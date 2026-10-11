/// 「浏览点歌即播」的回归测试：persistOnline / playOnline。
///
/// ## 这个文件在防什么
/// 浏览优先形态下，用户从榜单/歌手/歌单点一首歌，链路是：
///
///     playOnline → persistOnline（静默入库拿 id）→ playQueue → 按需匹配
///
/// 这条链有三个**不抛异常、只是行为不对**的失败模式：
///
///   1. 榜单里同一首歌出现多次（榜单聚合多版本），入库不去重的话
///      队列里有两份相同的歌，「下一首」会原地踏步
///   2. 点第 N 首却从第 1 首开始播 —— 去重后 index 错位
///   3. 重复点同一批歌，库里行数翻倍 —— upsert 语义被破坏
///
/// 三者都静默发生，只有行为断言能抓。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 假 B站 API：任何搜索都返回空池。
///
/// playOnline → playQueue 会触发按需匹配；本文件只关心**入库与队列**，
/// 匹配环节让它正常失败即可（返回 null、不抛异常）——这同时验证了
/// 「匹配失败不破坏播放意图」的容错路径。绝不发真网络请求。
class _EmptyBili extends BiliApi {
  _EmptyBili() : super(BiliApiClient());
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late LibraryRepository repo;
  late AppState st;
  var seq = 0;

  /// 每个测试一个独立的内存库（不能用 inMemoryDatabasePath，见
  /// on_demand_match_test 里的说明——共享缓存会让数据互相漏）。
  Future<void> boot() async {
    db = await AppDatabase.open(
      path: 'file:onlineplay${seq++}?mode=memory&cache=shared',
    );
    repo = LibraryRepository(
      db: db,
      engine: MatchEngine(BiliAudioSourceAdapter(_EmptyBili())),
      metadata: QQMusicMetadataAdapter(QQMusicProvider()),
    );
    st = AppState(repo: repo);
  }

  tearDown(() async {
    st.dispose();
    await db.close();
  });

  /// 造一条在线目录歌曲（模拟 fromCatalogJson 出来的东西）
  OnlineSong item(String title, String artist,
      {String mid = '', int dur = 256}) {
    final m = mid.isEmpty ? 'MID$title$artist' : mid;
    return OnlineSong(
      song: Song(title: title, artist: artist, duration: dur, coverSeed: 1),
      songMid: m,
      albumMid: 'ALB$m',
    );
  }

  group('persistOnline：静默入库', () {
    test('入库返回带 id 的 Song（id 是收藏/统计/匹配的凭据）', () async {
      await boot();
      final songs = await repo.persistOnline([
        item('晴天', '周杰伦'),
        item('起风了', '买辣椒也用券'),
      ]);

      expect(songs.length, 2);
      for (final s in songs) {
        expect(s.id, isNotNull, reason: '入库后必须有 id');
        expect(s.id!, greaterThan(0));
      }
    });

    test('同批重复项去重保序（榜单聚合多版本的兜底）', () async {
      await boot();
      final songs = await repo.persistOnline([
        item('晴天', '周杰伦', mid: 'MID_QINGTIAN'),
        item('起风了', '买辣椒也用券'),
        item('晴天', '周杰伦', mid: 'MID_QINGTIAN'), // 重复：同一 mid
      ]);

      expect(songs.length, 2, reason: '同 mid 的歌只应出现一次');
      expect(songs[0].title, '晴天', reason: '去重必须保序');
      expect(songs[1].title, '起风了');
    });

    test('重复入库不增加行数（upsert 语义）', () async {
      await boot();
      final batch = [item('晴天', '周杰伦'), item('起风了', '买辣椒也用券')];
      await repo.persistOnline(batch);
      final count1 = (await repo.listSongs()).length;

      await repo.persistOnline(batch);
      final count2 = (await repo.listSongs()).length;

      expect(count2, count1, reason: '同一批歌再入库，行数不能翻倍');
    });
  });

  group('playOnline：点哪首播哪首', () {
    test('队列 = 整批歌，current = 点击的那首', () async {
      await boot();
      final items = [
        item('晴天', '周杰伦'),
        item('起风了', '买辣椒也用券'),
        item('无名的人', '毛不易'),
      ];

      await st.playOnline(items, 2);

      expect(st.queue.length, 3);
      expect(st.current!.title, '无名的人',
          reason: '点第 3 首就应播第 3 首，而不是从第 1 首开始');
      expect(st.index, 2);
    });

    test('点击项在队列里的位置与它在列表里的位置一致', () async {
      await boot();
      final items = [
        item('晴天', '周杰伦'),
        item('起风了', '买辣椒也用券'),
        item('晴天', '周杰伦'), // 与第 1 首同 mid → 去重后错位
      ];

      // 点的是「第 3 个位置」，但它和第 1 首是同一首歌。
      // 去重保序后队列里晴天在前，点击项应落到第 1 个位置。
      await st.playOnline(items, 2);

      expect(st.current!.title, '晴天');
      expect(st.index, 0, reason: '按 key 对齐到去重后的位置');
    });

    test('★ 点歌后 refreshLibrary 完成，current 仍是点击的那首（迷你条回归）',
        () async {
      await boot();
      final items = [
        item('晴天', '周杰伦'),
        item('起风了', '买辣椒也用券'),
        item('无名的人', '毛不易'),
      ];

      // playOnline 内部是 unawaited(refreshLibrary()) + 同步 playQueue。
      // await playOnline 返回时 refreshLibrary 大概率仍在跑（真机上必然），
      // 等 100ms 让它与 playQueue 的并发时序充分暴露。
      await st.playOnline(items, 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(st.current!.title, '无名的人',
          reason: 'refreshLibrary 与 playQueue 并发时，'
              'current 不能被改回上一首或第 0 首——'
              '否则迷你播放条显示的就不是刚点的歌');
      // refreshLibrary 重建队列后采用曲库排序，index 不必等于点击位置，
      // 但必须指向 current 本身（队列与 current 不能失联）。
      expect(st.queue[st.index].key, st.current!.key);
    });

    test('repo 为 null（单测/预览）时安全返回，不抛异常', () async {
      final bare = AppState();
      st = bare; // 交给 tearDown 统一 dispose，避免双重 dispose
      // mock 模式下队列预填了 mock 曲库；playOnline 应当原样不动
      final before = bare.queue.length;
      await bare.playOnline([item('晴天', '周杰伦')], 0);
      expect(bare.queue.length, before);
    });
  });

  group('activateBestCandidate：点播时的 REVIEW 兜底', () {
    /// 直接插一条候选绑定（模拟 matchOne 存下的 REVIEW 候选）。
    ///
    /// ⚠️ binding 表有**两个**外键：song_id → song、bvid → bilibili_video。
    /// 只插 song 不插 video 的话，binding 的 INSERT 会 FK 失败（787）——
    /// 第一次写这个测试就踩了，报错只说 constraint failed 不说是哪个键。
    Future<void> seedBinding(int songId, String bvid, double score,
        {bool active = false}) async {
      await db.videos.upsert(VideoRow(
        bvid: bvid,
        cid: 100,
        title: '候选视频 $bvid',
        fetchedAt: 1,
      ));
      await db.bindings.upsert(BindingRow(
        songId: songId,
        bvid: bvid,
        matchScore: score,
        confidence: MatchConfidence.review,
        matchType: MatchType.autoMatched,
        matchedAt: 1,
        isActive: active,
      ));
    }

    Future<int> seedSong(String title) {
      return db.songs.upsert(SongRow.fromSong(
        Song(title: title, artist: '某歌手', duration: 240, coverSeed: 2),
        qqSongMid: 'MID$title',
      ));
    }

    test('激活最高分的 REVIEW 候选（宁播相似版本，不静默失败）', () async {
      await boot();
      final songId = await seedSong('如诗一般的形容妳');
      await seedBinding(songId, 'BV1LOW', 0.656);
      await seedBinding(songId, 'BV1HIGH', 0.810); // 最高分但低于 AUTO 0.82
      await seedBinding(songId, 'BV1MID', 0.791);

      final ok = await repo.activateBestCandidate(songId);

      expect(ok, isTrue, reason: '0.81 >= 0.60 底线，应当激活');
      final active = await db.bindings.getActive(songId);
      expect(active, isNotNull);
      expect(active!.bvid, 'BV1HIGH', reason: '必须激活分数最高的那条');
    });

    test('全部候选低于底线时拒绝激活（低分候选大概率不是这首歌）', () async {
      await boot();
      final songId = await seedSong('无名的人');
      await seedBinding(songId, 'BV1BAD', 0.45);

      expect(await repo.activateBestCandidate(songId), isFalse);
      expect(await db.bindings.getActive(songId), isNull,
          reason: '拒绝激活时不能动任何绑定');
    });

    test('没有任何候选时返回 false', () async {
      await boot();
      final songId = await seedSong('游爱场');
      expect(await repo.activateBestCandidate(songId), isFalse);
    });

    test('★ 激活唯一性：新激活会顶掉旧的激活绑定', () async {
      await boot();
      final songId = await seedSong('幻火');
      // 先有一条已激活的（比如人工确认过的）
      await db.videos.upsert(const VideoRow(
        bvid: 'BV1OLD',
        cid: 101,
        title: '旧候选',
        fetchedAt: 1,
      ));
      await db.bindings.upsert(BindingRow(
        songId: songId,
        bvid: 'BV1OLD',
        matchScore: 0.70,
        confidence: MatchConfidence.review,
        matchType: MatchType.manualBound,
        matchedAt: 1,
        isActive: true,
      ));
      await seedBinding(songId, 'BV1NEW', 0.85);

      await repo.activateBestCandidate(songId);

      final actives = (await db.bindings.getCandidates(songId))
          .where((b) => b.isActive)
          .toList();
      expect(actives.length, 1,
          reason: '同首歌最多一条激活 —— 这是设计红线，兜底激活也必须遵守');
      expect(actives.single.bvid, 'BV1NEW');
    });
  });
}
