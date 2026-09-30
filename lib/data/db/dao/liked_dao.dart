/// LikedSong 表的读写（收藏 / 喜欢）。
///
/// ## 为什么单独一张表而不是 song 表的布尔列
/// 见 `schema.dart` 里 `kCreateLikedTable` 的说明：收藏是**用户行为**，
/// 与歌曲元数据生命周期不同。最现实的一个后果是——导入会 upsert song 行，
/// 若红心存在那张表里，重导一次歌单就会把用户攒的收藏全部抹掉。
///
/// ## 为什么不用 Song.key(title|artist) 当键
/// 那只是展示层的去重键，改名/换歌手就会失联。这里用真正的 `song_id`
/// 外键，歌被删时 CASCADE 自动清理，不留孤儿行。
library;

import 'package:sqflite/sqflite.dart';

import '../schema.dart';

class LikedDao {
  LikedDao(this.db);

  final DatabaseExecutor db;

  /// 标记收藏。重复收藏不报错也不刷新时间（幂等）。
  ///
  /// 用 `INSERT OR IGNORE` 而非 `REPLACE`：后者会先删后插，
  /// 在开启外键的情况下会触发一次无谓的 CASCADE 检查；
  /// 更重要的是——重复点红心不该把 `liked_at` 冲掉，
  /// 否则「最近收藏」排序会随每次点击乱跳。
  Future<void> like(int songId, {int? now}) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.insert(
      Tables.liked,
      {'song_id': songId, 'liked_at': ts},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 取消收藏。本来就没收藏也不报错。
  Future<void> unlike(int songId) async {
    await db.delete(Tables.liked, where: 'song_id = ?', whereArgs: [songId]);
  }

  /// 切换收藏状态，返回切换后是否已收藏。
  ///
  /// 用 `where` 的删除行数判断当前状态，避免「先查再写」之间的竞态。
  Future<bool> toggle(int songId, {int? now}) async {
    final deleted =
        await db.delete(Tables.liked, where: 'song_id = ?', whereArgs: [songId]);
    if (deleted > 0) return false;
    await like(songId, now: now);
    return true;
  }

  /// 是否已收藏
  Future<bool> isLiked(int songId) async {
    final rows = await db.query(
      Tables.liked,
      columns: ['song_id'],
      where: 'song_id = ?',
      whereArgs: [songId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 全部已收藏的 song_id。
  ///
  /// 返回 Set 而非 List：调用方拿它做 `contains` 判断来渲染红心，
  /// 列表在这场景下每次渲染都是 O(n)。
  Future<Set<int>> allLikedIds() async {
    final rows = await db.query(Tables.liked, columns: ['song_id']);
    return rows.map((r) => r['song_id'] as int).toSet();
  }

  /// 已收藏的 song_id，**按收藏时间倒序**（最近收藏在前）。
  ///
  /// 与 [allLikedIds] 的区别是带顺序：收藏列表页要用它保持「最近收藏靠前」，
  /// 而红心渲染只需要集合语义。
  Future<List<int>> likedIdsByRecency({int limit = 500}) async {
    final rows = await db.query(
      Tables.liked,
      columns: ['song_id'],
      orderBy: 'liked_at DESC',
      limit: limit,
    );
    return rows.map((r) => r['song_id'] as int).toList();
  }

  /// 收藏总数
  Future<int> count() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.liked}');
    return (r.first['c'] as int?) ?? 0;
  }

  /// 清空（调试 / 测试用）
  Future<void> clear() async {
    await db.delete(Tables.liked);
  }
}
