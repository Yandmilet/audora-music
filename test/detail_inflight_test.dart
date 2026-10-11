/// 详情缓存的**在途去重**回归测试。
///
/// ## 防什么缺陷（2026-10-07 审计）
/// `_detailOf` 原本是「先查缓存 -> 没命中就 await 请求 -> 写缓存」。
/// 缓存只在**请求返回后**才写入，所以两个 `match()` 重叠且都命中同一 bvid 时，
/// 两路会**同时**读到缓存 miss 并各发一次请求：缓存形同虚设，
/// 还把 30 次/分钟的限流额度白烧一份。
///
/// ## 注意：它防的是「跨歌并发」，不是「同一首歌内重复」
/// 单次 `match()` 内部，Stage 1 的 `_mergeAndTrim` 已按 bvid 用
/// `merged.putIfAbsent(...)` 去重，同一首歌的候选池里不会有两条同 bvid。
/// 真正会重叠的是**跨歌**场景：批量匹配循环里相邻两首歌命中同一个合集视频、
/// 或点播重解析与批量匹配撞上同一个 bvid —— 它们共用 repository 里
/// 那同一个 MatchEngine 实例。
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/net/rate_limiter.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _sharedBvid = 'BVSHARED0001';

const _songA = Song(
  title: '秘密',
  artist: '白浩寅',
  album: '秘密',
  duration: 256,
  coverSeed: 1,
);

/// 第二首歌：同一个合集视频的标题里同时写了两个歌名，
/// 因此两首歌的搜索都会召回它 —— 候选池指向同一个 bvid。
const _songB = Song(
  title: '秘密 现场版',
  artist: '白浩寅',
  album: '合集',
  duration: 256,
  coverSeed: 2,
);

/// 假 B站 API：只记账，并记录每个 bvid 实际被请求了几次。
class _FakeBili extends BiliApi {
  _FakeBili({this.detailDelay = const Duration(milliseconds: 60)})
      : super(BiliApiClient());

  /// 详情响应延迟。不给延迟的话两个 match() 可能串行跑完，
  /// 测不出「缓存还没写入就重叠」这个真实场景。
  final Duration detailDelay;

  int detailCalls = 0;

  /// 每个 bvid 被请求的次数（>1 即为在途击穿）
  final Map<String, int> callsPerBvid = {};

  @override
  Future<List<VideoCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int maxRetries = 3,
  }) async {
    return [
      VideoCandidate(
        bvid: _sharedBvid,
        title: keyword,
        author: '白浩寅',
        mid: 999,
        durationSec: 256,
        play: 500000,
        pubdate: 1600000000,
      ),
    ];
  }

  @override
  Future<VideoDetail?> fetchVideoDetail(String bvid) async {
    detailCalls++;
    callsPerBvid[bvid] = (callsPerBvid[bvid] ?? 0) + 1;

    if (detailDelay > Duration.zero) await Future<void>.delayed(detailDelay);

    return VideoDetail(
      bvid: bvid,
      cid: 8000,
      title: '白浩寅 - 秘密 / 秘密 现场版',
      ownerName: '白浩寅',
      ownerMid: 999,
      tname: '音乐',
      durationSec: 256,
      playCount: 500000,
      pubdate: 1600000000,
      pages: const [
        VideoPage(cid: 8000, page: 1, part: '白浩寅 - 秘密', durationSec: 256),
      ],
    );
  }
}

/// 详情恒返回 null 的假实现（模拟「视频已删除」）。
class _AlwaysFailBili extends BiliApi {
  _AlwaysFailBili() : super(BiliApiClient());

  int detailCalls = 0;

  @override
  Future<List<VideoCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int maxRetries = 3,
  }) async {
    return [
      VideoCandidate(
        bvid: _sharedBvid,
        title: keyword,
        author: '白浩寅',
        mid: 999,
        durationSec: 256,
        play: 500000,
        pubdate: 1600000000,
      ),
    ];
  }

  @override
  Future<VideoDetail?> fetchVideoDetail(String bvid) async {
    detailCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return null;
  }
}

void main() {
  group('详情缓存在途去重（跨歌并发）', () {
    test('两首歌并发匹配同一个 bvid，只发一次详情请求', () async {
      final fake = _FakeBili();
      final engine = MatchEngine(
        BiliAudioSourceAdapter(fake),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      // 两首歌共用同一个 MatchEngine 实例（与生产一致）
      await Future.wait([
        engine.match(_songA),
        engine.match(_songB),
      ]);

      expect(
        fake.callsPerBvid[_sharedBvid],
        lessThanOrEqualTo(1),
        reason: '同一 bvid 的详情请求必须被在途去重合并成 1 次；'
            '实测 ${fake.callsPerBvid[_sharedBvid]} 次 —— '
            '缓存还没写入就重叠，限流额度被白烧',
      );
    });

    test('去重不改变匹配结果（两首歌都仍能选出音源）', () async {
      final fake = _FakeBili();
      final engine = MatchEngine(
        BiliAudioSourceAdapter(fake),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      final results =
          await Future.wait([engine.match(_songA), engine.match(_songB)]);

      for (final r in results) {
        expect(r.best, isNotNull, reason: '去重只应影响请求数，不该改变匹配结果');
        expect(r.best!.video.bvid, _sharedBvid);
      }
    });

    test('串行两次匹配：第二次应命中详情缓存，不发新请求', () async {
      final fake = _FakeBili();
      final engine = MatchEngine(
        BiliAudioSourceAdapter(fake),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      await engine.match(_songA);
      final first = fake.detailCalls;
      expect(first, greaterThan(0));

      await engine.match(_songA);

      expect(fake.detailCalls, first, reason: 'TTL 内第二次匹配应全部命中缓存');
    });

    test('详情零延迟（串行退化为最快路径）时结果仍正确', () async {
      // detailDelay=0 让两个 match() 几乎同时进入，这正是去重最该生效的
      // 边界；同时也证明去重不是靠「延迟」碰巧串行才成立的。
      final fake = _FakeBili(detailDelay: Duration.zero);
      final engine = MatchEngine(
        BiliAudioSourceAdapter(fake),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      final results =
          await Future.wait([engine.match(_songA), engine.match(_songB)]);

      expect(
        fake.callsPerBvid[_sharedBvid],
        lessThanOrEqualTo(1),
        reason: '零延迟下也必须只发一次详情请求',
      );
      for (final r in results) {
        expect(r.best, isNotNull);
        expect(r.best!.video.bvid, _sharedBvid);
      }
    });

    test('在途表在失败后必须清键，否则会被永久毒化', () async {
      final failing = _AlwaysFailBili();
      final engine = MatchEngine(
        BiliAudioSourceAdapter(failing),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      await engine.match(_songA);
      final first = failing.detailCalls;

      await engine.match(_songA);

      expect(
        failing.detailCalls,
        greaterThan(first),
        reason: '失败结果不写缓存（null = 视频失效，必须每次现查），'
            '且在途表必须在 finally 里清键，否则第二次会复用第一次'
            '（已失败的）Future，详情永远补不上',
      );
    });
  });
}