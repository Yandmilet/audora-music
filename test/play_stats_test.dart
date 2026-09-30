/// 播放历史与播放次数统计的契约测试。
///
/// ## 要钉死的三件事
/// 1. **计数门限**：点开又秒切不算一次播放。不设门限的话「常听」会退化成
///    「最近点开过什么」，失去意义。
/// 2. **两张表同事务**：流水与聚合必须一致。分开写会出现「最近播放里有它、
///    常听榜里没有」这种自相矛盾的状态。
/// 3. **裁剪流水不影响统计**：`play_log` 会无限增长需要定期裁，
///    但裁掉流水不该让「听了 100 次」缩水。
library;

import 'dart:io';

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/db/dao/play_stats_dao.dart';
import 'package:audora2/data/db/rows.dart';
import 'package:audora2/data/db/schema.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
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

  group('PlayStatsDao 计数门限', () {
    late AppDatabase db;
    late PlayStatsDao dao;
    late int songId;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:plays$seq?mode=memory&cache=shared',
      );
      dao = db.plays;
      songId = await db.songs.upsert(SongRow.fromSong(
        _song('无名的人', '毛不易', 256),
        qqSongMid: 'mid001',
        now: 1000,
      ));
    });

    tearDown(() async => db.close());

    test('没听够门限：进流水但不计次数', () async {
      await dao.recordPlay(songId, playedMs: 5 * 1000, now: 2000);

      final stat = await dao.statOf(songId);
      expect(stat, isNotNull);
      expect(stat!.playCount, 0, reason: '听 5 秒不该算「听过」');
      // 但「最近播放」要能看到它——用户确实点开过
      expect(await dao.recentlyPlayedSongIds(), [songId]);
      expect(stat.lastPlayedAt, 2000);
    });

    test('听够门限：计一次', () async {
      await dao.recordPlay(
        songId,
        playedMs: PlayStatsDao.countingThresholdMs,
        now: 2000,
      );
      expect((await dao.statOf(songId))!.playCount, 1);
    });

    test('正好差 1 毫秒不算（边界）', () async {
      await dao.recordPlay(
        songId,
        playedMs: PlayStatsDao.countingThresholdMs - 1,
        now: 2000,
      );
      expect((await dao.statOf(songId))!.playCount, 0);
    });

    test('多次播放累加次数与总时长', () async {
      for (var i = 0; i < 3; i++) {
        await dao.recordPlay(songId, playedMs: 60 * 1000, now: 2000 + i);
      }
      final stat = (await dao.statOf(songId))!;
      expect(stat.playCount, 3);
      expect(stat.totalPlayedMs, 3 * 60 * 1000);
      expect(stat.lastPlayedAt, 2002, reason: '应更新为最后一次时间');
    });

    test('未达门限的播放也会刷新 last_played_at', () async {
      await dao.recordPlay(songId, playedMs: 60 * 1000, now: 2000);
      await dao.recordPlay(songId, playedMs: 2 * 1000, now: 3000);
      final stat = (await dao.statOf(songId))!;
      expect(stat.playCount, 1, reason: '第二次没听够不算');
      expect(stat.lastPlayedAt, 3000, reason: '但「最近播放」要跟着更新');
    });

    test('没有记录时 statOf 返回 null', () async {
      expect(await dao.statOf(songId), isNull);
    });
  });

  group('常听排行', () {
    late AppDatabase db;
    late PlayStatsDao dao;
    late int a;
    late int b;
    late int c;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:top$seq?mode=memory&cache=shared',
      );
      dao = db.plays;
      a = await db.songs.upsert(SongRow.fromSong(
        _song('A', 'x', 200), qqSongMid: 'midA', now: 1000));
      b = await db.songs.upsert(SongRow.fromSong(
        _song('B', 'y', 200), qqSongMid: 'midB', now: 1000));
      c = await db.songs.upsert(SongRow.fromSong(
        _song('C', 'z', 200), qqSongMid: 'midC', now: 1000));
    });

    tearDown(() async => db.close());

    test('按播放次数倒序', () async {
      // A 听 3 次，B 听 1 次，C 听 2 次
      for (var i = 0; i < 3; i++) {
        await dao.recordPlay(a, playedMs: 60000, now: 2000 + i);
      }
      await dao.recordPlay(b, playedMs: 60000, now: 2100);
      await dao.recordPlay(c, playedMs: 60000, now: 2200);

      final top = await dao.topPlayed();
      expect(top.map((s) => s.songId).toList(), [a, c, b]);
    });

    test('minCount 过滤掉只听过一两次的', () async {
      await dao.recordPlay(a, playedMs: 60000, now: 2000);
      for (var i = 0; i < 3; i++) {
        await dao.recordPlay(b, playedMs: 60000, now: 2100 + i);
      }

      expect((await dao.topPlayed(minCount: 3)).map((s) => s.songId), [b]);
      expect((await dao.topPlayed(minCount: 2)).map((s) => s.songId), [b]);
      expect((await dao.topPlayed(minCount: 1)).length, 2);
    });

    test('次数相同时按最近播放倒序（打破平局）', () async {
      await dao.recordPlay(a, playedMs: 60000, now: 2000);
      await dao.recordPlay(b, playedMs: 60000, now: 5000);
      // 都是 1 次，B 更近 → B 在前
      expect((await dao.topPlayed()).map((s) => s.songId).toList(), [b, a]);
    });

    test('没听够门限的歌不上常听榜', () async {
      await dao.recordPlay(a, playedMs: 3000, now: 2000);
      expect(await dao.topPlayed(), isEmpty);
    });
  });

  group('最近播放', () {
    late AppDatabase db;
    late PlayStatsDao dao;
    late int a;
    late int b;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:recent$seq?mode=memory&cache=shared',
      );
      dao = db.plays;
      a = await db.songs.upsert(SongRow.fromSong(
        _song('A', 'x', 200), qqSongMid: 'midA', now: 1000));
      b = await db.songs.upsert(SongRow.fromSong(
        _song('B', 'y', 200), qqSongMid: 'midB', now: 1000));
    });

    tearDown(() async => db.close());

    test('同一首歌反复播放只出现一次（按歌去重）', () async {
      for (var i = 0; i < 5; i++) {
        await dao.recordPlay(a, playedMs: 60000, now: 2000 + i);
      }
      // ★ 不去重的话「最近播放」会被同一首歌排满整屏
      expect(await dao.recentlyPlayedSongIds(), [a]);
    });

    test('按最后播放时间倒序', () async {
      await dao.recordPlay(a, playedMs: 60000, now: 2000);
      await dao.recordPlay(b, playedMs: 60000, now: 3000);
      expect(await dao.recentlyPlayedSongIds(), [b, a]);

      // A 又播了一次 → 应排到最前
      await dao.recordPlay(a, playedMs: 60000, now: 4000);
      expect(await dao.recentlyPlayedSongIds(), [a, b]);
    });

    test('未达门限的播放也出现在最近播放里', () async {
      await dao.recordPlay(a, playedMs: 1000, now: 2000);
      expect(await dao.recentlyPlayedSongIds(), [a]);
    });
  });

  group('流水裁剪不影响统计（两张表分工的核心价值）', () {
    late AppDatabase db;
    late PlayStatsDao dao;
    late int songId;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:trim$seq?mode=memory&cache=shared',
      );
      dao = db.plays;
      songId = await db.songs.upsert(SongRow.fromSong(
        _song('A', 'x', 200), qqSongMid: 'midA', now: 1000));
    });

    tearDown(() async => db.close());

    test('裁剪流水后 play_count 不缩水', () async {
      for (var i = 0; i < 50; i++) {
        await dao.recordPlay(songId, playedMs: 60000, now: 2000 + i);
      }
      expect((await dao.statOf(songId))!.playCount, 50);

      // 只保留最近 10 条流水
      final removed = await dao.trimLog(keep: 10);
      expect(removed, 40);
      expect((await dao.recentLogs()).length, 10);

      // ★ 聚合表不受影响——否则「听了 50 次」会变成「听了 10 次」
      expect((await dao.statOf(songId))!.playCount, 50,
          reason: '裁流水不该动统计');
      expect((await dao.topPlayed()).first.playCount, 50);
    });

    test('清空历史时两张表一起清', () async {
      await dao.recordPlay(songId, playedMs: 60000, now: 2000);
      await dao.clearAll();
      expect(await dao.statOf(songId), isNull);
      expect(await dao.recentLogs(), isEmpty);
      expect(await dao.topPlayed(), isEmpty);
    });

    test('歌被删除时播放记录被级联清理', () async {
      await dao.recordPlay(songId, playedMs: 60000, now: 2000);
      await db.db.delete(Tables.song, where: 'id = ?', whereArgs: [songId]);
      expect(await dao.statOf(songId), isNull);
      expect(await dao.recentLogs(), isEmpty);
    });
  });

  group('Repository 层的歌曲视图', () {
    late AppDatabase db;
    late LibraryRepository repo;
    late int songId;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:playrepo$seq?mode=memory&cache=shared',
      );
      repo = LibraryRepository(db: db, engine: _NoopEngine(), qq: _StubQQ());
      songId = await db.songs.upsert(SongRow.fromSong(
        _song('无名的人', '毛不易', 256),
        qqSongMid: 'mid001',
        now: 1000,
      ));
    });

    tearDown(() async => db.close());

    test('topPlayedSongs 返回完整视图且保持次数序', () async {
      final id2 = await db.songs.upsert(SongRow.fromSong(
        _song('起风了', '买辣椒也用券', 312),
        qqSongMid: 'mid002',
        now: 1000,
      ));
      for (var i = 0; i < 3; i++) {
        await repo.recordPlay(id2, playedMs: 60000);
      }
      await repo.recordPlay(songId, playedMs: 60000);

      final list = await repo.topPlayedSongs();
      expect(list.length, 2);
      expect(list.first.id, id2, reason: '听得多的排前面');
      expect(list.first.song.title, '起风了');
    });

    test('recentlyPlayedSongs 保持最近时间序', () async {
      final id2 = await db.songs.upsert(SongRow.fromSong(
        _song('起风了', '买辣椒也用券', 312),
        qqSongMid: 'mid002',
        now: 1000,
      ));
      // ⚠️ 显式给 now：不给的话两次调用会落在同一秒（秒级时间戳），
      // 排序就取决于 SQLite 的稳定顺序而不是「谁更近」，测出来是随机结果。
      await db.plays.recordPlay(songId, playedMs: 60000, now: 2000);
      await db.plays.recordPlay(id2, playedMs: 60000, now: 3000);

      final list = await repo.recentlyPlayedSongs();
      expect(list.map((e) => e.id).toList(), [id2, songId]);
    });

    test('没有播放记录时两个列表都为空（不报错）', () async {
      expect(await repo.topPlayedSongs(), isEmpty);
      expect(await repo.recentlyPlayedSongs(), isEmpty);
    });

    test('playStatOf 能取到单首统计', () async {
      await repo.recordPlay(songId, playedMs: 60000);
      final stat = await repo.playStatOf(songId);
      expect(stat, isNotNull);
      expect(stat!.playCount, 1);
    });
  });

  group('v2 → v3 迁移', () {
    test('旧库（无播放表）打开后自动迁移，且收藏数据完好', () async {
      final dir = await Directory.systemTemp.createTemp('audora_v3_');
      final path = p.join(dir.path, 'v2.db');

      // ── 1. 造一个 v2 库（有 liked，无 play_*）──
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, v) async {
            await db.execute(kCreateSongTable);
            await db.execute(kCreateVideoTable);
            await db.execute(kCreateBindingTable);
            await db.execute(kCreateLikedTable);
          },
        ),
      );
      final songId = await old.insert(Tables.song, {
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
      await old.insert(Tables.liked, {'song_id': songId, 'liked_at': 1500});
      await old.close();

      // ── 2. 用当前版本打开 → 触发 v2→v3 迁移 ──
      final db = await AppDatabase.open(path: path);
      expect(await db.db.getVersion(), kDbVersion);

      // 新的播放表可用
      await db.plays.recordPlay(songId, playedMs: 60000, now: 2000);
      expect((await db.plays.statOf(songId))!.playCount, 1);

      // ★ 收藏必须还在：迁移只加表，不该碰 v2 的数据
      expect(await db.liked.isLiked(songId), isTrue,
          reason: 'v2→v3 迁移把收藏弄丢了');
      expect((await db.songs.getAll()).length, 1);

      await db.close();
      await dir.delete(recursive: true);
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
  Future<List<QQSongMeta>> search(String keyword, {int pageSize = 20}) async =>
      const [];

  @override
  Future<QQSongMeta?> fetchDetail(QQSongMeta base) async => base;
}

Song _song(String title, String artist, int duration) =>
    Song(title: title, artist: artist, duration: duration, coverSeed: 0);
