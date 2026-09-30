/// Song 表的读写。
library;

import 'package:sqflite/sqflite.dart';

import '../rows.dart';
import '../schema.dart';

class SongDao {
  SongDao(this.db);

  final DatabaseExecutor db;

  /// 插入或更新（以 `qq_song_mid` 去重，设计文档 10.3）。
  ///
  /// 返回行 id。已存在时保留原 `created_at`，只更新 `updated_at`
  /// 和服务端可能变化的字段（作词/作曲/编曲等补全信息）。
  Future<int> upsert(SongRow row) async {
    final existing = await db.query(
      Tables.song,
      columns: ['id', 'created_at'],
      where: 'qq_song_mid = ?',
      whereArgs: [row.qqSongMid],
      limit: 1,
    );

    if (existing.isEmpty) {
      return db.insert(Tables.song, row.toMap());
    }

    final id = existing.first['id'] as int;
    final createdAt = existing.first['created_at'] as int? ?? row.createdAt;
    await db.update(
      Tables.song,
      row.toMap()..['created_at'] = createdAt,
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  /// 批量 upsert（曲库导入用）。走事务，避免逐条提交的开销。
  ///
  /// ## 为什么用原生 `ON CONFLICT DO UPDATE` 而不是复用 [upsert]
  /// 逐条走 [upsert] 是「每行 1 次 SELECT + 1 次写」，100 首歌 = 200 条语句。
  /// 原生 UPSERT 把每行压成 1 条 INSERT，批量收尾再用**一次** `IN (...)`
  /// 查询取回全部 id 按入参顺序排列——200 条 → N+1 条。
  /// `created_at` 不进 DO UPDATE 的 SET 列表：冲突时保留库中原值，
  /// 与 [upsert] 的语义一致。
  Future<List<int>> upsertAll(List<SongRow> rows) async {
    if (rows.isEmpty) return [];

    Future<void> body(DatabaseExecutor executor) async {
      for (final r in rows) {
        await executor.rawInsert('''
INSERT INTO ${Tables.song}
  (qq_song_mid, title, artists, album, album_mid, lyricist, composer,
   arranger, genre, release_date, duration_ms, cover_seed, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(qq_song_mid) DO UPDATE SET
  title = excluded.title,
  artists = excluded.artists,
  album = excluded.album,
  album_mid = excluded.album_mid,
  lyricist = excluded.lyricist,
  composer = excluded.composer,
  arranger = excluded.arranger,
  genre = excluded.genre,
  release_date = excluded.release_date,
  duration_ms = excluded.duration_ms,
  cover_seed = excluded.cover_seed,
  updated_at = excluded.updated_at
''', [
          r.qqSongMid,
          r.title,
          r.artists,
          r.album,
          r.albumMid,
          r.lyricist,
          r.composer,
          r.arranger,
          r.genre,
          r.releaseDate,
          r.durationMs,
          r.coverSeed,
          r.createdAt,
          r.updatedAt,
        ]);
      }
    }

    // DatabaseExecutor 没有 transaction 方法（Transaction 自己才是 executor），
    // 所以先判类型：顶层 Database 才开新事务，已在事务里则直接跑，避免死锁。
    if (db is Transaction) {
      await body(db);
    } else {
      await (db as Database).transaction(body);
    }

    // 一次查回全部 id，按入参顺序排列（调用方依赖返回顺序与入参一致）。
    final mids = rows.map((r) => r.qqSongMid).toList();
    final inPlaceholders = List.filled(mids.length, '?').join(', ');
    final idRows = await db.query(
      Tables.song,
      columns: ['id', 'qq_song_mid'],
      where: 'qq_song_mid IN ($inPlaceholders)',
      whereArgs: mids,
    );
    final idByMid = <String, int>{
      for (final r in idRows) r['qq_song_mid'] as String: r['id'] as int,
    };
    return [for (final mid in mids) idByMid[mid]!];
  }

  Future<SongRow?> getById(int id) async {
    final rows = await db.query(
      Tables.song,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SongRow.fromMap(rows.first);
  }

  Future<SongRow?> getByMid(String mid) async {
    final rows = await db.query(
      Tables.song,
      where: 'qq_song_mid = ?',
      whereArgs: [mid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SongRow.fromMap(rows.first);
  }

  Future<List<SongRow>> getAll({int limit = 500, int offset = 0}) async {
    final rows = await db.query(
      Tables.song,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(SongRow.fromMap).toList();
  }

  /// 取「id 不在 [notInSubSelect] 结果里」的歌，按 `created_at DESC` 排序。
  ///
  /// ## 为什么必须是 SQL 下推，而不是拉全表 + Dart 过滤
  /// 旧写法 `getAll(limit: limit * 4)` 再在 Dart 里差集：曲库一旦超过
  /// limit×4 首（未匹配队列 400 / 批量匹配 200），排在后面的歌**永远
  /// 进不了队列**——列表看起来是全的，实际在静默漏歌。
  ///
  /// [notInSubSelect] 是返回 song_id 的子查询（不含外层括号），由调用方
  /// 决定排除口径：「有任何绑定记录」用 `SELECT DISTINCT song_id FROM
  /// binding`，「有激活音源」再加 `WHERE is_active = 1`。子查询为空时
  /// `NOT IN` 天然返回全部行，与旧逻辑一致。
  Future<List<SongRow>> getAllExcluding(
    String notInSubSelect, {
    int limit = 100,
  }) async {
    final rows = await db.query(
      Tables.song,
      where: 'id NOT IN ($notInSubSelect)',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(SongRow.fromMap).toList();
  }

  /// 按标题 + 歌手模糊搜索（本地曲库搜索框用）
  Future<List<SongRow>> search(String keyword, {int limit = 50}) async {
    if (keyword.trim().isEmpty) return getAll(limit: limit);
    final kw = '%${keyword.trim()}%';
    final rows = await db.query(
      Tables.song,
      where: 'title LIKE ? OR artists LIKE ? OR album LIKE ?',
      whereArgs: [kw, kw, kw],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(SongRow.fromMap).toList();
  }

  Future<int> count() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.song}');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> delete(int id) async {
    await db.delete(Tables.song, where: 'id = ?', whereArgs: [id]);
  }
}
