/// 收藏持久化契约测试。
///
/// ## 为什么不直接给 song 表加个 liked 列
/// 见 `schema.dart` 里 `kCreateLikedTable` 的注释。这里把这个决定的
/// **可验证后果**钉下来，最关键的一条是：
/// **重新导入同一首歌（upsert song 行）不能把用户的收藏抹掉。**
///
/// 另一个必须锁的是 **v1 → v2 迁移**：已有用户升级 app 时磁盘上是一个
/// version=1 的旧库，没有 liked 表。迁移写错的表现是「打开就崩」或
/// 「曲库变空了」——所以既要测加表成功，也要测旧数据没被破坏。
library;

import 'dart:io';

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/db/dao/liked_dao.dart';
import 'package:audora2/data/db/rows.dart';
import 'package:audora2/data/db/schema.dart';
import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/qqmusic/qqmusic_dto.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('LikedDao', () {
    late AppDatabase db;
    late LikedDao dao;
    late int songId;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:liked$seq?mode=memory&cache=shared',
      );
      dao = db.liked;
      songId = await db.songs.upsert(SongRow.fromSong(
        _song('无名的人', '毛不易', 256),
        qqSongMid: 'mid001',
        now: 1000,
      ));
    });

    tearDown(() async => db.close());

    test('like 之后 isLiked 为 true', () async {
      expect(await dao.isLiked(songId), isFalse);
      await dao.like(songId, now: 2000);
      expect(await dao.isLiked(songId), isTrue);
    });

    test('重复 like 是幂等的，且不刷新 liked_at', () async {
      await dao.like(songId, now: 2000);
      await dao.like(songId, now: 9999);
      // ★ 若用 REPLACE 实现，这里会变成 9999——「最近收藏」排序就会
      // 因为用户多点一次红心而乱跳。
      final r = await db.db.query(Tables.liked);
      expect(r.length, 1);
      expect(r.first['liked_at'], 2000);
    });

    test('unlike 之后 isLiked 为 false', () async {
      await dao.like(songId, now: 2000);
      await dao.unlike(songId);
      expect(await dao.isLiked(songId), isFalse);
    });

    test('unlike 不存在的收藏不抛异常（幂等）', () async {
      await expectLater(dao.unlike(99999), completes);
    });

    test('toggle 返回切换后的状态，且与 isLiked 一致', () async {
      expect(await dao.toggle(songId, now: 2000), isTrue);
      expect(await dao.isLiked(songId), isTrue);

      expect(await dao.toggle(songId), isFalse);
      expect(await dao.isLiked(songId), isFalse);
    });

    test('allLikedIds 返回集合语义', () async {
      final id2 = await db.songs.upsert(SongRow.fromSong(
        _song('起风了', '买辣椒也用券', 312),
        qqSongMid: 'mid002',
        now: 1000,
      ));
      await dao.like(songId, now: 2000);
      await dao.like(id2, now: 3000);

      final ids = await dao.allLikedIds();
      expect(ids, {songId, id2});
      expect(await dao.count(), 2);
    });

    test('likedIdsByRecency 按收藏时间倒序（最近在前）', () async {
      final id2 = await db.songs.upsert(SongRow.fromSong(
        _song('起风了', '买辣椒也用券', 312),
        qqSongMid: 'mid002',
        now: 1000,
      ));
      await dao.like(songId, now: 2000); // 先收藏
      await dao.like(id2, now: 3000); // 后收藏

      final ids = await dao.likedIdsByRecency();
      expect(ids, [id2, songId], reason: '后收藏的应排在前面');
    });

    test('歌被删除时收藏被级联清理，不留孤儿行', () async {
      await dao.like(songId, now: 2000);
      // 外键 CASCADE 依赖 PRAGMA foreign_keys=ON（在 open 的 onConfigure 里）
      await db.db.delete(Tables.song, where: 'id = ?', whereArgs: [songId]);
      expect(await dao.count(), 0, reason: '孤儿收藏行会越积越多');
    });
  });

  group('收藏不会被重新导入抹掉（独立表的核心价值）', () {
    late AppDatabase db;
    late LibraryRepository repo;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:likepreserve$seq?mode=memory&cache=shared',
      );
      repo = LibraryRepository(db: db, engine: _NoopEngine(), qq: _StubQQ());
    });

    tearDown(() async => db.close());

    test('upsert 同一首歌后收藏仍在', () async {
      // 1. 导入
      final results = await repo.searchOnline('无名的人');
      await repo.importOnline([results.first]);
      final row = (await db.songs.getByMid('mid001'))!;
      final id = row.id!;

      // 2. 收藏
      expect(await repo.toggleLike(id), isTrue);
      expect(await repo.likedIds(), contains(id));

      // 3. 重新导入同一首（upsert 会覆盖 song 行的所有字段）
      await repo.importOnline(results);

      // ★ 核心断言：收藏还在。若 liked 是 song 表的布尔列，
      // 这次 upsert 会把它冲成默认值 false。
      expect(await repo.likedIds(), contains(id),
          reason: '重新导入把用户的收藏抹掉了——收藏不该存在 song 表里');

      // 且没有产生第二行
      expect((await db.songs.getAll()).length, 1);
    });

    test('likedSongs 返回完整视图且保持收藏顺序', () async {
      final results = await repo.searchOnline('无名的人');
      await repo.importOnline([results.first]);
      final id = (await db.songs.getByMid('mid001'))!.id!;

      await repo.toggleLike(id);
      final list = await repo.likedSongs();

      expect(list.length, 1);
      expect(list.first.id, id);
      expect(list.first.song.title, isNotEmpty);
    });

    test('未收藏的歌不出现在 likedSongs 里', () async {
      final results = await repo.searchOnline('无名的人');
      await repo.importOnline([results.first]);
      expect(await repo.likedSongs(), isEmpty);
    });
  });

  group('v1 → v2 迁移', () {
    test('旧库（无 liked 表）打开后自动迁移，且旧数据完好', () async {
      // ⚠️ 必须用**磁盘临时文件**而不是内存库：
      // 内存库（file:xxx?mode=memory&cache=shared）在最后一个连接关闭时
      // 内容就被销毁了。这里要「造旧库 → 关闭 → 用新版本重新打开」，
      // 用内存库的话第二步会开出一个全新的空库，迁移根本没被触发。
      final dir = await Directory.systemTemp.createTemp('audora_migrate_');
      final path = p.join(dir.path, 'legacy.db');

      // ── 1. 手工造一个 v1 库：只有三张老表 ──
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) async {
            await db.execute(kCreateSongTable);
            await db.execute(kCreateVideoTable);
            await db.execute(kCreateBindingTable);
          },
        ),
      );
      // 塞一首歌，用来验证迁移不会清库
      await old.insert(Tables.song, {
        'qq_song_mid': 'legacy001',
        'title': '老歌',
        'artists': '老歌手',
        'album': '',
        'album_mid': '',
        'duration_ms': 200000,
        'cover_seed': 0,
        'created_at': 1000,
        'updated_at': 1000,
      });
      // 确认旧库确实是 v1 且没有 liked 表
      final v = await old.getVersion();
      expect(v, 1);
      await old.close();

      // ── 2. 用当前版本打开 → 触发 onUpgrade ──
      final db = await AppDatabase.open(path: path);

      // 迁移后版本应为 v2
      expect(await db.db.getVersion(), kDbVersion);

      // 迁移后 liked 表可用
      final row = await db.songs.getByMid('legacy001');
      expect(row, isNotNull, reason: '迁移不该丢用户曲库');
      final id = row!.id!;
      await db.liked.like(id, now: 2000);
      expect(await db.liked.isLiked(id), isTrue);

      // ★ 旧数据必须还在。迁移里任何 DROP TABLE 都会让这里变空。
      expect((await db.songs.getAll()).length, 1,
          reason: '迁移不该丢用户曲库');

      await db.close();
      await dir.delete(recursive: true);
    });

    test('新库直接建成 v2，liked 表存在', () async {
      final seq = _dbSeq++;
      final db = await AppDatabase.open(
        path: 'file:fresh$seq?mode=memory&cache=shared',
      );
      // 能查就说明表在
      expect(await db.liked.count(), 0);
      await db.close();
    });
  });
}

// ── 构造辅助 ─────────────────────────────────────────────

class _NoopEngine extends MatchEngine {
  _NoopEngine() : super(BiliApi(BiliApiClient()));
}

class _StubQQ extends QQMusicProvider {
  _StubQQ() : super(dio: Dio());

  @override
  Future<List<QQSongMeta>> search(String keyword, {int pageSize = 20}) async {
    return const [
      QQSongMeta(
        songMid: 'mid001',
        title: '无名的人',
        artists: ['毛不易'],
        album: '无名的人',
        albumMid: 'albumMid001',
        interval: 256,
      ),
    ];
  }

  @override
  Future<QQSongMeta?> fetchDetail(QQSongMeta base) async => base;
}

Song _song(String title, String artist, int duration) =>
    Song(title: title, artist: artist, duration: duration, coverSeed: 0);
