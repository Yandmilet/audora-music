/// SongSourceBinding 表的读写。
///
/// ## 这个 DAO 里最重要的一条不变式
/// **同一首歌最多只能有一个 `is_active = 1` 的绑定。**
/// 「先清旧激活、再写新激活」必须在一个事务里完成，否则中途失败会让
/// 一首歌出现 0 个或 2 个激活音源——0 个表现为「突然没声」，
/// 2 个表现为「随机播到错的那首」，都是难查的偶发 bug。
library;

import 'package:sqflite/sqflite.dart';

import '../../../services/match/match_config.dart';
import '../../../services/match/match_scorer.dart';
import '../rows.dart';
import '../schema.dart';

class BindingDao {
  BindingDao(this.db);

  final DatabaseExecutor db;

  /// 写入自动匹配结果并激活（这是匹配引擎的主出口）。
  ///
  /// 事务内做三件事：
  ///   1. 清掉该歌原有的激活标记
  ///   2. upsert 绑定记录（同 song+bvid 覆盖）
  ///   3. 若达 AUTO 阈值，置为激活
  ///
  /// 返回绑定行 id。
  Future<int> saveMatch({
    required int songId,
    required ScoredCandidate scored,
    bool activate = true,
    String? note,
  }) async {
    return _txn((dao) async {
      await dao.deactivateAll(songId);
      final row = BindingRow.fromScored(
        songId: songId,
        scored: scored,
        isActive: activate && scored.confidence.isBound,
        note: note,
      );
      return dao.upsert(row);
    });
  }

  /// 批量保存匹配结果（同一首歌的多个候选）
  Future<List<int>> saveCandidates({
    required int songId,
    required List<ScoredCandidate> candidates,
  }) async {
    if (candidates.isEmpty) return [];
    return _txn((dao) async {
      final ids = <int>[];
      for (final c in candidates) {
        ids.add(await dao.upsert(BindingRow.fromScored(
          songId: songId,
          scored: c,
          isActive: false,
        )));
      }
      return ids;
    });
  }

  /// 人工绑定 / 用户改选（设计文档 6.4 的回流数据）
  ///
  /// [matchType] 区分 MANUAL_BOUND（人工确认算法推荐）与
  /// USER_SELECTED（用户改选了另一个候选）——后者是调参最有价值的样本。
  Future<int> bindManually({
    required int songId,
    required String bvid,
    required double score,
    ScoreDetail? detail,
    MatchType matchType = MatchType.manualBound,
    String? note,
  }) async {
    return _txn((dao) async {
      await dao.deactivateAll(songId);
      return dao.upsert(BindingRow.fromManual(
        songId: songId,
        bvid: bvid,
        score: score,
        detail: detail,
        matchType: matchType,
        note: note,
      ));
    });
  }

  /// upsert：同一 (song_id, bvid) 覆盖（表上有 UNIQUE 约束）
  Future<int> upsert(BindingRow row) async {
    final existing = await db.query(
      Tables.binding,
      columns: ['id'],
      where: 'song_id = ? AND bvid = ?',
      whereArgs: [row.songId, row.bvid],
      limit: 1,
    );
    if (existing.isEmpty) {
      return db.insert(Tables.binding, row.toMap());
    }
    final id = existing.first['id'] as int;
    await db.update(
      Tables.binding,
      row.toMap()..['id'] = id,
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  /// 清掉一首歌的所有激活标记。
  ///
  /// **必须与后续的激活写入在同一事务内调用**，见类注释。
  Future<void> deactivateAll(int songId) async {
    await db.update(
      Tables.binding,
      {'is_active': 0},
      where: 'song_id = ?',
      whereArgs: [songId],
    );
  }

  /// 切换激活音源（人工换源）
  Future<void> activate(int songId, String bvid) async {
    await _txn((dao) async {
      await dao.deactivateAll(songId);
      // ★ 必须走 dao.db（事务对象），不能用外层 db ——
      // 在事务内通过外层 Database 执行语句会另开一条连接，
      // 外层事务持有写锁，于是自己把自己锁死（SQLite 默认 busy_timeout
      // 只有 10s，超时后抛 database is locked）。
      await dao.db.update(
        Tables.binding,
        {'is_active': 1},
        where: 'song_id = ? AND bvid = ?',
        whereArgs: [songId, bvid],
      );
    });
  }

  /// 当前激活的绑定（播放时用）
  Future<BindingRow?> getActive(int songId) async {
    final rows = await db.query(
      Tables.binding,
      where: 'song_id = ? AND is_active = 1',
      whereArgs: [songId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BindingRow.fromMap(rows.first);
  }

  /// 一次 `IN (...)` 查回多首歌的激活绑定（song_id → 行）。
  ///
  /// ## 为什么需要批量版
  /// 曲库装配（`_assemble`）原来对每首歌逐条调 [getActive]：
  /// `listSongs(limit: 500)` = 500 次串行查询，冷启动全耗在这——
  /// 之前注释声称「避免 N+1」，实现本身就是 N+1。批量版同样命中
  /// `idx_binding_song_active` 索引，只是把 500 次往返压成 1 次。
  ///
  /// id 先去重。SQLite 变量上限 999，曲库列表/收藏列表的 limit 均
  /// ≤ 500，与 `songsByIdsOrdered` 同一量级约定，不做分片。
  Future<Map<int, BindingRow>> getActiveFor(List<int> songIds) async {
    if (songIds.isEmpty) return {};
    final uniqueIds = songIds.toSet().toList();
    final placeholders = List.filled(uniqueIds.length, '?').join(', ');
    final rows = await db.query(
      Tables.binding,
      where: 'song_id IN ($placeholders) AND is_active = 1',
      whereArgs: uniqueIds,
    );
    return {
      for (final r in rows) r['song_id'] as int: BindingRow.fromMap(r),
    };
  }

  /// 某首歌的全部候选（人工兜底界面用，按分数降序）
  Future<List<BindingRow>> getCandidates(int songId) async {
    final rows = await db.query(
      Tables.binding,
      where: 'song_id = ?',
      whereArgs: [songId],
      orderBy: 'match_score DESC',
    );
    return rows.map(BindingRow.fromMap).toList();
  }

  /// 按置信度取队列（设计文档 6.2 的「待确认 / 未匹配 / 已绑定」三个队列）
  Future<List<BindingRow>> getByConfidence(
    MatchConfidence c, {
    int limit = 100,
  }) async {
    final rows = await db.query(
      Tables.binding,
      where: 'confidence = ?',
      whereArgs: [c.label],
      orderBy: 'match_score DESC',
      limit: limit,
    );
    return rows.map(BindingRow.fromMap).toList();
  }

  /// 取某首歌已确认失效的 bvid，供重新匹配时排除（设计文档 8.3）
  Future<Set<String>> getFailedBvids(int songId) async {
    final rows = await db.rawQuery('''
      SELECT b.bvid FROM ${Tables.binding} b
      JOIN ${Tables.video} v ON v.bvid = b.bvid
      WHERE b.song_id = ? AND v.available = 0
    ''', [songId]);
    return rows.map((r) => r['bvid'] as String).toSet();
  }

  /// 取「有激活音源」的歌曲 id 列表（用于从曲库过滤出可播放的）
  Future<List<int>> getActiveSongIds({int limit = 1000}) async {
    final rows = await db.query(
      Tables.binding,
      columns: ['song_id'],
      where: 'is_active = 1',
      limit: limit,
    );
    return rows.map((r) => r['song_id'] as int).toList();
  }

  /// 取「**有任何绑定记录**」的歌曲 id 列表。
  ///
  /// 与 [getActiveSongIds] 的区别：这里包含 REVIEW / REJECTED 的候选。
  /// 用途是「待匹配」队列——有候选（哪怕只是待确认）的歌不该再被送去匹配。
  Future<List<int>> getAllSongIds() async {
    final rows = await db.query(
      Tables.binding,
      columns: ['song_id'],
      distinct: true,
    );
    return rows.map((r) => r['song_id'] as int).toList();
  }

  /// 统计各置信度的数量（匹配管理界面顶部展示）
  Future<Map<String, int>> stats() async {
    final rows = await db.rawQuery(
      'SELECT confidence, COUNT(*) AS c FROM ${Tables.binding} '
      'GROUP BY confidence',
    );
    return {
      for (final r in rows) r['confidence'] as String: (r['c'] as int?) ?? 0,
    };
  }

  Future<int> count() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.binding}');
    return (r.first['c'] as int?) ?? 0;
  }

  /// 在事务里执行；如果已在事务中（db 是 Transaction）则直接跑。
  ///
  /// sqflite 的 Transaction 本身也是 DatabaseExecutor，支持嵌套调用会死锁——
  /// 所以这里判断类型，只有顶层 Database 才开新事务。
  Future<T> _txn<T>(Future<T> Function(BindingDao dao) body) async {
    if (db is Transaction) {
      return body(this);
    }
    return (db as Database).transaction((txn) => body(BindingDao(txn)));
  }
}
