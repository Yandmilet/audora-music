/// 匹配流水线的**网络开销**测试。
///
/// ## 为什么专门测「请求数」而不是「功能对不对」
/// 匹配速度的唯一瓶颈是 B站 的限流额度（全局限流 30 次/分钟，见
/// `RateLimiter`）。功能测试（`match_scorer_test.dart`）能保证选出来的
/// 音源是对的，但**完全测不出「选一次要花多少次请求」**。
///
/// 而请求数直接决定用户要等多久：
///
/// ```
///   单首歌请求数 = Stage1 搜索路数 + Stage3 详情候选数
///   等待时间     = 请求数 ÷ 30 × 60 秒
/// ```
///
/// 历史事故：Stage 3 曾对**整个候选池**（上限 30 条）逐条查详情，
/// 于是单首歌 = 4 次搜索 + 30 次详情 = 34 次 ≈ **68 秒**，
/// 导入 20 首要等 20 分钟以上 —— 用户表现为「匹配好慢，等了好几分钟」。
///
/// 这个文件把「详情请求数必须被 `enrichTopK` 兜住」变成断言，
/// 防止以后有人把预筛删掉又把速度打回原形。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/services/bilibili/bili_dto.dart';
import 'package:audora2/services/match/match_config.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/net/rate_limiter.dart';

/// 假的 B站 API：不发任何网络请求，只记账。
///
/// ## 为什么用「继承 + override」而不是引入接口
/// `MatchEngine` 只依赖 `BiliApi` 的两个方法。直接继承并在子类里覆盖，
/// 就能在不改生产代码、不引入抽象层的前提下拿到一个可记账的替身 ——
/// 抽象层等真有第二种实现时再加也不迟。
class _FakeBili extends BiliApi {
  _FakeBili({required List<VideoCandidate> pool})
      : _pool = pool,
        super(BiliApiClient()) {
    for (final c in pool) {
      _byBvid[c.bvid] = c;
    }
  }

  final List<VideoCandidate> _pool;
  final Map<String, VideoCandidate> _byBvid = {};

  /// Stage 1 的搜索请求次数（每路一次）
  int searchCalls = 0;

  /// 置 true 时搜索抛异常（模拟 -412 风控 / 网络抖动），
  /// 用来验证「失败结果不进搜索缓存」
  bool failSearch = false;

  /// Stage 3 的详情请求次数（每个候选一次，**这是速度的关键**）
  int detailCalls = 0;

  /// 实际被请求过详情的 bvid，按顺序（命中缓存的不计入）
  final List<String> requestedDetailBvids = [];

  @override
  Future<List<VideoCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int maxRetries = 3,
  }) async {
    searchCalls++;
    if (failSearch) {
      throw Exception('模拟搜索失败');
    }
    // 真实场景里四路查询结果高度重叠，这里统一返回同一个池 ——
    // 合并去重后的候选数因此是确定的，断言才好写。
    return _pool;
  }

  @override
  Future<VideoDetail?> fetchVideoDetail(String bvid) async {
    detailCalls++;
    requestedDetailBvids.add(bvid);

    final c = _byBvid[bvid];
    if (c == null) return null;

    return VideoDetail(
      bvid: bvid,
      cid: 8000 + detailCalls,
      title: c.title,
      ownerName: c.author,
      ownerMid: c.mid,
      // 详情才带分区 —— 这正是 Stage 3 存在的理由之一
      tname: '音乐',
      durationSec: c.durationSec,
      playCount: c.play,
      pubdate: c.pubdate,
      pages: [
        VideoPage(cid: 8000 + detailCalls, page: 1, part: c.title, durationSec: c.durationSec),
      ],
    );
  }
}

/// 目标歌曲：256 秒，歌手白浩寅
const _song = Song(
  title: '秘密',
  artist: '白浩寅',
  album: '秘密',
  duration: 256,
  coverSeed: 1,
);

/// 目标音源：标题同时含歌名与歌手，时长精确吻合
const _trueBvid = 'BV1TRUE000001';

/// 造一个 30 条的候选池：
///   - 全部能通过 Stage 2 硬过滤（标题干净、时长在 ±30 秒内、有播放量）
///   - 正确音源 [_trueBvid] **播放量最低**，用来证明排序不是靠播放量
List<VideoCandidate> _buildPool({int size = 30}) {
  final out = <VideoCandidate>[];

  // 29 条干扰项：标题只含歌名，不含歌手 —— 能过硬过滤，但打分偏低
  for (var i = 0; i < size - 1; i++) {
    out.add(VideoCandidate(
      bvid: 'BV1DISTRACT${i.toString().padLeft(2, '0')}',
      title: '音乐搬运工$i - 秘密',
      author: '搬运工$i',
      mid: 1000 + i,
      // 时长在 256±30 秒内，否则会被 Stage 2 的时长粗筛干掉
      durationSec: 250 + (i % 12),
      // 播放量远高于正确音源 —— 按播放量排序时它会排在前面
      play: 900000 - i * 1000,
      pubdate: 1600000000,
    ));
  }

  // 正确音源：播放量最低（1 万），但标题与歌手都精确命中
  out.add(const VideoCandidate(
    bvid: _trueBvid,
    title: '白浩寅 - 秘密',
    author: '白浩寅',
    mid: 999,
    durationSec: 256,
    play: 10000,
    pubdate: 1600000000,
  ));

  return out;
}

void main() {
  late _FakeBili fake;
  late MatchEngine engine;

  setUp(() {
    // 限流额度拉满：这个文件测的是**请求数**，不是限流器本身
    // （限流器另有单测）。否则每个用例都要真等几十秒。
    fake = _FakeBili(pool: _buildPool());
    engine = MatchEngine(
      fake,
      rateLimiter: RateLimiter(maxRequests: 100000),
    );
  });

  group('Stage 3 详情请求必须被 enrichTopK 兜住', () {
    test('候选池 30 条时，详情请求数不超过 enrichTopK', () async {
      expect(_buildPool().length, 30, reason: '前提：池子确实有 30 条');

      await engine.match(_song);

      expect(
        fake.detailCalls,
        lessThanOrEqualTo(MatchConfig.enrichTopKMax),
        reason: '详情请求必须被预筛限制。若等于候选池大小（30），'
            '说明预筛被绕过，单首歌会退化成 34 次请求 ≈ 68 秒',
      );
      // 同时确认预筛**真的生效了**（不是池子本来就小），
      // 且动态 TopK 没有跌破下限（预筛不是一刀切到 0）
      expect(fake.detailCalls, lessThan(30));
      expect(fake.detailCalls, greaterThanOrEqualTo(MatchConfig.enrichTopKMin));
    });

    test('详情请求数与候选池大小解耦：池子翻倍，请求数不变', () async {
      await engine.match(_song);
      final small = fake.detailCalls;

      // 换一个 60 条的池子（翻倍）
      fake = _FakeBili(pool: _buildPool(size: 60));
      engine = MatchEngine(fake, rateLimiter: RateLimiter(maxRequests: 100000));
      await engine.match(_song);

      expect(fake.detailCalls, small,
          reason: '池子变大只增加本地计算，不该多打一次详情接口');
    });

    test('搜索请求数不超过 4 路上限（Q1/Q2 足够强时允许提前跳过）', () async {
      // 2026-09-30 起 Stage1 支持提前终止：Q1/Q2 已有足够强候选时
      // 跳过 Q3/Q4（真机日志「Q1/Q2 已获得足够强候选，跳过 Q3/Q4」）。
      // 所以这里只封顶不断言恰好 4 次。
      await engine.match(_song);
      expect(fake.searchCalls, lessThanOrEqualTo(4));
      expect(fake.searchCalls, greaterThanOrEqualTo(1));
    });

    test('单首歌总请求数（搜索 + 详情）远低于「4 + 候选池」', () async {
      await engine.match(_song);
      final total = fake.searchCalls + fake.detailCalls;

      expect(total, lessThan(4 + 30));
      // 回归基线：修复前是 34 次。这里留一条硬线，
      // 以后任何人把请求数推高都会在这里炸掉。
      expect(total, lessThanOrEqualTo(4 + MatchConfig.enrichTopKMax));
    });
  });

  group('预筛不能丢掉正确的音源', () {
    test('播放量最低但标题歌手精确命中的候选，仍然胜出', () async {
      final r = await engine.match(_song);

      expect(r.best, isNotNull, reason: '池子里有正确候选，不该判无音源');
      expect(
        r.best!.video.bvid,
        _trueBvid,
        reason: '正确音源播放量最低，若靠播放量排序就会被埋掉。'
            '预筛必须按打分排序，而不是按热度',
      );
    });

    test('正确音源的详情被请求过（没被预筛挡在门外）', () async {
      await engine.match(_song);
      expect(fake.requestedDetailBvids, contains(_trueBvid));
    });
  });

  group('详情缓存', () {
    test('同一引擎重复匹配同一首歌，第二次全部命中缓存、不再发请求', () async {
      await engine.match(_song);
      final afterFirst = fake.detailCalls;
      expect(afterFirst, greaterThan(0));

      await engine.match(_song);
      expect(
        fake.detailCalls,
        afterFirst,
        reason: '5 分钟 TTL 内的重复匹配应完全命中缓存 —— '
            '重新匹配是用户高频操作，每次重打 6 次详情纯属浪费额度',
      );
    });

    test('清空缓存后重新发请求', () async {
      await engine.match(_song);
      final afterFirst = fake.detailCalls;

      engine.clearDetailCache();
      await engine.match(_song);

      expect(fake.detailCalls, afterFirst * 2,
          reason: 'clearDetailCache 后不应再命中缓存');
    });
  });

  group('搜索缓存（v0.5）', () {
    test('同一引擎重复匹配同一首歌，第二次搜索全部命中缓存、不再发请求', () async {
      await engine.match(_song);
      final afterFirst = fake.searchCalls;
      expect(afterFirst, greaterThan(0));

      await engine.match(_song);
      expect(
        fake.searchCalls,
        afterFirst,
        reason: '24h TTL 内的重复匹配应完全命中搜索缓存 —— '
            '重新匹配时重发 Q1~Q4 纯属浪费限流额度（批量场景 2~4 次/首）',
      );
    });

    test('清空搜索缓存后重新发请求（clearSearchCache 只清搜索、不动详情缓存）', () async {
      await engine.match(_song);
      final searchAfterFirst = fake.searchCalls;
      final detailAfterFirst = fake.detailCalls;

      engine.clearSearchCache();
      await engine.match(_song);

      expect(fake.searchCalls, searchAfterFirst * 2,
          reason: 'clearSearchCache 后不应再命中搜索缓存');
      // 详情缓存 TTL 未到，不应多发
      expect(fake.detailCalls, detailAfterFirst,
          reason: 'clearSearchCache 不得影响详情缓存');
    });

    test('搜索失败不写缓存：抖动一次不能让这首歌在 TTL 内匹配不到', () async {
      final flaky = _FakeBili(pool: _buildPool());
      final e = MatchEngine(flaky, rateLimiter: RateLimiter(maxRequests: 100000));

      // 第一轮：搜索全部抛异常（模拟 -412 / 网络抖动）
      flaky.failSearch = true;
      final r1 = await e.match(_song);
      expect(r1.hasCandidate, isFalse);
      final failedCalls = flaky.searchCalls;
      expect(failedCalls, greaterThan(0));

      // 第二轮：网络恢复。若失败结果被缓存住，searchCalls 不会增长
      flaky.failSearch = false;
      await e.match(_song);
      expect(
        flaky.searchCalls,
        greaterThan(failedCalls),
        reason: '失败路径绝不能进缓存，否则一次抖动 = TTL 内永久无候选',
      );
    });
  });

  group('无结果的歌必须快速返回，不能无限递归（回归）', () {
    // ## 这里曾经有个把整批匹配堵死的 bug
    // `_recall` 在「分档搜索为空」时会 `return _recall(song)` 递归回退全量。
    // 但递归进去后 durationFilter 由 song.duration **重算出同一个值**、
    // 查询词也完全相同 —— 于是「空 → 递归 → 还是空 → 再递归」永不终止：
    // 每轮白烧 8 次限流配额，且永不返回，而 `matchAllUnmatched` 是串行的，
    // 整个队列被这一首永久堵住。用户表现为「匹配卡住、等多久都好不了」，
    // 且没有任何报错。
    //
    // 下面的 timeout 就是用来抓它的：真发生无限递归时不会静默通过，
    // 而是直接超时失败。

    test('B站 完全没有结果时，match 必须在限定时间内返回', () async {
      final empty = _FakeBili(pool: <VideoCandidate>[]);
      final e = MatchEngine(empty, rateLimiter: RateLimiter(maxRequests: 100000));

      final r = await e.match(_song).timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError(
              'match() 没有在 5 秒内返回 —— 极可能是「分档搜索为空」'
              '触发了无限递归（每轮 8 次请求且永不终止）',
            ),
          );

      expect(r.hasCandidate, isFalse);
      expect(r.diagnostics, isNotEmpty, reason: '无候选时要留下可排查的原因');
    });

    test('无结果时的搜索请求数有上界（回退只允许一次）', () async {
      final empty = _FakeBili(pool: <VideoCandidate>[]);
      final e = MatchEngine(empty, rateLimiter: RateLimiter(maxRequests: 100000));

      await e.match(_song).timeout(const Duration(seconds: 5));

      // 4 路 × （首次 + 一次性回退）= 8 是理论上界
      expect(
        empty.searchCalls,
        lessThanOrEqualTo(8),
        reason: '超过 8 次说明回退在反复触发（递归没有收敛）',
      );
    });

    test('无结果时不会请求任何详情', () async {
      final empty = _FakeBili(pool: <VideoCandidate>[]);
      final e = MatchEngine(empty, rateLimiter: RateLimiter(maxRequests: 100000));

      await e.match(_song).timeout(const Duration(seconds: 5));

      expect(empty.detailCalls, 0);
    });
  });

  group('成本模型（把「为什么慢」写成可执行的说明）', () {
    test('按 30 次/分钟限流折算，单首歌的等待时间在 30 秒以内', () async {
      await engine.match(_song);
      final total = fake.searchCalls + fake.detailCalls;

      // 限流是 30 次/分钟 → 每次请求平均占 2 秒
      final estimatedSeconds = total * 2;
      expect(
        estimatedSeconds,
        lessThan(30),
        reason: '单首歌若超过 30 秒，导入 20 首就要 10 分钟以上，'
            '这个体感就是「卡住了」',
      );

      // 对照：修复前 Stage 3 对 30 条候选全部查详情 → 34 次 ≈ 68 秒
      const beforeTotal = 4 + 30;
      expect(beforeTotal * 2, greaterThan(60),
          reason: '记录修复前的量级，说明这次优化确实必要');
    });
  });
}
