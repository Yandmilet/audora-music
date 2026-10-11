/// Song 表的读写。
library;

import 'package:sqflite/sqflite.dart';

import '../rows.dart';
import '../schema.dart';

/// 「排除口径」：哪些歌算「已处理过」、要从队列里排除。
///
/// ## 为什么用 enum 而不是直接传子查询字符串
/// 旧签名是 `getAllExcluding(String notInSubSelect)`，把调用方给的
/// 字符串**原样拼进 WHERE**：`id NOT IN ($notInSubSelect)`。
/// 当时只有两个调用方、都传常量，所以不可利用；但这个 API 本身就是个
/// 注入 sink —— 将来任何一处传入用户 / 接口派生的内容都是真实的 SQL 注入。
///
/// 口径本来就只有两种，穷举成 enum 之后：拼接点在 DAO 内部唯一、
/// 全部是编译期常量，调用方不可能再拼出注入。枚举名同时也是
/// 「这个列表到底按什么口径排除」的自文档。
enum ExcludeScope {
  /// 有**任何**绑定记录（含 REVIEW 待确认）→ 判据见 `unmatchedQueue`。
  ///
  /// 用 DISTINCT：同一首歌可能有多条候选绑定，不去重会让 NOT IN 子查询
  /// 里出现重复值（不影响结果，但白白变慢）。
  anyBinding,

  /// 有**激活**绑定（`is_active = 1`）→ 判据见「批量匹配」队列。
  ///
  /// REVIEW 级候选不激活，但批量匹配仍要跑（重匹配可能升到 AUTO），
  /// 所以这条口径与 [anyBinding] 刻意不同。
  activeBinding,
}

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
  (qq_song_mid, meta_source_type, meta_source_id,
   title, artists, album, album_mid, lyricist, composer,
   arranger, genre, release_date, duration_ms, cover_seed,
   lyric_offset_ms, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(qq_song_mid) DO UPDATE SET
  meta_source_type = excluded.meta_source_type,
  meta_source_id   = excluded.meta_source_id,
  title            = excluded.title,
  artists          = excluded.artists,
  album            = excluded.album,
  album_mid        = excluded.album_mid,
  lyricist         = excluded.lyricist,
  composer         = excluded.composer,
  arranger         = excluded.arranger,
  genre            = excluded.genre,
  release_date     = excluded.release_date,
  duration_ms      = excluded.duration_ms,
  cover_seed       = excluded.cover_seed,
  updated_at       = excluded.updated_at
''', [
          r.qqSongMid,
          r.metaSourceType,
          r.metaSourceId.isEmpty ? r.qqSongMid : r.metaSourceId,
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
          // lyric_offset_ms 仅在首次插入时写入；冲突时保留库中原值，
          // 避免批量导入把用户手动校准的偏移静默覆盖
          r.lyricOffsetMs,
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

/// 取「id 不在所选口径的绑定表里」的歌，按 `created_at DESC` 排序。
///
/// ## 为什么必须是 SQL 下推，而不是拉全表 + Dart 过滤
/// 旧写法 `getAll(limit: limit * 4)` 再在 Dart 里差集：曲库一旦超过
/// limit×4 首（未匹配队列 400 / 批量匹配 200），排在后面的歌**永远
/// 进不了队列**——列表看起来是全的，实际在静默漏歌。
///
/// 子查询为空时 `NOT IN` 天然返回全部行，与旧逻辑一致。
Future<List<SongRow>> getAllExcluding(
  ExcludeScope scope, {
  int limit = 100,
}) async {
  // ⚠️ 这里用 whereArgs 传表名会更「干净」，但表名不能参数化
  // （SQLite 不允许绑定标识符）。折中办法是把全部合法取值枚举成
  // [ExcludeScope]，让本 switch 成为**唯一**的拼接点且全为常量。
  final String subSelect;
  switch (scope) {
    case ExcludeScope.anyBinding:
      subSelect = 'SELECT DISTINCT song_id FROM ${Tables.binding}';
    case ExcludeScope.activeBinding:
      subSelect = 'SELECT song_id FROM ${Tables.binding} WHERE is_active = 1';
  }

  final rows = await db.query(
    Tables.song,
    where: 'id NOT IN ($subSelect)',
    orderBy: 'created_at DESC',
    limit: limit,
  );
  return rows.map(SongRow.fromMap).toList();
  }

  /// 按标题 + 歌手模糊搜索（本地曲库搜索框用）
  ///
  /// ## ⚠️ LIKE 必须转义 `%` / `_` / 转义符本身
  /// SQL 的 LIKE 把 `%` 当通配符、`_` 当单字符通配符。直接
  /// `'%$keyword%'` 拼的话，用户搜 `%` 会匹配到全部歌曲、搜 `a_b`
  /// 会把 `axb` 也算命中——搜索结果与用户输入不符。
  ///
  /// 这里的值仍然是**参数化**传入的（不构成注入），但要让它按字面量
  /// 匹配，就得先用 ESCAPE 子句声明转义符，并把用户输入里的转义符本身
  /// 一起转义掉，否则搜 `\` 会反过来破坏模式串。
  Future<List<SongRow>> search(String keyword, {int limit = 50}) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return getAll(limit: limit);

    const escape = r'\';
    final kw = '%${_escapeLike(trimmed, escape)}%';
    final rows = await db.query(
      Tables.song,
      where: r'''title LIKE ? ESCAPE '\' OR artists LIKE ? ESCAPE '\' '''
          r'''OR album LIKE ? ESCAPE '\' ''',
      whereArgs: [kw, kw, kw],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(SongRow.fromMap).toList();
  }

  /// 转义 LIKE 模式里的通配符，使其按字面量匹配。
  ///
  /// 必须连 [escape] 本身一起转义（`ESCAPE` 的标准要求）：
  /// 否则用户输入的 `\` 会把紧随其后的 `%` 或 `_` 还原成通配符。
  static String _escapeLike(String input, String escape) {
    final sb = StringBuffer();
    for (final ch in input.split('')) {
      if (ch == '%' || ch == '_' || ch == escape) {
        sb.write(escape);
      }
      sb.write(ch);
    }
    return sb.toString();
  }

  Future<int> count() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.song}');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> delete(int id) async {
    await db.delete(Tables.song, where: 'id = ?', whereArgs: [id]);
  }

  /// 定向更新歌词校准偏移（毫秒）。
  ///
  /// 只改 lyric_offset_ms 一列，不触发整行 upsert（避免覆盖其他字段）。
  /// 由 AppState.adjustLyricOffset / resetLyricOffset 调用。
  Future<void> updateLyricOffset(int songId, int offsetMs) async {
    await db.update(
      Tables.song,
      {
        'lyric_offset_ms': offsetMs,
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      where: 'id = ?',
      whereArgs: [songId],
    );
  }
}
