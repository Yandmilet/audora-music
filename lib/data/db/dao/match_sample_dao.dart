/// V0.9 Golden Dataset：match_sample 表 DAO。
///
/// 这张表记录每次匹配的完整快照——歌曲信息、所有候选得分、
/// 最终决策、后续用户反馈。用于：
///   - 离线评估（Auto Precision / Recall@3 / Margin Distribution）
///   - 后续 ML 训练数据
///   - 调参回归对比
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../models/models.dart';
import '../../../services/match/match_engine.dart';
import '../../../services/match/match_scorer.dart';
import '../schema.dart';

class MatchSampleDao {
  MatchSampleDao(this.db);
  final Database db;

  /// 写入一次匹配快照。失败静默（Golden Dataset 是辅助，不应影响主流程）。
  Future<void> insertMatchSample({
    required int songId,
    required Song song,
    required MatchResult result,
    required List<ScoredCandidate> allCandidates,
  }) async {
    if (!result.hasCandidate) return;

    try {
      final best = result.best!;
      final runnerUp = allCandidates.length >= 2 ? allCandidates[1] : null;
      final margin = runnerUp != null ? best.total - runnerUp.total : 0.0;

      final candidatesJson = allCandidates
          .map((c) => {
                'bvid': c.video.bvid,
                'title': c.video.title,
                'total': c.total.toStringAsFixed(4),
                'confidence': c.confidence.name,
                'detail': c.detail.toJson(),
              })
          .toList();

      await db.insert(Tables.matchSample, {
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'song_id': songId,
        'song_title': song.title,
        'song_artist': song.artist,
        'song_album': song.album,
        'song_duration': song.duration * 1000,
        'song_release': song.releaseDate?.millisecondsSinceEpoch,
        'best_bvid': best.video.bvid,
        'best_title': best.video.title,
        'best_total': best.total,
        'best_confidence': best.confidence.name,
        'best_detail': jsonEncode(best.detail.toJson()),
        'candidates_json': jsonEncode(candidatesJson),
        'margin': margin,
      });
    } catch (_) {
      // 失败静默
    }
  }

  Future<void> markAccepted(int songId, String bvid) async {
    try {
      await db.rawUpdate('''
        UPDATE ${Tables.matchSample}
        SET user_decision = 'accept',
            decision_bvid = ?,
            decided_at = ?
        WHERE song_id = ? AND user_decision IS NULL
      ''', [bvid, DateTime.now().millisecondsSinceEpoch, songId]);
    } catch (_) {}
  }

  /// 用户主动改选音源时回填反馈（Golden Dataset 的负样本通道）。
  ///
  /// 更新该歌**最新一条**快照（无论此前是否已被隐式接受）：
  ///  - [chosenBvid] == 快照 best_bvid → 'accept'（用户认可原选择）
  ///  - 否则 → 'reject'（此前 AUTO 绑定被推翻，调参最有价值的负样本）
  /// decision_bvid 一律记用户最终选择的 bvid（评估时的 ground truth）。
  ///
  /// 不能用 `WHERE user_decision IS NULL`：AUTO 绑定在激活时就已
  /// markAccepted 隐式落定，用户事后改选必须能覆盖那次隐式接受。
  /// 无快照（无候选匹配 / 老数据）时静默无操作。
  Future<void> markUserChoice(int songId, String chosenBvid) async {
    try {
      await db.rawUpdate('''
        UPDATE ${Tables.matchSample}
        SET user_decision = CASE
              WHEN ? = best_bvid THEN 'accept'
              ELSE 'reject'
            END,
            decision_bvid = ?,
            decided_at = ?
        WHERE id = (
          SELECT id FROM ${Tables.matchSample}
          WHERE song_id = ?
          ORDER BY created_at DESC, id DESC
          LIMIT 1
        )
      ''', [
        chosenBvid,
        chosenBvid,
        DateTime.now().millisecondsSinceEpoch,
        songId,
      ]);
    } catch (_) {}
  }

  /// V0.9-9 评价指标辅助：返回累计统计。
  Future<Map<String, int>> summary() async {
    final rows = await db.query(Tables.matchSample);
    if (rows.isEmpty) return const {'total': 0};

    int autoCount = 0;
    int autoCorrect = 0;
    int decisions = 0;
    int decisionsCorrect = 0;

    for (final r in rows) {
      final confidence = r['best_confidence'] as String? ?? '';
      final decision = r['user_decision'] as String?;
      final bestBvid = r['best_bvid'] as String? ?? '';
      final chosenBvid = r['decision_bvid'] as String?;

      if (confidence == 'auto') {
        autoCount++;
        if (decision == 'accept' || (decision != null && chosenBvid == bestBvid)) {
          autoCorrect++;
        }
      }

      if (decision != null) {
        decisions++;
        if (decision == 'accept') decisionsCorrect++;
      }
    }

    return {
      'total': rows.length,
      'auto_total': autoCount,
      'auto_correct': autoCorrect,
      'decisions_total': decisions,
      'decisions_correct': decisionsCorrect,
    };
  }
}
