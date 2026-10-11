/// 本机文件的线上身份补全（v12）：DAO 冷却、零成本回填、盒子编排、封面映射。
///
/// ## 这条链路在解决什么
/// 本机文件（手机自带 / app 下载）没有 albumMid 与 songMid，而**封面 URL 是
/// 从 albumMid 拼的、歌词接口只认 songMid**。所以要先按「标题+歌手+时长」
/// 去元数据源换一次身份，换到就缓存进 `local_audio`。换不到 = 继续渐变占位，
/// 断网 = 同样占位（图片拉不到时 CoverImage 会露出底下那层）。
///
/// ## 四组必须钉住的行为
/// 1. **重扫不冲掉已缓存的身份**：`upsert` 的 UPDATE 分支故意不写这三列。
///    写进去的话每次扫描都会把用户攒下来的封面清空一遍。
/// 2. **换不到要冷却，网络异常不许冷却**：前者省请求，后者是「今天没网」
///    不是「这歌不存在」，标了冷却就等于永久放弃这首歌。
/// 3. **断网早停**：连续几首请求异常就收手，不然几十首 × 每次超时 = 卡死。
/// 4. **下载条目零成本回填**：它回指的那首曲库歌往往已有真 mid，
///    根本不用打网络。
library;

import 'dart:io';

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/dao/local_audio_dao.dart';
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/data/db/schema.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/metadata_provider.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/state/local_library.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _seq = 0;

String _dbName(String tag) => 'file:meta$tag${_seq++}?mode=memory&cache=shared';

LocalAudioEntry _entry(
  String uri, {
  required String title,
  String artist = '歌手',
  LocalAudioKind kind = LocalAudioKind.local,
  int? songId,
  int durationSec = 200,
  int size = 4 << 20,
}) =>
    LocalAudioEntry(
      kind: kind,
      uri: uri,
      title: title,
      artist: artist,
      durationMs: durationSec * 1000,
      sizeBytes: size,
      firstSeen: 1000,
      lastSeen: 1000,
      songId: songId,
    );

/// 往曲库插一首歌，返回行 id。
Future<int> _seedSong(
  AppDatabase db, {
  required String mid,
  String albumMid = '',
  String title = '老歌',
}) =>
    db.songs.upsert(SongRow.fromSong(
      Song(title: title, artist: '歌手', duration: 200, coverSeed: 1),
      qqSongMid: mid,
      albumMid: albumMid,
      now: 1000,
    ));

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  late _StubMeta meta;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await AppDatabase.open(path: _dbName('repo'));
    meta = _StubMeta();
    repo = LibraryRepository(
      db: db,
      engine: _NoopEngine(),
      metadata: meta,
    );
  });

  tearDown(() async => db.close());

  group('建表与迁移（v11 → v12）', () {
    test('全新装机即有三列', () async {
      final cols = (await db.db
              .rawQuery('PRAGMA table_info(${Tables.localAudio})'))
          .map((r) => r['name'] as String)
          .toList();
      expect(cols, containsAll(['song_mid', 'album_mid', 'resolved_at']));
    });

    test('v11 老库升上来：三列补齐、默认值正确、原有行还在', () async {
      final dir = await Directory.systemTemp.createTemp('audora_v12_');
      final path = '${dir.path}/v11.db';

      // 冻结的 v11 形状（**不能**用 kCreateLocalAudioTable：它已经含 v12 的
      // 三列，用它造「旧库」等于让迁移无事可做）。
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 11,
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
          onCreate: (d, v) async {
            await d.execute('''
CREATE TABLE ${Tables.localAudio} (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('local','download')),
  uri TEXT NOT NULL UNIQUE,
  path TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  duration_ms INTEGER NOT NULL DEFAULT 0,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  mtime_sec INTEGER NOT NULL DEFAULT 0,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  song_id INTEGER,
  quality_id INTEGER NOT NULL DEFAULT 0
);''');
            await d.insert(Tables.localAudio, _entry('u-old', title: '旧条目')
                .toMap()
              ..remove('song_mid')
              ..remove('album_mid')
              ..remove('resolved_at'));
          },
        ),
      );
      await old.close();

      final up = await AppDatabase.open(path: path);
      expect(await up.db.getVersion(), kDbVersion);
      final rows = await up.localAudio.listByKind(LocalAudioKind.local);
      expect(rows, hasLength(1), reason: '迁移不该把用户已有的清单弄丢');
      expect(rows.single.uri, 'u-old');
      expect(rows.single.songMid, '');
      expect(rows.single.albumMid, '');
      expect(rows.single.resolvedAt, 0, reason: '默认值 0 = 从没试过');
      await up.close();
      await dir.delete(recursive: true);
    });
  });

  group('DAO：待办清单与冷却', () {
    test('换到过身份的条目不再进待办', () async {
      await db.localAudio.upsert(_entry('u1', title: '甲'));
      await db.localAudio.upsert(_entry('u2', title: '乙'));
      await db.localAudio.applyResolution(
        uri: 'u1',
        songMid: 'm1',
        albumMid: 'a1',
        now: 2000,
      );

      final pending = await db.localAudio.unresolved(now: 2000);
      expect(pending.map((e) => e.uri), ['u2']);
    });

    test('标过「试过但没换到」的，冷却期内不进待办', () async {
      await db.localAudio.upsert(_entry('u1', title: '甲'));
      await db.localAudio.markResolutionAttempted(uri: 'u1', now: 2000);

      expect(await db.localAudio.unresolved(now: 2000 + 60), isEmpty,
          reason: '这源上确实没有这首歌，别再白打请求');
      expect(await db.localAudio.unresolved(
            now: 2000 + 3 * 24 * 3600 + 10,
          ),
          hasLength(1),
          reason: '过了冷却期该允许再试一次');
    });

    test('重扫只更新文件信息，不冲掉已缓存的身份', () async {
      await db.localAudio.upsert(_entry('u1', title: '甲', size: 100));
      await db.localAudio.applyResolution(
        uri: 'u1',
        songMid: 'm1',
        albumMid: 'a1',
        now: 2000,
      );
      // 同一 uri 再扫一次（体积变了、first_seen 更早都不影响身份缓存）
      await db.localAudio.upsert(_entry('u1', title: '甲', size: 999));

      final row = (await db.localAudio.listByKind(LocalAudioKind.local)).single;
      expect(row.sizeBytes, 999, reason: '文件信息要跟上最新一次扫描');
      expect(row.songMid, 'm1', reason: '重扫不该把攒下的线上身份清空');
      expect(row.albumMid, 'a1');
      expect(row.resolvedAt, 2000);
    });

    test('空标题的条目不进待办（没有可搜的关键词）', () async {
      await db.localAudio.upsert(_entry('u1', title: ''));
      expect(await db.localAudio.unresolved(now: 1000), isEmpty);
    });
  });

  group('零成本回填：下载条目抄曲库那首歌', () {
    test('song_id 指向真 mid 的行 → 不请求也拿到身份', () async {
      final songId = await _seedSong(db, mid: 'realMid', albumMid: 'realAlbum');
      await db.localAudio.upsert(_entry('d1', title: '下载的歌', kind: LocalAudioKind.download, songId: songId));

      expect(await repo.backfillLocalFromSongs(), 1);
      expect(meta.batchCalls, 0, reason: '这条路一个请求都不该打');

      final row =
          (await db.localAudio.listByKind(LocalAudioKind.download)).single;
      expect(row.songMid, 'realMid');
      expect(row.albumMid, 'realAlbum');
    });

    test('行里是 local: 派生键 → 不回填（留给网络补全）', () async {
      final songId = await _seedSong(
          db, mid: SongRow.deriveMid('下载的歌', '歌手'));
      await db.localAudio.upsert(_entry('d1',
          title: '下载的歌', kind: LocalAudioKind.download, songId: songId));

      expect(await repo.backfillLocalFromSongs(), 0);
      final row =
          (await db.localAudio.listByKind(LocalAudioKind.download)).single;
      expect(row.songMid, '');
    });
  });

  group('盒子编排 syncMissingMeta', () {
    late LocalLibraryBox box;
    late int changes;

    setUp(() {
      changes = 0;
      box = LocalLibraryBox(
        repo: () => repo,
        scanPathPrefix: () => null,
        onChange: () => changes++,
      );
    });

    test('命中的写身份、没命中的记冷却，清单跟着刷新', () async {
      await db.localAudio.upsert(_entry('u-hit', title: '命中歌'));
      await db.localAudio.upsert(_entry('u-miss', title: '查无此歌'));

      meta.batch = (queries) {
        final ok = <ResolvedEntry>[];
        final bad = <BatchRejection>[];
        for (final q in queries) {
          if (q.title == '命中歌') {
            ok.add(ResolvedEntry(
              query: q,
              song: q.toSong(),
              sourceId: 'midHit',
              coverSourceId: 'albumHit',
            ));
          } else {
            bad.add(BatchRejection(q, '三重校验全部候选均不通过'));
          }
        }
        return BatchResolveResult(successes: ok, rejections: bad);
      };

      expect(await box.syncMissingMeta(), 1);

      final hit = await db.localAudio.byUri('u-hit');
      expect(hit!.songMid, 'midHit');
      expect(hit.albumMid, 'albumHit');
      expect(hit.resolvedAt, greaterThan(0));

      final miss = await db.localAudio.byUri('u-miss');
      expect(miss!.songMid, '', reason: '没命中就不该有身份');
      expect(miss.resolvedAt, greaterThan(0), reason: '但要记下试过了');

      // 清单内存态同步：封面 URL 现在能拼出来了
      await box.load();
      final song = localEntryToSong(box.localTracks.first);
      expect(song.coverUrl, contains('albumHit'));
      expect(changes, greaterThan(0), reason: '补完要通知一次 UI，否则列表不更新');
    });

    test('连续请求异常达到阈值就收手，且不落冷却标记', () async {
      for (var i = 0; i < 8; i++) {
        await db.localAudio.upsert(_entry('net$i', title: '歌$i'));
      }
      meta.batch = (queries) => BatchResolveResult(
            successes: const [],
            rejections: [
              for (final q in queries) BatchRejection(q, '请求异常：SocketException'),
            ],
          );

      expect(await box.syncMissingMeta(limit: 60), 0);
      // 收手发生在分片边界（一片 6 首），所以撞 6 下就该停，而不是 8 下全撞完
      expect(meta.totalQueries, lessThan(8),
          reason: '认定断网后剩下的不该继续撞');

      final stillPending = await db.localAudio.unresolved(now: 100000);
      expect(stillPending, hasLength(8),
          reason: '没网不是「这歌不存在」的证据，标冷却等于永久放弃');
    });

    test('再跑一次不会重复请求已有身份的条目', () async {
      await db.localAudio.upsert(_entry('u1', title: '甲'));
      meta.batch = (queries) => BatchResolveResult(
            successes: [
              for (final q in queries)
                ResolvedEntry(query: q, song: q.toSong(), sourceId: 'm-${q.title}'),
            ],
            rejections: const [],
          );

      await box.syncMissingMeta();
      final first = meta.totalQueries;
      await box.syncMissingMeta();
      expect(meta.totalQueries, first, reason: '第二轮无事可做，不该再打请求');
    });
  });

  group('映射：本机条目 → Song', () {
    test('换到 albumMid 就拼真实封面 URL，没换到是 null', () {
      final withArt = localEntryToSong(
        _entry('u1', title: '甲').withResolution(
          songMid: 'midJia',
          albumMid: '002fRO0N4FftzY',
          resolvedAt: 1000,
        ),
      );
      expect(withArt.coverUrl,
          'https://y.gtimg.cn/music/photo_new/T002R300x300M000002fRO0N4FftzY.jpg');
      expect(withArt.albumMid, '002fRO0N4FftzY');

      final bare = localEntryToSong(_entry('u2', title: '乙'));
      expect(bare.coverUrl, isNull, reason: '没身份 → UI 露出渐变占位');
      expect(bare.albumMid, isNull);
      // 占位渐变的种子仍然来自标题：断网时列表不会是空白
      expect(bare.coverSeed, '乙'.hashCode & 0xffff);
    });
  });
}

/// 元数据桩：只实现本测试用到的批量解析，记录调用次数。
class _StubMeta extends QQMusicMetadataAdapter {
  _StubMeta() : super(_StubQQ());

  /// 由用例注入：输入 queries → 编造结果
  BatchResolveResult Function(List<BatchQuery> queries)? batch;

  int batchCalls = 0;
  int totalQueries = 0;

  @override
  Future<BatchResolveResult> resolveBatch(
    List<BatchQuery> queries, {
    int durationToleranceSec = 5,
    bool withLyricCredits = false,
    void Function(int done, int total)? onProgress,
    void Function(BatchQuery query, String reason)? onReject,
  }) async {
    batchCalls++;
    totalQueries += queries.length;
    return (batch ?? (_) => const BatchResolveResult(
        successes: [], rejections: []))(queries);
  }
}

class _StubQQ extends QQMusicProvider {
  _StubQQ() : super(dio: Dio());
}

/// 引擎桩：构造需要非空 api，本测试不碰 B站匹配。
class _NoopEngine extends MatchEngine {
  _NoopEngine() : super(BiliAudioSourceAdapter(BiliApi(BiliApiClient())));
}

extension on BatchQuery {
  /// BatchQuery 只带 标题+歌手+时长，够拼出解析用的最小 Song。
  Song toSong() => Song(
        title: title,
        artist: artist,
        duration: durationSec,
        coverSeed: 0,
      );
}
