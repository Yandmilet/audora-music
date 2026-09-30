/// 数据链路集成测试：Repository ↔ AppState。
///
/// 覆盖的是**最容易出错、单测覆盖不到**的那段：从数据库读出 → 装配成
/// `SongWithSource` → 变成 UI 看到的状态。之前 `durationDelta` 漏减歌曲时长、
/// `SongWithSource.id` 两个来源不一致，都是这一层的问题。
library;

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/db/rows.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/services/bilibili/bili_dto.dart';
import 'package:audora2/services/match/match_config.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/match/match_scorer.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:audora2/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late LibraryRepository repo;

  // 每个测试用**独立的内存库文件**。
  //
  // ⚠️ 不能用 inMemoryDatabasePath：在 sqflite_common_ffi 下它等价于
  // file::memory:?cache=shared，同一进程内所有测试共享同一个库。
  // tearDown 里 db.close() 并不会真正销毁它（只要还有别的连接/缓存活着），
  // 于是上一个测试的数据会漏到下一个测试，表现为"数量比预期多 1"。
  var dbSeq = 0;

  setUp(() async {
    // 名字里带 unique 序号，保证互不干扰；db.close() 时自动消失
    db = await AppDatabase.open(path: 'file:itest$dbSeq?mode=memory&cache=shared');
    dbSeq++;
    // 匹配引擎在这里不会被真正调用（测试不联网），
    // 但 Repository 的构造需要它，所以装一个指向本地 Dio 的实例
    final client = BiliApiClient();
    repo = LibraryRepository(
      db: db,
      engine: MatchEngine(BiliApi(client)),
      qq: QQMusicProvider(),
    );
  });

  tearDown(() async => db.close());

  /// 造一首歌 + 一个视频 + 一条激活绑定。
  ///
  /// [bvid] 默认由歌名派生，保证不同调用的视频互不冲突。
  /// ⚠️ 别让多个 seedSong 共用同一个 bvid —— 表上 `UNIQUE(song_id, bvid)`
  /// 加上 `ON DELETE CASCADE`，早期用 replace 写入时曾把别的歌的绑定连带删掉。
  Future<int> seedSong({
    String title = '秘密',
    String artist = '白浩寅',
    int durSec = 226,
    bool withSource = true,
    int videoDurSec = 228,
    double score = 0.95,
    String? bvid,
  }) async {
    final songId = await db.songs.upsert(SongRow.fromSong(
      Song(title: title, artist: artist, duration: durSec, coverSeed: 3),
      qqSongMid: SongRow.deriveMid(title, artist),
    ));

    if (withSource) {
      final id = bvid ?? 'BV_${title}_$artist';
      await db.videos.upsert(VideoRow(
        bvid: id,
        cid: 784756939,
        title: '$artist - $title',
        author: '白浩寅',
        durationMs: videoDurSec * 1000,
        typename: '音乐',
        playCount: 500000,
        fetchedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        audioQualityId: 30280,
      ));
      await db.bindings.upsert(BindingRow(
        songId: songId,
        bvid: id,
        isActive: true,
        matchScore: score,
        confidence: MatchScorer.grade(score),
        scoreDetail: BindingRow.detailToJson(const ScoreDetail(
          s1TitleArtist: 1.0,
          s2Duration: 0.92,
          s3Uploader: 0.95,
          s4Publish: 1.0,
          s5Category: 0.6,
          s6Format: 0.8,
        )),
        matchType: MatchType.autoMatched,
        matchedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ));
    }
    return songId;
  }

  group('Repository → SongWithSource 装配', () {
    test('listSongs 带出 id、音源与时长差', () async {
      await seedSong();

      final list = await repo.listSongs();
      expect(list.length, 1);

      final item = list.first;
      // id 必须非空 —— 否则重匹配/确认无法落库
      expect(item.id, isNotNull);
      expect(item.id, greaterThan(0));
      expect(item.song.title, '秘密');
      expect(item.song.id, item.id, reason: 'song.id 与 item.id 必须一致');

      final src = item.source!;
      expect(src.bvid, 'BV_秘密_白浩寅');
      expect(src.cid, 784756939);
      expect(src.qualityLabel, '192Kbps');
      expect(src.auto, isTrue);
      // 关键回归：durationDelta = 视频时长 - 歌曲时长 = 228 - 226 = 2
      expect(src.durationDelta, 2);
    });

    test('无音源的歌也能读出（source 为 null）', () async {
      await seedSong(withSource: false);
      final list = await repo.listSongs();
      expect(list.length, 1);
      expect(list.first.source, isNull);
      expect(list.first.song.sourceStatus, SourceStatus.none);
      expect(list.first.id, isNotNull);
    });

    test('REVIEW 级绑定的状态是 pending、auto 为 false', () async {
      await seedSong(score: 0.70);
      final item = (await repo.listSongs()).first;
      expect(item.song.sourceStatus, SourceStatus.pending);
      expect(item.source!.auto, isFalse);
    });

    test('searchLocal 命中题目/歌手', () async {
      await seedSong(title: '秘密', artist: '白浩寅');
      await seedSong(title: '起风了', artist: '买辣椒也用券');

      expect((await repo.searchLocal('秘密')).length, 1);
      expect((await repo.searchLocal('白浩寅')).length, 1);
      expect((await repo.searchLocal('不存在')).length, 0);
    });

    test('stats 反映真实统计', () async {
      await seedSong(title: 'A', artist: 'X', score: 0.95);
      await seedSong(title: 'B', artist: 'Y', score: 0.70);
      final s = await repo.stats();
      expect(s.songCount, 2);
      expect(s.autoCount, 1);
      expect(s.reviewCount, 1);
    });

    test('reviewQueue / unmatchedQueue 分流正确', () async {
      await seedSong(title: 'A', artist: 'X', score: 0.95); // AUTO
      await seedSong(title: 'B', artist: 'Y', score: 0.70); // REVIEW
      await seedSong(title: 'C', artist: 'Z', withSource: false); // 未匹配

      // 待确认 = 恰好 REVIEW 那一条（AUTO 的不该出现，未匹配的也不该出现）
      final review = await repo.reviewQueue();
      expect(review.length, 1);
      expect(review.first.song.title, 'B');

      // 待匹配 = 恰好「完全没有候选」的 C 一条。
      // ★ 回归：B 是 REVIEW 却有 binding，绝不能同时出现在两个列表里。
      final unmatched = await repo.unmatchedQueue();
      expect(unmatched.length, 1);
      expect(unmatched.first.song.title, 'C');
    });
  });

  group('AppState ↔ Repository', () {
    test('loadLibrary 把 DB 内容读进 library', () async {
      await seedSong(title: '秘密', artist: '白浩寅');
      final st = AppState(repo: repo);

      // 接入数据层后、loadLibrary 之前：应该是空的（不再预填 mock）
      expect(st.usingMock, isFalse, reason: '接了 repo 就不该走 mock');
      expect(st.library, isEmpty, reason: '加载前还没读到 DB，应为空');

      await st.loadLibrary();

      expect(st.loadState, LibraryLoadState.ready);
      expect(st.library.length, 1);
      expect(st.library.first.title, '秘密');
      expect(st.library.first.id, isNotNull);
      st.dispose();
    });

    test('空库就是空库，不再用 mock 兜底', () async {
      final st = AppState(repo: repo);
      await st.loadLibrary();

      expect(st.loadState, LibraryLoadState.ready);
      // ⚠️ 这是刻意为之的行为变更：早期版本空库会塞 30 首演示歌，
      // 导致用户完全分不清数据真假（搜索像能用、导入看不出效果）。
      // 现在空就诚实地空着，由 UI 显示空状态并引导导入。
      expect(st.library, isEmpty);
      expect(st.libraryEmpty, isTrue);
      expect(st.usingMock, isFalse, reason: '空库不等于 mock 模式');
      st.dispose();
    });

    test('pendingCount 来自 REVIEW 队列真实条数', () async {
      await seedSong(title: 'A', artist: 'X', score: 0.95);
      await seedSong(title: 'B', artist: 'Y', score: 0.70);
      await seedSong(title: 'C', artist: 'Z', score: 0.68);

      final st = AppState(repo: repo);
      await st.loadLibrary();

      expect(st.pendingCount, 2);
      st.dispose();
    });

    test('confirmSource 落库并刷新曲库（修掉原 rematch bug）', () async {
      final songId = await seedSong(title: 'B', artist: 'Y', score: 0.70);

      final st = AppState(repo: repo);
      await st.loadLibrary();
      expect(st.library.first.sourceStatus, SourceStatus.pending);
      expect(st.pendingCount, 1);

      // 人工确认为 AUTO 级
      final ok = await st.confirmSource(
        songId: songId,
        bvid: 'BV_B_Y',
        score: 0.93,
      );
      expect(ok, isTrue);

      // 关键验证：曲库状态已更新（原实现只改队列副本，这里是真落库）
      expect(st.library.first.sourceStatus, SourceStatus.ok);
      expect(st.library.first.source!.auto, isTrue);
      expect(st.pendingCount, 0, reason: '确认后待确认数应归零');

      // 且数据库里确实改了
      final active = await db.bindings.getActive(songId);
      expect(active!.matchType, MatchType.manualBound);
      expect(active.matchScore, 0.93);
      st.dispose();
    });

    test('loadReviewQueue 返回可操作的 SongWithSource（带 id）', () async {
      await seedSong(title: 'B', artist: 'Y', score: 0.70);
      final st = AppState(repo: repo);
      await st.loadLibrary();

      final queue = await st.loadReviewQueue();
      expect(queue.length, 1);
      // id 非空才能调 confirmSource
      expect(queue.first.id, isNotNull);
      st.dispose();
    });

    test('refreshLibrary 保留当前播放位置', () async {
      await seedSong(title: '秘密', artist: '白浩寅');
      await seedSong(title: '起风了', artist: '买辣椒也用券');

      final st = AppState(repo: repo);
      await st.loadLibrary();
      expect(st.library.length, 2);

      // 播到第二首
      st.playQueue(st.library, 1);
      final playing = st.current!.title;

      // 新增一首后刷新
      await seedSong(title: '新歌', artist: '新歌手');
      await st.refreshLibrary();

      expect(st.library.length, 3);
      expect(st.current!.title, playing, reason: '刷新后应仍在同一首');
      st.dispose();
    });

    test('未接入数据层时 loadLibrary 安全返回', () async {
      final st = AppState(); // repo = null
      await st.loadLibrary();
      expect(st.loadState, LibraryLoadState.idle);
      expect(st.library, isNotEmpty);
      expect(st.usingMock, isTrue);
      st.dispose();
    });
  });

  group('真实匹配落库（不联网，验证写库与去重路径）', () {
    test('saveCandidates 存候选但不激活，activate 后唯一激活', () async {
      final songId = await seedSong(title: '秘密', artist: '白浩寅', withSource: false);

      // 手动造两个候选（绕过网络）
      const detail = ScoreDetail(
        s1TitleArtist: 1,
        s2Duration: 1,
        s3Uploader: 0.5,
        s4Publish: 1,
        s5Category: 0.6,
        s6Format: 0.8,
      );
      await db.videos
          .upsert(const VideoRow(bvid: 'BVhi', cid: 1, title: 'a', fetchedAt: 1));
      await db.videos
          .upsert(const VideoRow(bvid: 'BVlo', cid: 2, title: 'b', fetchedAt: 1));

      await db.bindings.saveCandidates(songId: songId, candidates: [
        const ScoredCandidate(
          video: VideoCandidate(bvid: 'BVhi', title: 'a', durationSec: 226),
          total: 0.95,
          detail: detail,
          confidence: MatchConfidence.auto,
        ),
        const ScoredCandidate(
          video: VideoCandidate(bvid: 'BVlo', title: 'b', durationSec: 226),
          total: 0.70,
          detail: detail,
          confidence: MatchConfidence.review,
        ),
      ]);

      // 候选写入了但都没激活
      expect((await db.bindings.getCandidates(songId)).length, 2);
      expect(await db.bindings.getActive(songId), isNull);

      // 激活高分那条
      await db.bindings.activate(songId, 'BVhi');
      final active = await db.bindings.getActive(songId);
      expect(active!.bvid, 'BVhi');

      // 通过 Repository 读出来应是 AUTO
      final item = (await repo.listSongs()).first;
      expect(item.source!.bvid, 'BVhi');
      expect(item.song.sourceStatus, SourceStatus.ok);
    });
  });
}
