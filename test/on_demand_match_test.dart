/// 「按需匹配」的回归测试：首次播放一首还没匹配的歌，只匹配**这一首**。
///
/// ## 这个文件在防什么
/// 曲库里没音源的歌，原先在点击播放时会直接失败：
///
///     SourceResolver.resolve → '这首歌还没有匹配到音源'
///
/// 于是「导入完想听第一首」必须先去「我的」页点批量匹配，等 6~7 分钟
/// （20 首 × 10 次请求 ÷ 30 次/分钟限流）。用户把这段时间体验成「卡住」。
///
/// 改成「点哪首匹配哪首」后，**首首可播时间从 6~7 分钟降到约 20 秒**，
/// 而且总请求量更少 —— 不听的歌根本不会被匹配。
///
/// ## 为什么必须用断言锁住，而不是靠人肉验证
/// 这个改动有两个**不抛异常、只是行为不对**的失败模式：
///
///   1. 匹配好了，但播放队列里还是旧对象 → 播放页一直显示「无音源」
///      （可歌明明已经能播），而且下一首续播会再匹配一次、白等 20 秒
///   2. 已经有音源的歌被重新匹配 → 白烧 10 次请求的限流配额
///
/// 两者都静默发生，只有行为断言能抓。所以这里测的是**请求次数**与
/// **对象是否被就地替换**，而不是「功能能不能用」。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 假 B站 API：不发网络请求，只记账，并为**任何**一首歌回一条吻合的音源。
///
/// 继承 + override 而不是引入接口 —— `MatchEngine` 只依赖 [BiliApi] 的
/// 两个方法，覆盖掉就够，不必为了测试在生产代码里加抽象层。
class _FakeBili extends BiliApi {
  _FakeBili({this.returnEmptyPool = false}) : super(BiliApiClient());

  /// 所有测试歌曲的时长都取这个值，好让搜索结果能过 Stage 2 的 ±30 秒粗筛。
  static const fakeDurationSec = 256;

  /// true 时模拟「B站 搜不到任何结果」
  final bool returnEmptyPool;

  /// Stage 1 搜索请求次数
  int searchCalls = 0;

  /// Stage 3 详情请求次数
  int detailCalls = 0;

  /// 每次搜索前的回调。用于在**匹配进行中**观察 AppState 的状态
  /// （「等待可见」这条需求只能在过程中验证，事后看不到）。
  void Function()? onSearch;

  /// 每首歌一个 bvid，避免多首歌共用同一个视频行（表上有 UNIQUE(bvid)）
  final Map<String, String> _bvidOf = {};
  final Map<String, ({String title, String artist})> _metaOf = {};

  String _bvidFor(String title, String artist) {
    return _bvidOf.putIfAbsent('$title|$artist', () {
      final bvid = 'BV1ND${_bvidOf.length.toString().padLeft(3, '0')}';
      _metaOf[bvid] = (title: title, artist: artist);
      return bvid;
    });
  }

  @override
  Future<List<VideoCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int maxRetries = 3,
  }) async {
    searchCalls++;
    onSearch?.call();
    if (returnEmptyPool) return const [];

    // 从查询词反推「歌名 歌手」，回一条标题与时长都吻合的候选。
    // 查询路是 Q1「歌名 歌手」/ Q2「歌名」/ Q3「歌名 歌手 无损」，
    // 结果按 bvid 去重且 **Q1 优先**，所以这里按 Q1 的解析结果造候选即可。
    final parts = keyword.split(' ');
    final title = parts.first;
    final artist = parts.length > 1 ? parts[1] : '';

    return [
      VideoCandidate(
        bvid: _bvidFor(title, artist),
        // 「歌手 - 歌名」标准格式会让标题维度直接拿满分（设计文档 4.6.2）
        title: artist.isEmpty ? title : '$artist - $title',
        author: artist,
        mid: 999,
        durationSec: fakeDurationSec,
        play: 500000,
        pubdate: 1600000000,
      ),
    ];
  }

  @override
  Future<VideoDetail?> fetchVideoDetail(String bvid) async {
    detailCalls++;
    final meta = _metaOf[bvid];
    if (meta == null) return null;

    return VideoDetail(
      bvid: bvid,
      cid: 7001,
      title: '${meta.artist} - ${meta.title}',
      ownerName: meta.artist,
      ownerMid: 999,
      // 详情才带分区 —— 这正是 Stage 3 存在的理由之一
      tname: '音乐',
      durationSec: fakeDurationSec,
      playCount: 500000,
      pubdate: 1600000000,
      pages: [
        VideoPage(
          cid: 7001,
          page: 1,
          part: meta.title,
          durationSec: fakeDurationSec,
        ),
      ],
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late LibraryRepository repo;
  late AppState st;
  late _FakeBili lastApi;
  var seq = 0;

  /// 每个测试一个独立的内存库。
  ///
  /// ⚠️ 不能用 `inMemoryDatabasePath`：在 sqflite_common_ffi 下它等价于
  /// `file::memory:?cache=shared`，同一进程内所有测试**共享同一个库**，
  /// 上一个用例的数据会漏进来（表现为「数量比预期多」）。
  ///
  /// 重复调用前请先 `st.dispose()` + `db.close()`，否则会留下没关的库。
  Future<void> boot({bool emptyPool = false}) async {
    final api = _FakeBili(returnEmptyPool: emptyPool);
    db = await AppDatabase.open(
      path: 'file:ondemand${seq++}?mode=memory&cache=shared',
    );
    repo = LibraryRepository(
      db: db,
      engine: MatchEngine(BiliAudioSourceAdapter(api)),
      // 本文件不会真的取歌词，但 Repository 的构造需要它。
      // 注意 fetchLyric 会先看 qq_song_mid 是否带 `local:` 前缀——
      // 这里派生出来的 mid 正是 `local:`，所以永远不会打到网络上。
      metadata: QQMusicMetadataAdapter(QQMusicProvider()),
    );
    st = AppState(repo: repo);
    lastApi = api;
  }

  setUp(() => boot());
  tearDown(() async {
    st.dispose();
    await db.close();
  });

  /// 只在 song 表插一行 —— **不建任何音源绑定**，即「刚导入、还没匹配」。
  ///
  /// 时长固定取 [_FakeBili.fakeDurationSec]，否则假的搜索结果过不了
  /// Stage 2 的 ±30 秒时长粗筛，匹配会被硬过滤掉、测不出真实行为。
  Future<int> seedUnmatched({
    String title = '秘密',
    String artist = '白浩寅',
    int durSec = _FakeBili.fakeDurationSec,
  }) {
    return db.songs.upsert(SongRow.fromSong(
      Song(title: title, artist: artist, duration: durSec, coverSeed: 3),
      qqSongMid: SongRow.deriveMid(title, artist),
    ));
  }

  group('ensurePlayableSource：没音源就现匹配', () {
    test('无音源的歌会被现匹配，返回带音源的对象', () async {
      final id = await seedUnmatched();
      await st.loadLibrary();
      expect(st.queue.single.source, isNull, reason: '前提：这首歌还没有音源');

      final fresh = await st.ensurePlayableSource(st.queue.single);

      expect(fresh, isNotNull, reason: '应当匹配成功');
      expect(fresh!.id, id);
      expect(fresh.source, isNotNull);
      expect(fresh.source!.bvid, isNotEmpty);
      expect(lastApi.searchCalls, greaterThan(0), reason: '确实发出过搜索请求');
      // 详情请求必须被 enrichTopK 兜住，否则速度会退回「每候选一次请求」
      expect(lastApi.detailCalls, lessThanOrEqualTo(3));
    });

    test('★ 匹配成功后播放队列里的旧对象被就地替换', () async {
      // 这是最容易漏的一步：`matchOne` 只写数据库，不会改内存里的对象。
      // 不同步的话，播放页的音源徽标会一直显示「无音源」，
      // 而且下一首续播拿到的还是旧对象 → 又白等 20 秒重新匹配一次。
      await seedUnmatched();
      await st.loadLibrary();

      final before = st.queue.single;
      expect(before.source, isNull);

      await st.ensurePlayableSource(before);

      expect(st.queue.single.source, isNotNull,
          reason: '队列里必须已经是带音源的新对象');
      expect(st.queue.single.source!.bvid, isNotEmpty);
      expect(identical(st.queue.single, before), isFalse,
          reason: '必须是新对象，不能还是匹配前那个');
    });

    test('就地替换不动队列结构与播放位置', () async {
      await seedUnmatched(title: '秘密', artist: '白浩寅');
      await seedUnmatched(title: '无名的人', artist: '毛不易');
      await seedUnmatched(title: '起风了', artist: '买辣椒也用券');
      await st.loadLibrary();
      expect(st.queue.length, 3);

      // 先把播放位置挪到第 2 首 —— 位置为 0 时「有没有被重置」看不出来
      st.playQueue(st.queue, 1);
      expect(st.index, 1);
      final currentKey = st.current!.key;
      final indexBefore = st.index;

      await st.ensurePlayableSource(st.current!);

      expect(st.queue.length, 3, reason: '队列不能被整表重建');
      expect(st.index, indexBefore, reason: '播放位置不能被重置');
      expect(st.current!.key, currentKey, reason: '当前歌不能被换掉');
      expect(st.current!.source, isNotNull);
    });

    test('已经有音源的歌不会被重复匹配（0 次请求）', () async {
      // 匹配一首要 10 次请求 / 约 20 秒。这里若不做前置判断，
      // 每次播放都会白烧一份限流配额，速度会莫名其妙地掉回去。
      final id = await seedUnmatched();
      await repo.matchOne(id); // 先正常匹配一次，让这首歌有音源
      await st.loadLibrary();
      expect(st.queue.single.source, isNotNull);

      final api = lastApi;
      final searchesBefore = api.searchCalls;
      final detailsBefore = api.detailCalls;

      final fresh = await st.ensurePlayableSource(st.queue.single);

      expect(fresh, isNotNull);
      expect(api.searchCalls, searchesBefore, reason: '不该再发搜索请求');
      expect(api.detailCalls, detailsBefore, reason: '不该再发详情请求');
    });

    test('没有数据层（repo 为 null）时安静返回 null，不抛异常', () async {
      final bare = AppState(); // repo == null
      const song = Song(
        id: 1,
        title: '秘密',
        artist: '白浩寅',
        duration: 256,
        coverSeed: 1,
      );
      expect(await bare.ensurePlayableSource(song), isNull);
      bare.dispose();
    });

    test('歌曲没有 id（未落库）时返回 null，不抛异常', () async {
      await st.loadLibrary();
      const notPersisted = Song(
        title: '秘密',
        artist: '白浩寅',
        duration: 256,
        coverSeed: 1,
      );
      expect(await st.ensurePlayableSource(notPersisted), isNull);
    });

    test('匹配不到音源时返回 null，而不是抛异常', () async {
      // 先收掉 setUp 建的那一份，再换一个「搜不到结果」的引擎
      st.dispose();
      await db.close();
      await boot(emptyPool: true);
      await seedUnmatched();
      await st.loadLibrary();

      // 「这首没找到音源」是正常结果，不是错误 —— 抛异常会让
      // 播放链路整个断掉，用户看到的是崩溃而不是一句提示。
      expect(await st.ensurePlayableSource(st.queue.single), isNull);
    });
  });

  group('等待反馈（20 秒不能是静默的）', () {
    test('匹配期间 matchingOnDemand 为真，且带歌名', () async {
      await seedUnmatched();
      await st.loadLibrary();

      bool? flagDuringSearch;
      String? titleDuringSearch;
      lastApi.onSearch = () {
        flagDuringSearch = st.matchingOnDemand;
        titleDuringSearch = st.onDemandMatchTitle;
      };

      await st.ensurePlayableSource(st.queue.single);

      expect(flagDuringSearch, isTrue, reason: '搜索发出时就应该已经在提示「正在匹配」');
      expect(titleDuringSearch, '秘密', reason: '提示里要带歌名，否则用户不知道在等哪首');
    });

    test('匹配结束后 matchingOnDemand 复位，状态条不会一直挂着', () async {
      await seedUnmatched();
      await st.loadLibrary();

      await st.ensurePlayableSource(st.queue.single);

      expect(st.matchingOnDemand, isFalse);
      expect(st.onDemandMatchTitle, isNull);
    });
  });

  group('队列对象陈旧（refreshLibrary 的回归）', () {
    test('★ 刷新后队列持有的是最新对象，而不是匹配前的旧对象', () async {
      // 场景：用户在曲库页点了「批量匹配音源」，匹配完成后调 refreshLibrary。
      // `sameAsBefore` 只看「长度 + 首曲 key」—— 这些都没变，
      // 于是队列被原样保留，里面却还是**匹配前**的对象。
      final id = await seedUnmatched();
      await st.loadLibrary();
      expect(st.queue.single.source, isNull);

      // 模拟「批量匹配跑完了这一首」
      await repo.matchOne(id);
      await st.refreshLibrary();

      expect(st.queue.single.source, isNotNull,
          reason: '音源刚匹配出来，队列里的对象必须跟着更新');
      expect(st.library.single.source, isNotNull);
      expect(st.queue.single.key, st.library.single.key);
    });
  });
}
