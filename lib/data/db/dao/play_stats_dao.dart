/// 播放历史与播放次数统计的读写。
///
/// ## 两张表的分工（详见 `schema.dart`）
/// - `play_log`：事件流，每次「听完一段」追加一行。用于「最近播放」。
///   会无限增长，所以提供 [trimLog] 定期裁剪。
/// - `play_stat`：聚合，一行对一首歌。用于「常听排行」。
///   靠 upsert 累加，不随流水增长而变大。
///
/// ## 什么算「一次播放」
/// 本 DAO 不做判断，由调用方（`AppState`）在**实际播够时长**后调用
/// [recordPlay]。这里只管「记下来」，并保证两张表在**同一事务**里更新——
/// 否则会出现「最近播放里有它、常听榜里没有」的不一致。
library;

import 'package:sqflite/sqflite.dart';

import '../schema.dart';

/// 一首歌的播放统计
class PlayStat {
  final int songId;

  /// 有效播放次数（达到门限的那些）
  final int playCount;

  /// 累计播放时长（毫秒）
  final int totalPlayedMs;

  /// 最近一次播放时间（秒级时间戳）
  final int lastPlayedAt;

  const PlayStat({
    required this.songId,
    required this.playCount,
    required this.totalPlayedMs,
    required this.lastPlayedAt,
  });
}

/// 播放流水的一条记录（「最近播放」用）
class PlayLogEntry {
  final int songId;
  final int playedAt;
  final int playedMs;

  const PlayLogEntry({
    required this.songId,
    required this.playedAt,
    this.playedMs = 0,
  });
}

class PlayStatsDao {
  PlayStatsDao(this.db);

  final DatabaseExecutor db;

  /// 有效播放的时长门限：听满 30 秒才算一次。
  ///
  /// ## 为什么要这个门限
  /// 「播放次数」如果不设门限，用户点开歌单一路跳过也会把每首都记一次，
  /// 常听榜会变成「我最近点开过什么」而不是「我真正在听什么」。
  /// 30 秒是在「能反映真实收听」和「短歌也能计数」之间的折中。
  static const int countingThresholdMs = 30 * 1000;

  /// 记一次播放。
  ///
  /// [playedMs] 是本次实际播放时长；达到 [countingThresholdMs] 才计入
  /// `play_count`，但**不论是否达标都会写入流水**（否则「最近播放」
  /// 会漏掉用户刚刚点开的那首）。
  ///
  /// 两张表的更新必须同一事务：这是本 DAO 唯一的不变式。
  Future<void> recordPlay(
    int songId, {
    required int playedMs,
    int? now,
    String? sourceBvid,
  }) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final counts = playedMs >= countingThresholdMs;

    // ⚠️ `db as Database`：DatabaseExecutor 接口没有 transaction 方法
    // （Transaction 自己才是 executor）。这是既有约定，见 song_dao.dart。
    await (db as Database).transaction((txn) async {
      await txn.insert(Tables.playLog, {
        'song_id': songId,
        'played_at': ts,
        'played_ms': playedMs,
        if (sourceBvid != null) 'source_bvid': sourceBvid,
      });

      // 即使不算有效播放，也刷新 last_played_at ——
      // 「最近播放」看的是最后接触时间，不是有效收听。
      await txn.rawInsert(
        '''
        INSERT INTO ${Tables.playStat}
          (song_id, play_count, total_played_ms, last_played_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(song_id) DO UPDATE SET
          play_count      = play_count + excluded.play_count,
          total_played_ms = total_played_ms + excluded.total_played_ms,
          last_played_at  = excluded.last_played_at
        ''',
        [songId, counts ? 1 : 0, playedMs, ts],
      );
    });
  }

  /// 某首歌的统计，没有记录时返回 null
  Future<PlayStat?> statOf(int songId) async {
    final rows = await db.query(
      Tables.playStat,
      where: 'song_id = ?',
      whereArgs: [songId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _toStat(rows.first);
  }

  /// 常听排行：按有效播放次数倒序。
  ///
  /// [minCount] 用于过滤掉只听过一两次的——首页「常听」只放真正的常听。
  /// 传 1 表示不过滤。
  Future<List<PlayStat>> topPlayed({
    int limit = 20,
    int minCount = 1,
  }) async {
    final rows = await db.query(
      Tables.playStat,
      where: 'play_count >= ?',
      whereArgs: [minCount],
      orderBy: 'play_count DESC, last_played_at DESC',
      limit: limit,
    );
    return rows.map(_toStat).toList();
  }

  /// 最近播放：按最后接触时间倒序。
  ///
  /// ## 为什么要 GROUP BY 而不是直接查流水
  /// 同一首歌反复播放会在流水里出现多行，直接查会看到「同一首歌排满整屏」。
  /// 这里按 song 去重，取每首的**最新一次**时间。
  Future<List<int>> recentlyPlayedSongIds({int limit = 30}) async {
    final rows = await db.rawQuery(
      '''
      SELECT song_id, MAX(played_at) AS last_at
      FROM ${Tables.playLog}
      GROUP BY song_id
      ORDER BY last_at DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((r) => r['song_id'] as int).toList();
  }

  /// 最近的播放流水（**不去重**，含重复播放，用于调试 / 详情页）
  Future<List<PlayLogEntry>> recentLogs({int limit = 50}) async {
    final rows = await db.query(
      Tables.playLog,
      orderBy: 'played_at DESC',
      limit: limit,
    );
    return rows
        .map((r) => PlayLogEntry(
              songId: r['song_id'] as int,
              playedAt: r['played_at'] as int,
              playedMs: (r['played_ms'] as int?) ?? 0,
            ))
        .toList();
  }

  /// 裁剪流水：只保留最近 [keep] 条。
  ///
  /// `play_log` 会持续增长（每次播放一行），不裁的话长期使用后会拖慢查询。
  /// 注意**只裁流水，不动聚合表**——`play_stat` 是常听排行的唯一依据，
  /// 裁掉流水不该让「听了 100 次」变成「听了 3 次」。
  Future<int> trimLog({int keep = 500}) async {
    return db.rawDelete(
      '''
      DELETE FROM ${Tables.playLog}
      WHERE id NOT IN (
        SELECT id FROM ${Tables.playLog} ORDER BY played_at DESC LIMIT ?
      )
      ''',
      [keep],
    );
  }

  /// 清空全部播放历史（设置项「清除播放记录」用）
  Future<void> clearAll() async {
    // ⚠️ `db as Database`：DatabaseExecutor 接口没有 transaction 方法
    // （Transaction 自己才是 executor）。这是既有约定，见 song_dao.dart。
    await (db as Database).transaction((txn) async {
      await txn.delete(Tables.playLog);
      await txn.delete(Tables.playStat);
    });
  }

  static PlayStat _toStat(Map<String, Object?> m) => PlayStat(
        songId: m['song_id'] as int,
        playCount: (m['play_count'] as int?) ?? 0,
        totalPlayedMs: (m['total_played_ms'] as int?) ?? 0,
        lastPlayedAt: (m['last_played_at'] as int?) ?? 0,
      );
}
