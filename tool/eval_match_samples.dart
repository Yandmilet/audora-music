/// Golden Dataset（match_sample 表）离线评估脚本。
///
/// 从匹配快照库里算调参需要的核心指标：
///   - **Auto Precision**：AUTO 决策中被用户认可（未被推翻）的比例
///   - **False Auto Rate**：AUTO 决策中被用户推翻的比例（= 1 - Auto Precision）
///   - **Recall@1 / Recall@3**：用户最终选择的音源是否排在候选池前列
///   - **Margin 分布**：accept 与 reject 两类的 best-runnerUp 分位差，
///     用来判断当前置信度阈值能否把两类分开
///
/// 用法：
/// ```
/// dart run tool/eval_match_samples.dart <path/to/audora.db>
/// dart run tool/eval_match_samples.dart <path/to/audora.db> --csv features.csv
/// ```
///
/// `--csv` 额外导出「已决策样本 × 候选」逐行特征表（rank/total/S1~S6/是否被选中），
/// 供后续网格搜索 / 权重调优直接读用。
///
/// 设备库导出（release 包无法 run-as，走调试包或 root）：
/// ```
/// adb exec-out run-as <package> cat databases/audora.db > audora.db
/// ```
/// 也可直接指向 Windows 上的库文件副本。脚本只读打开，不改数据。
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// 单个候选的解析结果（candidates_json 数组元素）。
class _Cand {
  final String bvid;
  final double total;
  final Map<String, double> detail;
  _Cand(this.bvid, this.total, this.detail);
}

/// 一条匹配快照（match_sample 行）。
class _Sample {
  final int id;
  final int songId;
  final String songTitle;
  final String bestBvid;
  final double bestTotal;
  final String confidence; // auto / review / rejected
  final double margin;
  final String? decision; // accept / reject / null
  final String? decisionBvid;
  final List<_Cand> candidates;
  _Sample(
      this.id, this.songId, this.songTitle, this.bestBvid, this.bestTotal,
      this.confidence, this.margin, this.decision, this.decisionBvid,
      this.candidates);

  bool get decided => decision != null;
}

void main(List<String> args) {
  // sqlite3 3.x 走 native assets：pubspec 的 hooks.user_defines 已配置
  // Windows 用系统 winsqlite3.dll（System32）、Linux 用 libsqlite3.so，免安装。

  var dbPath = '';
  var csvPath = '';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--csv' && i + 1 < args.length) {
      csvPath = args[++i];
    } else {
      dbPath = args[i];
    }
  }
  if (dbPath.isEmpty) {
    stderr.writeln('用法: dart run tool/eval_match_samples.dart <audora.db> [--csv out.csv]');
    exit(2);
  }
  if (!File(dbPath).existsSync()) {
    stderr.writeln('数据库文件不存在: $dbPath');
    exit(2);
  }

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  final rows = db.select('''
    SELECT id, song_id, song_title, best_bvid, best_total, best_confidence,
           margin, user_decision, decision_bvid, candidates_json
    FROM match_sample ORDER BY song_id, created_at, id
  ''');
  final samples =
      rows.map(_sampleFromRow).toList();

  _report(samples, dbPath);
  if (csvPath.isNotEmpty) _exportCsv(samples, csvPath);
  db.close();
}

// ── 解析 ──────────────────────────────────────────────────────────────

/// candidates_json 新格式是合法 JSON（jsonEncode）；早期版本 detail 字段
/// 走过 Dart Map.toString()（键无引号），jsonDecode 会炸 → 正则兜底。
_Sample _sampleFromRow(Map<String, Object?> r) {
  final raw = r['candidates_json'] as String? ?? '';
  List<_Cand> cands;
  try {
    final list = jsonDecode(raw) as List;
    cands = list.map((e) {
      final m = e as Map;
      return _Cand(
        m['bvid'] as String? ?? '',
        double.tryParse('${m['total']}') ?? 0,
        _detailFromDynamic(m['detail']),
      );
    }).toList();
  } catch (_) {
    cands = _parseLegacyCandidates(raw);
  }
  return _Sample(
    r['id'] as int,
    r['song_id'] as int,
    r['song_title'] as String? ?? '',
    r['best_bvid'] as String? ?? '',
    (r['best_total'] as num?)?.toDouble() ?? 0,
    r['best_confidence'] as String? ?? '',
    (r['margin'] as num?)?.toDouble() ?? 0,
    r['user_decision'] as String?,
    r['decision_bvid'] as String?,
    cands,
  );
}

Map<String, double> _detailFromDynamic(Object? detail) {
  if (detail is Map) {
    return {
      for (final e in detail.entries)
        '${e.key}': double.tryParse('${e.value}') ?? 0,
    };
  }
  return const {};
}

/// 旧格式兜底：`{"bvid":"BVxx","title":"...","total":"0.9",...,"detail":{s1: 0.9,...}}`
/// 按 bvid 出现位置切块，块内再抽 total 与 S1~S6。
List<_Cand> _parseLegacyCandidates(String raw) {
  final bvidRe = RegExp('"bvid":"([^"]+)"');
  final totalRe = RegExp('"total":"([0-9.]+)"');
  final sRe = RegExp(r's([1-6]):\s*([0-9.]+)');
  final result = <_Cand>[];
  final matches = bvidRe.allMatches(raw).toList();
  for (var i = 0; i < matches.length; i++) {
    final start = matches[i].start;
    final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
    final chunk = raw.substring(start, end);
    final detail = <String, double>{};
    for (final m in sRe.allMatches(chunk).take(6)) {
      detail['s${m.group(1)}'] = double.tryParse(m.group(2)!) ?? 0;
    }
    result.add(_Cand(
      matches[i].group(1)!,
      double.tryParse(totalRe.firstMatch(chunk)?.group(1) ?? '') ?? 0,
      detail,
    ));
  }
  return result;
}

// ── 指标 ──────────────────────────────────────────────────────────────

/// ground truth 在候选池内的名次（按 total 降序）；不在池内返回 null。
int? _rankOf(_Sample s) {
  final chosen = s.decisionBvid;
  if (chosen == null) return null;
  final sorted = [...s.candidates]
    ..sort((a, b) => b.total.compareTo(a.total));
  final idx = sorted.indexWhere((c) => c.bvid == chosen);
  return idx < 0 ? null : idx + 1;
}

void _report(List<_Sample> samples, String dbPath) {
  final decided = samples.where((s) => s.decided).toList();
  final auto = samples.where((s) => s.confidence == 'auto').toList();
  final autoDecided = auto.where((s) => s.decided).toList();
  final autoRejected = autoDecided.where((s) => s.decision == 'reject').length;

  final inPool = decided.where((s) => _rankOf(s) != null).toList();
  final outOfPool = decided.length - inPool.length;
  final recallAt1 = inPool.where((s) => _rankOf(s) == 1).length;
  final recallAt3 = inPool.where((s) => _rankOf(s)! <= 3).length;

  final accMargins = decided
      .where((s) => s.decision == 'accept')
      .map((s) => s.margin)
      .toList()
    ..sort();
  final rejMargins = decided
      .where((s) => s.decision == 'reject')
      .map((s) => s.margin)
      .toList()
    ..sort();

  final out = StringBuffer()
    ..writeln('== Golden Dataset 离线评估 ==')
    ..writeln('数据库: $dbPath')
    ..writeln('样本总数: ${samples.length}'
        '（已决策 ${decided.length} / 待决策 ${samples.length - decided.length}）')
    ..writeln('按置信度: auto=${auto.length} review=${samples.where((s) => s.confidence == 'review').length}'
        ' rejected=${samples.where((s) => s.confidence == 'rejected').length}')
    ..writeln()
    ..writeln('-- Auto Precision（AUTO 决策质量）--');

  if (autoDecided.isEmpty) {
    out.writeln('  AUTO 已决策样本为 0 —— 继续攒样本（换源/手动指定都会回填反馈）');
  } else {
    final precision = (autoDecided.length - autoRejected) / autoDecided.length;
    out
      ..writeln('  AUTO 已决策: ${autoDecided.length}/${auto.length}'
          ' → Precision = ${(precision * 100).toStringAsFixed(1)}%')
      ..writeln('  False Auto Rate（被推翻）= '
          '${(autoRejected / autoDecided.length * 100).toStringAsFixed(1)}%');
  }

  out
    ..writeln()
    ..writeln('-- Recall@K（用户最终选择是否在候选前列）--');
  if (inPool.isEmpty) {
    out.writeln('  无已决策样本（等 markUserChoice 回填后才有数据）');
  } else {
    out
      ..writeln('  Recall@1 = $recallAt1/${inPool.length} '
          '= ${(recallAt1 / inPool.length * 100).toStringAsFixed(1)}%')
      ..writeln('  Recall@3 = $recallAt3/${inPool.length} '
          '= ${(recallAt3 / inPool.length * 100).toStringAsFixed(1)}%');
  }
  if (outOfPool > 0) {
    out.writeln('  ground truth 不在候选池: $outOfPool 条'
        '（手动搜索绑定的外部视频，不计入分母）');
  }

  out
    ..writeln()
    ..writeln('-- Margin 分布（best - runnerUp）--')
    ..writeln('  accept: ${_percentiles(accMargins)}')
    ..writeln('  reject: ${_percentiles(rejMargins)}')
    ..writeln('  提示: 两类分位区间重叠越多，当前置信度阈值越难分开这两类；')
    ..writeln('        accept 的 p25 明显高于 reject 的 p75 时，阈值附近才有调参空间。');

  stdout.writeln(out);
}

String _percentiles(List<double> sorted) {
  if (sorted.isEmpty) return '（无样本）';
  double p(double q) => sorted[((sorted.length - 1) * q).round()];
  return 'p25=${p(0.25).toStringAsFixed(4)} p50=${p(0.5).toStringAsFixed(4)}'
      ' p75=${p(0.75).toStringAsFixed(4)} p90=${p(0.9).toStringAsFixed(4)}'
      ' (n=${sorted.length})';
}

// ── CSV 导出（调参特征表）─────────────────────────────────────────────

void _exportCsv(List<_Sample> samples, String csvPath) {
  final decided = samples.where((s) => s.decided).toList();
  final buf = StringBuffer()
    ..writeln('sample_id,song_id,song_title,rank,bvid,total,is_best,is_chosen,'
        'confidence,user_decision,best_total,margin,'
        's1,s2,s3,s4,s5,s6,penalty,contradiction');
  for (final s in decided) {
    final sorted = [...s.candidates]..sort((a, b) => b.total.compareTo(a.total));
    for (var i = 0; i < sorted.length; i++) {
      final c = sorted[i];
      final d = c.detail;
      String f(String k) => (d[k] ?? 0).toString();
      buf
        ..write('${s.id},${s.songId},"${_csvEscape(s.songTitle)}",${i + 1},'
            '${c.bvid},${c.total.toStringAsFixed(4)},'
            '${c.bvid == s.bestBvid ? 1 : 0},${c.bvid == s.decisionBvid ? 1 : 0},'
            '${s.confidence},${s.decision},'
            '${s.bestTotal.toStringAsFixed(4)},${s.margin.toStringAsFixed(4)},'
            '${f('s1')},${f('s2')},${f('s3')},${f('s4')},${f('s5')},${f('s6')},'
            '${f('penalty')},${f('contradiction')}')
        ..writeln();
    }
  }
  File(csvPath).writeAsStringSync(buf.toString());
  stdout.writeln('特征表已导出: $csvPath'
      '（${decided.length} 个已决策样本 × 候选，供网格搜索读用）');
}

String _csvEscape(String s) => s.replaceAll('"', '""');
