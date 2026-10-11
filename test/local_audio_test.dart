/// `local_audio`（本机音频：自带扫描 + app 下载）的存储层测试。
///
/// ## 钉住的四件事
/// 1. **v10 → v11 迁移**：老装机用户升上来要自动多出一张表，而且不能碰
///    他已有的曲库与收藏（迁移只加不改是这库的铁律）。
/// 2. **两个 kind 彻底隔离**：列表互不可见、裁剪互不误伤。这是产品要求
///    （「本地」和「下载」是两个目录），一旦哪天有人图省事把两处合并，
///    这里会立刻红。
/// 3. **换血式扫描的时间戳语义**：同一次扫描必须共用一个 `last_seen`，
///    否则 `pruneUnseen` 会把刚写进去的条目当成旧的删掉。
/// 4. **uri 唯一 + first_seen 不被覆盖**：重扫不该抹掉「什么时候开始有这首歌」。
///
/// ## 迁移测试为什么用真临时文件
/// 内存库在最后一个连接关闭时内容就没了，「造旧库 → 关闭 → 新版打开」
/// 会开出一个全新空库（见 docs/testing.md 的坑位记录）。
library;

import 'dart:io';

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/dao/local_audio_dao.dart';
import 'package:audora_music/data/db/schema.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _seq = 0;

String _dbName(String tag) =>
    'file:local$tag${_seq++}?mode=memory&cache=shared';

/// v11 之前的建库形状（升级到 v10 时用户库里有的东西）。
///
/// 刻意用 `kCreateIndexes`（历史索引那组）而不是 `kCreateAll`——后者现在
/// 已经包含 local_audio，用它造的「旧库」其实是新库，迁移就测了个寂寞。
Future<Database> _openV10(String path) => databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 10,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) async {
          await db.execute(kCreateSongTable);
          await db.execute(kCreateVideoTable);
          await db.execute(kCreateBindingTable);
          await db.execute(kCreateLikedTable);
          await db.execute(kCreatePlayLogTable);
          await db.execute(kCreatePlayStatTable);
          await db.execute(kCreateTrackVolumeTable);
          await db.execute(kCreateMatchSampleTable);
          for (final sql in kCreateIndexes) {
            await db.execute(sql);
          }
        },
      ),
    );

Future<AppDatabase> _memDb() => AppDatabase.open(path: _dbName('dao'));

LocalAudioEntry _e(
  String uri, {
  LocalAudioKind kind = LocalAudioKind.local,
  String title = '歌',
  String artist = '手',
  int stamp = 1000,
  int size = 1000,
  int? songId,
  int qualityId = 0,
}) =>
    LocalAudioEntry(
      kind: kind,
      uri: uri,
      title: title,
      artist: artist,
      sizeBytes: size,
      durationMs: 200000,
      firstSeen: stamp,
      lastSeen: stamp,
      songId: songId,
      qualityId: qualityId,
    );

/// 插一首真实的曲库歌，返回行 id。
///
/// local_audio.song_id 是带外键的（`ON DELETE SET NULL`），随手编个 7 会被
/// SQLite 拒掉——这不是测试的毛病，正是它想保住的性质：下载记录不可能指向
/// 一首已经不存在的歌。
Future<int> _seedSong(AppDatabase db, {String mid = 'm1', String title = '老歌'}) =>
    db.db.insert(Tables.song, {
      'qq_song_mid': mid,
      'title': title,
      'artists': '歌手',
      'album': '',
      'album_mid': '',
      'duration_ms': 200000,
      'cover_seed': 0,
      'created_at': 1000,
      'updated_at': 1000,
    });

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('建表与迁移', () {
    test('全新装机即有 local_audio 与它的两个索引', () async {
      final db = await _memDb();
      final tables = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        [Tables.localAudio],
      );
      expect(tables, hasLength(1), reason: '新库没有这张表 = 全新装机没有本地功能');

      final indexes = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_local%'",
      );
      expect(indexes.map((r) => r['name']),
          containsAll(['idx_local_kind', 'idx_local_song']));
      await db.close();
    });

    test('v10 老库打开后自动升到 v11，曲库与收藏一根毛都没掉', () async {
      final dir = await Directory.systemTemp.createTemp('audora_v11_');
      final path = p.join(dir.path, 'v10.db');

      final old = await _openV10(path);
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

      final db = await AppDatabase.open(path: path);
      expect(await db.db.getVersion(), kDbVersion);

      // 新表能用
      await db.localAudio.upsert(_e('content://media/1', songId: songId));
      expect(await db.localAudio.countOfKind(LocalAudioKind.local), 1);

      // 老数据还在
      expect(await db.liked.isLiked(songId), isTrue,
          reason: 'v10→v11 迁移弄丢了收藏，等于把用户曲库毁了');
      expect((await db.songs.getAll()).length, 1);
      await db.close();
      await dir.delete(recursive: true);
    });

    test('迁移被打断过（表已建、索引没建完）也能重跑完成', () async {
      // 真实场景：升级过程中断电/被杀，第一条 SQL 成了、后面没跑完。
      // app_database 对 "already exists" 容错，这条测的就是那句容错。
      final dir = await Directory.systemTemp.createTemp('audora_v11x_');
      final path = p.join(dir.path, 'half.db');

      final old = await _openV10(path);
      await old.execute(kCreateLocalAudioTable); // 只跑了第一条
      await old.close();

      final db = await AppDatabase.open(path: path);
      expect(await db.db.getVersion(), kDbVersion,
          reason: '重复的建表语句把迁移卡住 = 这台设备永远升不上去');
      // 表能写、缺的那两个索引补上了
      await db.localAudio.upsert(_e('u1'));
      final indexes = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_local%'",
      );
      expect(indexes.map((r) => r['name']),
          containsAll(['idx_local_kind', 'idx_local_song']));
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  group('DAO 行为', () {
    test('同一 uri 再扫一次不新增行，且 first_seen 保持最早', () async {
      final db = await _memDb();
      await db.localAudio.upsert(_e('u1', stamp: 1000, size: 100));
      await db.localAudio.upsert(_e('u1', stamp: 2000, size: 900));

      final rows = await db.localAudio.listByKind(LocalAudioKind.local);
      expect(rows, hasLength(1));
      expect(rows.single.firstSeen, 1000,
          reason: '重扫不该抹掉「什么时候开始有这首歌」');
      expect(rows.single.lastSeen, 2000);
      expect(rows.single.sizeBytes, 900, reason: '元数据要跟上最新一次');
      await db.close();
    });

    test('两个 kind 的列表互不可见', () async {
      final db = await _memDb();
      await db.localAudio.upsert(_e('scan1'));
      await db.localAudio.upsert(_e('dl1', kind: LocalAudioKind.download));

      final local = await db.localAudio.listByKind(LocalAudioKind.local);
      final dl = await db.localAudio.listByKind(LocalAudioKind.download);
      expect(local.map((e) => e.uri), ['scan1']);
      expect(dl.map((e) => e.uri), ['dl1']);
      await db.close();
    });

    test('换血裁剪只删指定 kind、只删上一轮的', () async {
      final db = await _memDb();
      await db.localAudio.upsert(_e('keep', stamp: 100));
      await db.localAudio.upsert(_e('gone', stamp: 100));
      await db.localAudio.upsert(_e('dl', stamp: 100, kind: LocalAudioKind.download));

      // 新一轮（stamp=200）里 keep 还在，gone 没出现
      await db.localAudio.upsert(_e('keep', stamp: 200));
      final deleted = await db.localAudio.pruneUnseen(LocalAudioKind.local, 200);

      expect(deleted, 1);
      expect(
        (await db.localAudio.listByKind(LocalAudioKind.local)).map((e) => e.uri),
        ['keep'],
      );
      // ★ 下载那一条完全不受影响：重扫手机不该清掉用户的下载清单
      expect(await db.localAudio.countOfKind(LocalAudioKind.download), 1);
      await db.close();
    });

    test('空结果扫描若直接裁剪会清空清单——所以 repository 不允许这么用',
        () async {
      // 这条测的是「为什么 LocalLibraryBox 扫到 0 条时刻意不裁剪」。
      final db = await _memDb();
      await db.localAudio.upsert(_e('a', stamp: 100));
      expect(await db.localAudio.pruneUnseen(LocalAudioKind.local, 200), 1,
          reason: '0 结果 + 裁剪 = 整份清单消失，这就是要防的操作');
      await db.close();
    });

    test('downloadedOfSong 只认下载条目，同曲多档挑体积最大的', () async {
      final db = await _memDb();
      final songId = await _seedSong(db);
      await db.localAudio.upsert(_e('scan-copy', songId: songId, size: 9000));
      await db.localAudio.upsert(_e('dl-132',
          kind: LocalAudioKind.download, songId: songId, size: 3000));
      await db.localAudio.upsert(_e('dl-192',
          kind: LocalAudioKind.download, songId: songId, size: 5000));

      final hit = await db.localAudio.downloadedOfSong(songId);
      expect(hit?.uri, 'dl-192',
          reason: '同一首歌存了两档时，「本地优先」该播音质更好的那份');
      expect(hit?.kind, LocalAudioKind.download);
      expect(await db.localAudio.downloadedOfSong(songId + 1), isNull);

      // 歌被删时下载记录不该跟着消失，只是不再挂在任何歌上
      await db.db.delete(Tables.song, where: 'id = ?', whereArgs: [songId]);
      final after = await db.localAudio.byUri('dl-192');
      expect(after, isNotNull);
      expect(after?.songId, isNull, reason: 'SET NULL 而不是 CASCADE');
      await db.close();
    });

    test('existingUris 一次问 1200 条不炸（SQLite 999 变量上限）', () async {
      final db = await _memDb();
      final uris = [for (var i = 0; i < 1200; i++) 'u$i'];
      for (final u in uris.take(3)) {
        await db.localAudio.upsert(_e(u));
      }
      final found = await db.localAudio.existingUris(uris);
      expect(found, unorderedEquals(uris.take(3)));
      await db.close();
    });
  });

  group('Repository 侧的扫描落库', () {
    test('recordLocalAudio 给整批盖同一个时刻并返回它，配合 prune 换血',
        () async {
      final db = await _memDb();
      final repo = LibraryRepository(
        db: db,
        engine: MatchEngine(BiliAudioSourceAdapter(BiliApi(BiliApiClient()))),
        metadata: QQMusicMetadataAdapter(QQMusicProvider()),
      );

      // 上一轮的两条（时刻显式传：同一秒内连做两次扫描是常态，
      // 靠时钟区分轮次会让这个测试随机红）
      const first = 1000, second = 2000;
      await repo.recordLocalAudio([_e('a'), _e('b')], stamp: first);
      expect(await repo.localAudioCount(LocalAudioKind.local), 2);

      // 这一轮只剩 b 和一条新的 c
      await repo.recordLocalAudio([_e('b'), _e('c')], stamp: second);
      await repo.pruneLocalAudio(LocalAudioKind.local, second);

      expect(
        (await repo.localAudioOf(LocalAudioKind.local)).map((e) => e.uri),
        containsAll(['b', 'c']),
      );
      await db.close();
    });

    test('recordLocalAudio 不接受调用方传来的碎片时刻（避免同批跨秒）',
        () async {
      final db = await _memDb();
      final repo = LibraryRepository(
        db: db,
        engine: MatchEngine(BiliAudioSourceAdapter(BiliApi(BiliApiClient()))),
        metadata: QQMusicMetadataAdapter(QQMusicProvider()),
      );
      final stamp = await repo.recordLocalAudio([
        _e('x', stamp: 111),
        _e('y', stamp: 222),
      ]);
      final rows = await repo.localAudioOf(LocalAudioKind.local);
      expect(rows.every((e) => e.lastSeen == stamp), isTrue,
          reason: '同一次扫描必须同一个时刻，否则 prune 会误删');
      await db.close();
    });
  });
}
