/// lyric_mid_test —— 锁死「真实 songMid 必须落库」这条不变量。
///
/// ## 这个测试为什么存在
/// 曾出过产品级缺陷：批量导入时 `importFromKeywords` 恒走 refId / `local:`
/// 派生分支，把 QQ音乐解析出的**真实 songMid 丢弃**。后果是 `fetchLyric`
/// 里 `mid.startsWith('local:')` 直接返回 null —— 曲库看起来正常、能匹配
/// 音源，但**歌词静默命中 0 首**，而且没有任何报错。
///
/// 这类缺陷用「接口能不能通」的集成测试抓不到（接口本身是通的），
/// 必须断言**落库后的 mid 字段**。所以这里用真实内存 SQLite 走完整链路，
/// 只把 QQ 返回的数据换成桩。
library;

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/db/rows.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora2/services/qqmusic/qqmusic_dto.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:audora2/services/source/bili_audio_source_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  setUpAll(() {
    // 桌面/测试环境没有 Android 的 sqflite 原生实现，必须换成 FFI
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SongRow.deriveMid / isLocal', () {
    test('派生 mid 带 local: 前缀，且忽略首尾空格', () {
      final a = SongRow.deriveMid('无名的人', '毛不易');
      final b = SongRow.deriveMid('  无名的人 ', '毛不易');
      expect(a, startsWith('local:'));
      // 首尾空格应被去掉，保证同一首歌不会派生两个键
      expect(a, b);
    });

    test('local: 前缀被判定为 isLocal', () {
      final row = _row(qqSongMid: SongRow.deriveMid('foo', 'bar'));
      expect(row.isLocal, isTrue);
    });

    test('真实 songMid 不被误判为 local', () {
      final row = _row(qqSongMid: '0039MnYb0qxYhV');
      expect(row.isLocal, isFalse);
    });
  });

  group('ResolvedEntry', () {
    test('同时携带 sourceId(=QQ songMid) 与 coverSourceId(=QQ albumMid)', () {
      final e = ResolvedEntry(
        query: const BatchQuery(title: '无名的人', artist: '毛不易'),
        song: _song('无名的人', '毛不易', 256),
        sourceId: '004Z8Ihr0JIu5s',
        coverSourceId: '002fRO0N4FftzY',
      );
      expect(e.sourceId, '004Z8Ihr0JIu5s');
      expect(e.coverSourceId, '002fRO0N4FftzY');
      expect(e.toString(), contains('004Z8Ihr0JIu5s'));
    });
  });

  group('BatchResolveResult', () {
    test('songs 投影与各项计数一致', () {
      final r = BatchResolveResult(
        successes: [
          ResolvedEntry(
            query: const BatchQuery(title: 'a', artist: 'b'),
            song: _song('a', 'b', 100),
            sourceId: 'mid1',
          ),
          ResolvedEntry(
            query: const BatchQuery(title: 'c', artist: 'd'),
            song: _song('c', 'd', 200),
            sourceId: 'mid2',
          ),
        ],
        rejections: const [
          BatchRejection(BatchQuery(title: 'e', artist: 'f'), '时长不符'),
        ],
      );
      expect(r.songs.length, 2);
      expect(r.successCount, 2);
      expect(r.rejectedCount, 1);
      expect(r.total, 3);
      expect(r.successRate, closeTo(2 / 3, 1e-9));
      expect(r.songs.first.title, 'a');
    });

    test('空结果不除零', () {
      const r = BatchResolveResult(successes: [], rejections: []);
      expect(r.successRate, 0);
      expect(r.total, 0);
    });
  });

  group('SongDao 落库 / 回查 mid', () {
    late AppDatabase db;

    setUp(() async {
      // 用唯一文件路径代替 inMemoryDatabasePath：
      // 后者等价 `file::memory:?cache=shared`，多个测试会共享同一个库，
      // 上一条测试留下的行会污染下一条。
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:lyricmid$seq?mode=memory&cache=shared',
      );
    });

    tearDown(() async => db.close());

    test('upsert 后能按真实 mid 回查，且 isLocal 为 false', () async {
      final id = await db.songs.upsert(SongRow.fromSong(
        _song('无名的人', '毛不易', 256),
        qqSongMid: '004Z8Ihr0JIu5s',
        albumMid: '002fRO0N4FftzY',
        now: 1000,
      ));

      final row = await db.songs.getById(id);
      expect(row, isNotNull);
      expect(row!.qqSongMid, '004Z8Ihr0JIu5s');
      expect(row.albumMid, '002fRO0N4FftzY');
      // ★ 核心断言：真实 mid 必须能通过 fetchLyric 的前置检查
      expect(row.isLocal, isFalse,
          reason: '落库 mid 若是 local: 前缀，歌词会被静默跳过');
    });

    test('upsertAll 保留每首歌各自的真实 mid，不会串号', () async {
      final ids = await db.songs.upsertAll([
        SongRow.fromSong(_song('a', 'x', 100), qqSongMid: 'midAAA', now: 1000),
        SongRow.fromSong(_song('b', 'y', 200), qqSongMid: 'midBBB', now: 1000),
      ]);
      expect(ids.length, 2);

      final a = await db.songs.getById(ids[0]);
      final b = await db.songs.getById(ids[1]);
      expect(a!.qqSongMid, 'midAAA');
      expect(b!.qqSongMid, 'midBBB');
    });
  });

  group('LibraryRepository.fetchLyric 的前置判定', () {
    late AppDatabase db;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:lyricfetch$seq?mode=memory&cache=shared',
      );
    });

    tearDown(() async => db.close());

    test('无 id 的 Song 直接返回 null（mock 数据）', () async {
      final repo = LibraryRepository(
        db: db,
        engine: _NoopEngine(),
        metadata: QQMusicMetadataAdapter(_StubQQ()),
      );
      expect(await repo.fetchLyric(_song('x', 'y', 1)), isNull);
    });

    test('local: 前缀的 mid 不发起网络请求', () async {
      final id = await db.songs.upsert(SongRow.fromSong(
        _song('x', 'y', 1),
        qqSongMid: SongRow.deriveMid('x', 'y'),
        now: 1000,
      ));

      final stub = _StubQQ();
      final repo = LibraryRepository(
        db: db,
        engine: _NoopEngine(),
        metadata: QQMusicMetadataAdapter(stub),
      );
      final song = (await db.songs.getById(id))!.toSong();

      expect(await repo.fetchLyric(song), isNull);
      // ★ 关键：local: 的歌根本不该打歌词接口（省一次无用请求）
      expect(stub.lyricCalls, 0,
          reason: 'local: 前缀应在前置检查里就返回，不应穿透到 provider');
    });

    test('真实 mid 会真正打到 provider 并返回歌词', () async {
      final id = await db.songs.upsert(SongRow.fromSong(
        _song('x', 'y', 1),
        qqSongMid: 'realMid123',
        now: 1000,
      ));

      final stub = _StubQQ();
      final repo = LibraryRepository(
        db: db,
        engine: _NoopEngine(),
        metadata: QQMusicMetadataAdapter(stub),
      );
      final song = (await db.songs.getById(id))!.toSong();

      final bundle = await repo.fetchLyric(song);
      expect(bundle!.lrc, '[00:01.00]hello');
      expect(stub.lyricCalls, 1);
      expect(stub.lastMid, 'realMid123');
    });
  });
}

// ── 构造辅助 ─────────────────────────────────────────────

/// Song 的 `coverSeed` 是 required，测试里统一补 0。
Song _song(String title, String artist, int duration) =>
    Song(title: title, artist: artist, duration: duration, coverSeed: 0);

SongRow _row({required String qqSongMid}) => SongRow(
      qqSongMid: qqSongMid,
      title: 'foo',
      artists: 'bar',
      album: '',
      albumMid: '',
      lyricist: null,
      composer: null,
      arranger: null,
      genre: null,
      releaseDate: null,
      durationMs: 0,
      coverSeed: 0,
      createdAt: 0,
      updatedAt: 0,
    );

/// 引擎桩：本测试不涉及 B站匹配，但构造需要非空 api。
class _NoopEngine extends MatchEngine {
  _NoopEngine() : super(BiliAudioSourceAdapter(BiliApi(BiliApiClient())));
}

/// QQ provider 桩：只统计歌词调用，返回固定 LRC。
///
/// 继承而非 implements：`QQMusicProvider` 的 `dio` 是 final 字段，
/// implements 得把整套 HTTP 逻辑重写一遍；继承后只覆盖歌词这一条路径，
/// 其余方法真被调用到会走真实网络（本测试不会走到）。
class _StubQQ extends QQMusicProvider {
  _StubQQ() : super(dio: Dio());

  int lyricCalls = 0;
  String? lastMid;

  @override
  Future<QQLyric?> fetchLyric(String songMid) async {
    lyricCalls++;
    lastMid = songMid;
    return const QQLyric(lrc: '[00:01.00]hello', credits: QQCredits.empty);
  }
}
