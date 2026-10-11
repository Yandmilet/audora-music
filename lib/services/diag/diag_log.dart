/// 诊断日志 —— 匹配链路、网络请求、崩溃的本地留痕。
///
/// ## 为什么不放进 audora.db
/// 日志是**高频 append-only 流**：匹配一次写十几条，网络请求每条一次。
/// 塞进主库的后果是 `audora.db`（用户的曲库资产，要备份要迁移）被日志
/// 撑大，且按条数裁剪需要 VACUUM。所以落盘走 **JSONL 文件**
/// （一行一条 JSON），追加写、按天分文件、删文件即清理，导出直接就是成品。
/// 与「偏好设置不进数据库」是同一个理由：性质不同的数据不要共担生命周期。
///
/// ## 两级记录（用户 2026-09-29 决策）
/// - **摘要级（默认常开）**：`match` 与 `crash` 全级别 + 任何分类的
///   `warn` / `error`。覆盖「为什么这首歌没匹配上」与「为什么崩了」。
/// - **详细级（手动开）**：追加 `net` 的全量请求（含成功请求）。
///   排查限流 / -412 时临时打开，平时关掉以免日志量翻倍。
///
/// ## 三条硬约束
/// 1. **绝不记录凭据**：Cookie / SESSDATA / 完整流 URL（含签名）一律不写，
///    只写 bvid、cid、接口路径。脱敏责任在调用方，这里只保证不主动采集。
/// 2. **日志自身不许抛异常**：崩溃路径上再抛一次会把崩溃现场彻底弄丢。
///    所有 IO 都在 try/catch 里，失败就退化成「只留内存」。
/// 3. **不在 UI 线程同步写盘**：常规写走异步批量（20 条或 2 秒）；
///    只有崩溃时例外——进程随时可能被杀，那一次必须同步落盘。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 日志级别。数值越大越严重，用于摘要级过滤与 UI 着色。
enum DiagLevel { debug, info, warn, error }

/// 日志分类。UI 按它筛选，统计也按它聚合。
enum DiagCategory {
  /// 音源匹配四阶段
  match,

  /// B站 / QQ音乐网络请求（详细级才全量记录）
  net,

  /// 拉流与播放
  playback,

  /// 崩溃与未捕获异常
  crash,

  /// 界面动作（导入、切源等）
  ui;

  static DiagCategory fromName(String? s) => DiagCategory.values
      .firstWhere((e) => e.name == s, orElse: () => DiagCategory.ui);
}

/// 一条日志。
class DiagEntry {
  final DateTime at;
  final DiagLevel level;
  final DiagCategory category;

  /// 一句话结论，UI 列表的主标题
  final String message;

  /// 结构化字段（bvid / code / 耗时 / 六维得分 ...），UI 展开时展示
  final Map<String, Object?> fields;

  const DiagEntry({
    required this.at,
    required this.level,
    required this.category,
    required this.message,
    this.fields = const {},
  });

  Map<String, Object?> toJson() => {
        'ts': at.toIso8601String(),
        'level': level.name,
        'cat': category.name,
        'msg': message,
        if (fields.isNotEmpty) 'f': fields,
      };

  /// 解析失败时返回 null —— 单条坏记录不该让整个日志页打不开。
  static DiagEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ts = DateTime.tryParse(raw['ts']?.toString() ?? '');
    if (ts == null) return null;
    final f = raw['f'];
    return DiagEntry(
      at: ts,
      level: DiagLevel.values.firstWhere(
        (e) => e.name == raw['level'],
        orElse: () => DiagLevel.info,
      ),
      category: DiagCategory.fromName(raw['cat']?.toString()),
      message: raw['msg']?.toString() ?? '',
      fields: f is Map ? Map<String, Object?>.from(f) : const {},
    );
  }

  /// 单行 JSON（写盘用，不格式化）
  String get line => jsonEncode(toJson());

  /// UI 展示：把结构化字段压成一行可读文本
  String get detailText {
    if (fields.isEmpty) return '';
    const enc = JsonEncoder.withIndent('  ');
    return enc.convert(fields);
  }
}

/// 顶部统计条的数据。来源 = 内存缓冲 + 今日文件。
class DiagStats {
  final int requests;
  final int rateLimited;
  final int matchTotal;
  final int matchOk;
  final int crashes;

  const DiagStats({
    this.requests = 0,
    this.rateLimited = 0,
    this.matchTotal = 0,
    this.matchOk = 0,
    this.crashes = 0,
  });

  /// 匹配成功率；一次都没匹配过时返回 null（UI 显示「—」而不是 0%）
  double? get matchRate =>
      matchTotal == 0 ? null : matchOk / matchTotal;
}

/// 诊断日志单例。
///
/// ## 为什么用单例而不是层层传
/// 埋点分散在匹配引擎、网络客户端、解析器、main.dart 的崩溃钩子里——
/// 让它们都持有同一个实例，意味着这条链路上的每个构造函数都要加参数。
/// 日志是**横切关注点**，全局入口是它应有的形态；测试用
/// [resetForTest] 复位即可。
class DiagLog {
  DiagLog._();

  static final DiagLog instance = DiagLog._();

  /// 内存环形缓冲容量。UI 首屏直接读它，不必等文件 IO。
  static const int ringCap = 500;

  /// 批量落盘阈值：满 20 条，或距上次 flush 超过 2 秒。
  static const int flushThreshold = 20;
  static const Duration flushInterval = Duration(seconds: 2);

  /// 保留天数。启动时删掉更早的文件。
  static const int retainDays = 7;

  /// 单文件大小上限，超过就截掉前半部分（保留较新的后半）。
  static const int maxFileBytes = 2 * 1024 * 1024;

  final List<DiagEntry> _ring = [];
  final List<String> _pending = [];

  String? _dir;
  Timer? _timer;

  /// 详细级开关（摘要级永远开着，没有总开关）。
  bool _verbose = false;

  bool get verbose => _verbose;

  /// 落盘是否可用（目录没拿到时为 false，退化成纯内存）
  bool get persistent => _dir != null;

  /// 内存缓冲快照（最新在后）
  List<DiagEntry> get ring => List.unmodifiable(_ring);

  /// 打开日志目录。
  ///
  /// [dir] 为空时不落盘（纯内存模式）：单测与 path_provider 不可用时的
  /// 降级路径。**失败一律静默**——日志写不了不该影响应用启动。
  Future<void> init({String? dir}) async {
    try {
      _dir = dir;
      if (_dir != null) unawaited(prune());
    } catch (_) {
      _dir = null;
    }
  }

  /// 切详细级。由设置页调用（用户 2026-09-29：详细级默认关）。
  void setVerbose(bool v) {
    _verbose = v;
    if (!v) return;
    // 打开瞬间刷一次，让「开了开关」这件事本身有据可查
    log(DiagLevel.info, DiagCategory.ui, '诊断日志切到详细级（记录全部网络请求）');
  }

  /// 是否该记录这条。
  ///
  /// 摘要级 = `match` / `crash` 全级别 + 任何分类的 warn / error。
  /// 这样「匹配过程」和「崩溃」默认留痕，而高频的成功网络请求不落盘。
  bool _accept(DiagLevel level, DiagCategory cat) {
    if (_verbose) return true;
    // debug 一律只在详细级出现：哪怕是匹配链路里的琐碎步骤
    // （比如"详情缓存命中"），默认也不该占版面
    if (level == DiagLevel.debug) return false;
    if (level == DiagLevel.warn || level == DiagLevel.error) return true;
    return cat == DiagCategory.match || cat == DiagCategory.crash;
  }

  /// 写一条日志。**永不抛异常。**
  void log(
    DiagLevel level,
    DiagCategory category,
    String message, {
    Map<String, Object?> fields = const {},
  }) {
    try {
      if (!_accept(level, category)) return;
      final entry = DiagEntry(
        at: DateTime.now(),
        level: level,
        category: category,
        message: message,
        fields: _sanitize(fields),
      );
      _add(entry);
    } catch (_) {
      // 日志系统自身出错时什么都不做：保住主流程
    }
  }

  /// 便捷方法
  void d(DiagCategory c, String msg, [Map<String, Object?> f = const {}]) =>
      log(DiagLevel.debug, c, msg, fields: f);

  void i(DiagCategory c, String msg, [Map<String, Object?> f = const {}]) =>
      log(DiagLevel.info, c, msg, fields: f);

  void w(DiagCategory c, String msg, [Map<String, Object?> f = const {}]) =>
      log(DiagLevel.warn, c, msg, fields: f);

  void e(DiagCategory c, String msg, [Map<String, Object?> f = const {}]) =>
      log(DiagLevel.error, c, msg, fields: f);

  /// 崩溃专用：同步落盘后入缓冲。
  ///
  /// 崩溃后进程可能立刻被杀（尤其 release 下的未捕获异步异常），
  /// 异步 flush 大概率来不及。这里**直接同步写**。
  void crash(
    String message, {
    required String kind,
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields = const {},
  }) {
    try {
      final f = <String, Object?>{
        'kind': kind,
        if (error != null) 'error': error.toString(),
        if (stack != null) 'stack': _trimStack(stack),
        ...fields,
      };
      final entry = DiagEntry(
        at: DateTime.now(),
        level: DiagLevel.error,
        category: DiagCategory.crash,
        message: message,
        fields: _sanitize(f),
      );
      _add(entry);
      _flushSync();
    } catch (_) {
      // 崩溃路径上的二次异常只能吞掉
    }
  }

  void _add(DiagEntry e) {
    _ring.add(e);
    if (_ring.length > ringCap) _ring.removeAt(0);
    _pending.add(e.line);
    if (_pending.length >= flushThreshold) {
      unawaited(flush());
      return;
    }
    _ensureTimer();
  }

  void _ensureTimer() {
    if (_timer != null) return;
    _timer = Timer(flushInterval, () => unawaited(flush()));
  }

  /// 把待写行刷进文件（异步）。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final lines = List<String>.from(_pending);
    _pending.clear();
    await _write(lines);
  }

  Future<void> _write(List<String> lines) async {
    final path = _filePath();
    if (path == null) return;
    try {
      final f = File(path);
      if (!await f.parent.exists()) {
        await f.parent.create(recursive: true);
      }
      await f.writeAsString('${lines.join('\n')}\n',
          mode: FileMode.append, flush: true);
      await _trimIfTooLarge(f);
    } catch (_) {
      // 磁盘满 / 权限问题：丢掉这批，不影响运行
    }
  }

  void _flushSync() {
    final lines = List<String>.from(_pending);
    _pending.clear();
    final path = _filePath();
    if (path == null) return;
    try {
      final f = File(path);
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsStringSync('${lines.join('\n')}\n', mode: FileMode.append);
    } catch (_) {
      // 同步写也失败就没办法了
    }
  }

  /// 单文件超限时截掉前半，保留较新的后半。
  Future<void> _trimIfTooLarge(File f) async {
    try {
      if (await f.length() <= maxFileBytes) return;
      final raw = await f.readAsLines();
      final keep = raw.length ~/ 2;
      await f.writeAsString('${raw.skip(keep).join('\n')}\n', flush: true);
    } catch (_) {
      // 截断失败：文件暂时超限，下次写入会重试（自愈），不打断本次写入
    }
  }

  String? _filePath() {
    final dir = _dir;
    if (dir == null) return null;
    final now = DateTime.now();
    final day = '${now.year}${_two(now.month)}${_two(now.day)}';
    return p.join(dir, 'diag-$day.jsonl');
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 字段脱敏 + 长度收敛。
  ///
  /// 只做「防御性」收敛：丢空值、截断超长字符串、**把非 JSON 基本类型
  /// 压成字符串**（否则 e.line 的 jsonEncode 会抛 FormatException，
  /// 整条日志被 log() 的兜底 catch 无声吞掉——DateTime / StackTrace /
  /// 任意业务对象都踩过这类坑）。
  /// **凭据类字段的过滤责任在调用方**——日志系统不知道哪个字符串是 Cookie。
  Map<String, Object?> _sanitize(Map<String, Object?> src) {
    final out = <String, Object?>{};
    for (final e in src.entries) {
      final v = e.value;
      if (v == null) continue;
      if (v is String) {
        if (v.isEmpty) continue;
        out[e.key] = v.length > 400 ? '${v.substring(0, 400)}…' : v;
      } else if (v is num || v is bool) {
        out[e.key] = v;
      } else {
        out[e.key] = v.toString();
      }
    }
    return out;
  }

  /// 堆栈截断：崩溃栈常有几百帧，前 20 帧足够定位，其余是噪音。
  static String _trimStack(StackTrace stack, {int frames = 20}) {
    final lines = stack.toString().split('\n');
    final keep = lines.length > frames ? lines.take(frames) : lines;
    return keep.join('\n');
  }

  /// 读取最近 [days] 天的全部日志（内存 + 文件），时间正序。
  Future<List<DiagEntry>> readAll({int days = 7}) async {
    final out = <DiagEntry>[];
    final dir = _dir;
    if (dir != null) {
      try {
        final d = Directory(dir);
        if (await d.exists()) {
          final files = d
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.jsonl'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
          final cutoff = DateTime.now().subtract(Duration(days: days));
          for (final f in files) {
            final m = await f.lastModified();
            if (m.isBefore(cutoff)) continue;
            for (final l in await f.readAsLines()) {
              final e = _decodeLine(l);
              if (e != null) out.add(e);
            }
          }
        }
      } catch (_) {
        // 读不到就只给内存里那部分
      }
    }
    // 内存里的最新一批可能还没落盘，按时间戳去重后补在后面
    final seen = out.map((e) => e.at.microsecondsSinceEpoch).toSet();
    for (final e in _ring) {
      if (seen.add(e.at.microsecondsSinceEpoch)) out.add(e);
    }
    return out;
  }

  static DiagEntry? _decodeLine(String l) {
    if (l.trim().isEmpty) return null;
    try {
      return DiagEntry.fromJson(jsonDecode(l));
    } catch (_) {
      return null;
    }
  }

  /// 统计（今日）。基于内存缓冲 + 今日文件。
  Future<DiagStats> stats() async {
    var requests = 0;
    var rateLimited = 0;
    var matchTotal = 0;
    var matchOk = 0;
    var crashes = 0;

    void absorb(DiagEntry e) {
      final today = _isToday(e.at);
      if (e.category == DiagCategory.crash) {
        if (today) crashes++;
        return;
      }
      final ev = e.fields['event']?.toString();
      if (e.category == DiagCategory.net && ev == 'request') {
        if (today) requests++;
        final code = e.fields['code'];
        if (code is num && (code.toInt() == -412 || code.toInt() == -352)) {
          if (today) rateLimited++;
        }
        return;
      }
      if (e.category == DiagCategory.match && ev == 'done') {
        if (!today) return;
        matchTotal++;
        if (e.fields['ok'] == true) matchOk++;
      }
    }

    final inRing = <int>{};
    for (final e in _ring) {
      inRing.add(e.at.microsecondsSinceEpoch);
      absorb(e);
    }
    // 文件里还有内存缓冲已淘汰的今日记录，按时间戳去重后补上
    final path = _filePath();
    if (path != null) {
      final lines = await File(path)
          .readAsLines()
          .catchError((_) => <String>[]);
      for (final l in lines) {
        final e = _decodeLine(l);
        if (e == null) continue;
        if (!inRing.add(e.at.microsecondsSinceEpoch)) continue;
        absorb(e);
      }
    }
    return DiagStats(
      requests: requests,
      rateLimited: rateLimited,
      matchTotal: matchTotal,
      matchOk: matchOk,
      crashes: crashes,
    );
  }

  static bool _isToday(DateTime t) {
    final now = DateTime.now();
    return t.year == now.year && t.month == now.month && t.day == now.day;
  }

  /// 清空：内存 + 全部日志文件。
  Future<void> clear() async {
    _ring.clear();
    _pending.clear();
    final dir = _dir;
    if (dir == null) return;
    try {
      final d = Directory(dir);
      if (!await d.exists()) return;
      await for (final e in d.list()) {
        if (e is File && e.path.endsWith('.jsonl')) {
          await e.delete().catchError((_) => e);
        }
      }
    } catch (e) {
      // 清理失败不能无声：用户点了「清空」、文件却还在，至少内存 ring
      // 里要有痕迹（ring 不依赖磁盘，一定可用）。
      log(DiagLevel.error, DiagCategory.ui, '清空日志文件失败：$e');
    }
  }

  /// 删除超过 [retainDays] 天的文件。启动时调一次。
  Future<void> prune() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final d = Directory(dir);
      if (!await d.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: retainDays));
      await for (final e in d.list()) {
        if (e is! File || !e.path.endsWith('.jsonl')) continue;
        final m = await e.lastModified().catchError((_) => DateTime.now());
        if (m.isBefore(cutoff)) await e.delete().catchError((_) => e);
      }
    } catch (_) {}
  }

  /// 导出：把最近 [days] 天日志写成单个 .jsonl 文件。
  ///
  /// 返回目标路径；失败返回 null。导出的就是日志文件本身，
  /// 不需要额外格式转换（这也是选 JSONL 而非 SQLite 的收益之一）。
  Future<String?> export({String? toDir, int days = 7}) async {
    final target = toDir ?? _dir;
    if (target == null) return null;
    try {
      final entries = await readAll(days: days);
      final now = DateTime.now();
      final name = 'audora-diag-${now.year}${_two(now.month)}${_two(now.day)}'
          '-${_two(now.hour)}${_two(now.minute)}.jsonl';
      final out = File(p.join(target, name));
      await out.writeAsString(
        entries.map((e) => e.line).join('\n'),
        flush: true,
      );
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// 测试用：复位成「未初始化、纯内存」状态。
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _ring.clear();
    _pending.clear();
    _dir = null;
    _verbose = false;
  }
}
