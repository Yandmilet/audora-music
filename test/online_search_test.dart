/// 在线搜索契约测试。
///
/// ## 这个测试锁的是什么
/// 「搜 QQ 音乐 → 展示 → 一键导入」这条链路里，有一个和 E23 同源的隐患：
/// 搜索结果如果只返回领域 `Song`，真实 `songMid` 就在边界上丢掉了，
/// 导入时只能派生 `local:` —— 歌进得了库、能匹配音源，但**歌词静默失效**。
///
/// 所以这里断言三件事，缺一不可：
///   1. 搜索结果**必须**带真实 songMid（不是 `local:` 派生）
///   2. 搜索是**只读**的，不落库（曲库不该被搜索污染）
///   3. 导入后库里那行的 mid 就是 QQ 的真实 mid（歌词才取得到）
library;

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/db/rows.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/qqmusic/qqmusic_dto.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('searchOnline', () {
    late AppDatabase db;
    late _StubQQ qq;
    late LibraryRepository repo;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:online$seq?mode=memory&cache=shared',
      );
      qq = _StubQQ();
      repo = LibraryRepository(db: db, engine: _NoopEngine(), qq: qq);
    });

    tearDown(() async => db.close());

    test('空关键词不打接口', () async {
      final r = await repo.searchOnline('   ');
      expect(r, isEmpty);
      expect(qq.searchCalls, 0,
          reason: '空关键词应在前置检查就返回，不该浪费一次远端请求');
    });

    test('结果带真实 songMid，且不是 local: 派生', () async {
      final r = await repo.searchOnline('无名的人');

      expect(r, isNotEmpty);
      for (final e in r) {
        expect(e.songMid, isNotEmpty);
        expect(e.songMid, isNot(startsWith('local:')),
            reason: '在线搜索结果丢了真实 mid，导入后歌词必然取不到');
      }
      expect(r.first.songMid, '0039MnYb0qxYhV');
    });

    test('搜索是只读的：不落库', () async {
      await repo.searchOnline('无名的人');
      // ★ 关键：搜索不能污染曲库。用户只搜一下看看，
      // 结果下次打开「我的」发现多了一堆没导入的歌，无法分辨。
      expect(await db.songs.getAll(), isEmpty, reason: '搜索不该写库');
    });

    test('withDetail=false 时不拉详情，省掉每首一次请求', () async {
      await repo.searchOnline('无名的人', withDetail: false);
      expect(qq.detailCalls, 0);
    });

    test('withDetail=true 时会补详情（拿精确时长/专辑）', () async {
      await repo.searchOnline('无名的人', withDetail: true);
      expect(qq.detailCalls, greaterThan(0));
    });

    test('已在库的条目被标记 inLibrary', () async {
      // 先手动把这首塞进库
      await db.songs.upsert(SongRow.fromSong(
        _song('无名的人', '毛不易', 256),
        qqSongMid: '0039MnYb0qxYhV',
        now: 1000,
      ));

      final r = await repo.searchOnline('无名的人');
      final hit = r.firstWhere((e) => e.songMid == '0039MnYb0qxYhV');
      expect(hit.inLibrary, isTrue,
          reason: '已入库的应提前标出来，否则用户点了才发现重复');
    });

    test('未在库的条目不标记 inLibrary', () async {
      final r = await repo.searchOnline('无名的人');
      expect(r.first.inLibrary, isFalse);
    });

    test('详情接口异常时退回搜索结果的粗略字段，不整条丢失', () async {
      qq.failDetail = true;
      final r = await repo.searchOnline('无名的人');
      // 详情失败不该让结果消失——标题歌手至少能看
      expect(r, isNotEmpty);
      expect(r.first.song.title, isNotEmpty);
    });
  });

  group('importOnline', () {
    late AppDatabase db;
    late LibraryRepository repo;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:onlineimp$seq?mode=memory&cache=shared',
      );
      repo = LibraryRepository(db: db, engine: _NoopEngine(), qq: _StubQQ());
    });

    tearDown(() async => db.close());

    test('导入后库里那行的 mid 就是真实 mid（歌词取得到的唯一前提）', () async {
      final results = await repo.searchOnline('无名的人');
      await repo.importOnline([results.first]);

      final row = await db.songs.getByMid('0039MnYb0qxYhV');
      expect(row, isNotNull, reason: '应按真实 mid 入库');
      expect(row!.isLocal, isFalse);
      expect(row.title, isNotEmpty);
      expect(row.albumMid, isNotEmpty, reason: 'albumMid 落了才能拼封面');
    });

    test('重复导入同一首不产生两行（唯一键 upsert）', () async {
      final results = await repo.searchOnline('无名的人');
      await repo.importOnline([results.first]);
      await repo.importOnline([results.first]);

      final all = await db.songs.getAll();
      expect(all.length, 1, reason: '同 mid 应走更新而非新增');
    });

    test('导入空列表是安全的', () async {
      expect(await repo.importOnline([]), 0);
      expect(await db.songs.getAll(), isEmpty);
    });

    test('导入后 fetchLyric 能拿到歌词（端到端串起来）', () async {
      final results = await repo.searchOnline('无名的人');
      await repo.importOnline([results.first]);

      final row = (await db.songs.getByMid('0039MnYb0qxYhV'))!;
      final lrc = await repo.fetchLyric(row.toSong());
      // 这一步是整条链路的意义所在：搜到 → 导入 → 有歌词
      expect(lrc, isNotNull);
    });
  });
}

// ── 构造辅助 ─────────────────────────────────────────────

/// 引擎桩：本测试不涉及 B站匹配，但构造需要非空 api。
class _NoopEngine extends MatchEngine {
  _NoopEngine() : super(BiliApi(BiliApiClient()));
}

/// QQ provider 桩。
///
/// 继承而非 implements：`QQMusicProvider` 的 `dio` 是 final 字段。
/// 只覆盖 search / fetchDetail / fetchLyric 三条路径。
class _StubQQ extends QQMusicProvider {
  _StubQQ() : super(dio: Dio());

  int searchCalls = 0;
  int detailCalls = 0;
  bool failDetail = false;

  static const _mid = '0039MnYb0qxYhV';

  @override
  Future<List<QQSongMeta>> search(String keyword, {int pageSize = 20}) async {
    searchCalls++;
    return const [
      QQSongMeta(
        songMid: _mid,
        title: '无名的人',
        artists: ['毛不易'],
        album: '无名的人',
        albumMid: 'albumMid001',
        interval: 256,
      ),
    ];
  }

  @override
  Future<QQSongMeta?> fetchDetail(QQSongMeta base) async {
    detailCalls++;
    if (failDetail) throw Exception('详情接口挂了');
    return base.mergeDetail({
      'mid': _mid,
      'title': '无名的人',
      'singer': [
        {'name': '毛不易'},
      ],
      'album': {'name': '无名的人', 'mid': 'albumMid001'},
      'interval': 256,
      'time_public': '2023-01-01',
    });
  }

  @override
  Future<QQLyric?> fetchLyric(String songMid) async {
    // 只认真实 mid —— 这正是要验证的不变量
    if (songMid.startsWith('local:')) return null;
    return const QQLyric(
      lrc: '[00:06.42]词：测试词人\n[00:28.88]hello',
      credits: QQCredits.empty,
    );
  }
}

Song _song(String title, String artist, int duration) =>
    Song(title: title, artist: artist, duration: duration, coverSeed: 0);
