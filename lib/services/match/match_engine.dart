/// 音源匹配引擎 —— 四阶段流水线（设计文档 4.2）。
///
/// ```
/// 输入：Song(title, artist, album, duration, releaseDate)
///   ├─▶ [Stage 1] 候选召回 ──── 四路查询 → 去重 → 按播放量截断
///   ├─▶ [Stage 2] 硬性过滤 ──── 一票否决，不进打分
///   ├─▶ [Stage 3] 精确校验 ──── 批量查详情，分P级时长匹配
///   └─▶ [Stage 4] 加权打分 ──── 六维 → 总分 → 分级
/// ```
///
/// 三个阶段各自独立成方法，方便「精度不对时单独回放某一阶段」排查。
library;

import '../../models/models.dart';
import '../bilibili/bili_api.dart';
import '../bilibili/bili_dto.dart';
import '../diag/diag_log.dart';
import '../net/rate_limiter.dart';
import 'match_config.dart';
import 'match_scorer.dart';
import 'text_normalizer.dart';

/// 匹配结果（设计文档 4.7 的 `MatchResult`）
class MatchResult {
  /// 最终胜出的候选（无候选或全部淘汰时为 null）
  final ScoredCandidate? best;

  /// 备选候选，供人工兜底界面展示（设计文档 6.2「展示 Top 3 候选」）
  final List<ScoredCandidate> runnerUps;

  /// 为什么没有匹配上 / 哪些候选因何被淘汰，便于排查
  final List<String> diagnostics;

  const MatchResult({
    this.best,
    this.runnerUps = const [],
    this.diagnostics = const [],
  });

  bool get hasCandidate => best != null;

  MatchConfidence get confidence =>
      best?.confidence ?? MatchConfidence.rejected;

  /// 是否可直接自动绑定
  bool get isBound => confidence == MatchConfidence.auto;

  /// 供落库的 SongSourceBinding 用
  MatchType get matchType =>
      isBound ? MatchType.autoMatched : MatchType.manualBound;

  @override
  String toString() {
    if (best == null) {
      return 'MatchResult(无候选) ${diagnostics.join(" | ")}';
    }
    return 'MatchResult(best=${best!} '
        'runnerUps=${runnerUps.length})';
  }
}

class MatchEngine {
  MatchEngine(this.api, {RateLimiter? rateLimiter})
      : rateLimiter = rateLimiter ?? RateLimiter();

  final BiliApi api;

  /// 与 api 客户端共用同一个限流器时传入外部实例；
  /// 独立使用时用默认的 30次/分钟。
  final RateLimiter rateLimiter;

  /// 详情接口的进程内缓存。
  ///
  /// ## 为什么值得缓存
  /// 详情是全链路最贵的一步：每候选一次请求，且与搜索**共用**
  /// 30 次/分钟的全局额度。而重复命中很常见 ——
  /// 一次批量匹配里不同歌撞上同一个 bvid（同一 UP 主的合集、热门搬运稿），
  /// 或者用户对同一首歌重新匹配（此时全部候选都要重查一遍）。
  ///
  /// ## 为什么 TTL 短、且不缓存失败
  /// `fetchVideoDetail` 返回 null 的主要场景是「视频已删除」，
  /// 而 Stage 3 正是依赖它做失效判定 —— 把 null 缓存住会让
  /// 已恢复的视频永远拉不到。所以**只缓存成功结果**，TTL 取 5 分钟：
  /// 足够覆盖一次批量匹配，又不至于让元数据长期陈旧
  /// （播放量、失效状态都是会变的）。
  final Map<String, _CachedDetail> _detailCache = {};

  /// 缓存条目上限，超了按**插入顺序**淘汰最旧的一条（FIFO）。
  /// 用 FIFO 而非 LRU：这里每条的成本相同，实现简单且不会有链表开销。
  static const int _detailCacheCap = 500;

  static const Duration _detailTtl = Duration(minutes: 5);

  /// 清空详情缓存。
  ///
  /// 单测之间必须调用，否则上一个用例缓存的详情会串到下一个用例，
  /// 表现为「请求计数对不上」（缓存的条目没发请求）。
  /// 「强制重新匹配」这类需要拿最新元数据的场景也用它。
  void clearDetailCache() => _detailCache.clear();

  /// 搜索结果缓存（v0.5 限流与缓存设计）。
  ///
  /// ## 为什么搜索值得缓存
  /// 同一首歌的重复匹配（用户重新匹配、批量任务重跑、更换排除集后重试）
  /// 会把 Q1~Q4 全部重发一遍，而搜索结果在一天内几乎不变。
  /// 每命中一路就省一次限流额度——批量场景下是 2~4 次/首。
  ///
  /// ## 为什么 key 必须带 durationFilter
  /// 分档搜索（`MatchConfig.durationFilterFor`）是服务端过滤，
  /// 同一关键词不同档位返回不同结果集，只按关键词缓存会串档。
  ///
  /// ## 为什么只缓存成功结果
  /// 搜索失败（网络抖动 / -412 风控）绝不能把空列表缓存住——
  /// 否则一次抖动会让这首歌在 TTL 内永远匹配不到。
  /// 失败路径直接走 catch 返回空列表，不写缓存。
  final Map<String, _CachedSearch> _searchCache = {};

  /// 缓存条目上限，超了按插入顺序淘汰最旧的一条（与详情缓存同策略）。
  static const int _searchCacheCap = 300;

  /// 搜索结果 TTL：24 小时。搜索结果（标题/时长/播放量）日内变化极小，
  /// 而失效判定依赖的是详情接口（见 [_detailOf] 的短 TTL），
  /// 这里放长不会造成「绑死失效音源」的问题。
  static const Duration _searchTtl = Duration(hours: 24);

  /// 清空搜索缓存。
  ///
  /// 用途与 [clearDetailCache] 相同：单测隔离、强制重新匹配。
  void clearSearchCache() => _searchCache.clear();

  /// 供「手动搜索音源」使用的带缓存搜索（公开入口）。
  ///
  /// ## 为什么手动搜索要与匹配引擎共享缓存
  /// 用户的高频路径是「自动匹配不满意 → 打开手动搜索」，此时默认关键词
  /// 「歌名 歌手」与引擎的 Q1 完全相同——重新发一次搜索纯属浪费：
  /// 既多等一次请求（~0.5s），又多烧一次限流额度。共享后同词同档
  /// 直接命中（TTL 24h，见 [_searchTtl]），秒出结果；反向
  /// （先手动搜索再重新匹配）同样受益。
  ///
  /// [durationFilter] 传 0 = 全量档（手动搜索不做服务端时长过滤）。
  /// [maxRetries] 传 1：交互式搜索要快速反馈，见 `BiliApiClient.request`。
  Future<List<VideoCandidate>> searchCached(
    String keyword, {
    int durationFilter = 0,
    int maxRetries = 3,
  }) {
    return _searchSafe(keyword, durationFilter, null, maxRetries: maxRetries);
  }

  /// 匹配一首歌（完整四阶段）
  ///
  /// 外层只负责「开始 / 结束」两条诊断日志与耗时统计，
  /// 流水线本体在 [_matchImpl] —— 分开是为了让日志逻辑不掺进四阶段代码里。
  Future<MatchResult> match(
    Song song, {
    /// 已知失效的 bvid，直接排除（设计文档 8.3 的自动修复）
    Set<String> excludeBvids = const {},
    void Function(String stage, String msg)? onLog,
  }) async {
    final sw = Stopwatch()..start();
    DiagLog.instance.i(
      DiagCategory.match,
      '开始匹配：${song.title}',
      {
        'event': 'start',
        'song': song.title,
        'artist': song.artist,
        'duration': song.duration,
      },
    );

    final MatchResult r;
    try {
      r = await _matchImpl(song, excludeBvids: excludeBvids, onLog: onLog);
    } catch (e) {
      DiagLog.instance.e(
        DiagCategory.match,
        '匹配过程异常：$e',
        {
          'event': 'done',
          'ok': false,
          'song': song.title,
          'ms': sw.elapsedMilliseconds,
        },
      );
      rethrow;
    }

    final best = r.best;
    DiagLog.instance.log(
      // 没候选不算 error（B站确实可能没有这首歌），但值得 warn 一下
      best == null ? DiagLevel.warn : DiagLevel.info,
      DiagCategory.match,
      best == null
          ? '匹配结束：无可用候选'
          : '匹配结束：${best.video.bvid} ${best.score100}分'
              '（${best.confidence.label}）',
      fields: {
        'event': 'done',
        // ok 指「可直接自动绑定」，与 hasCandidate 不同：
        // 有候选但置信度不足时该走人工确认，统计上不算成功
        'ok': r.isBound,
        'hasCandidate': r.hasCandidate,
        'song': song.title,
        if (best != null) ...{
          'bvid': best.video.bvid,
          'score': double.parse(best.total.toStringAsFixed(4)),
          'confidence': best.confidence.name,
          // 六维明细：设计文档 5.3 指定它是调参的唯一依据
          'detail': best.detail.toJson(),
        },
        'ms': sw.elapsedMilliseconds,
        if (r.diagnostics.isNotEmpty) 'diagnostics': r.diagnostics.take(20).toList(),
      },
    );
    return r;
  }

  Future<MatchResult> _matchImpl(
    Song song, {
    Set<String> excludeBvids = const {},
    void Function(String stage, String msg)? onLog,
  }) async {
    final diag = <String>[];

    // ── Stage 1：候选召回 ────────────────────────────────
    final pool = await _recall(song, onLog: onLog);
    if (pool.isEmpty) {
      diag.add('Stage1：四路查询均无结果');
      return MatchResult(diagnostics: diag);
    }
    _stage(onLog, 'Stage1', '候选池 ${pool.length} 条',
        fields: {'count': pool.length});

    // ── Stage 2：硬过滤 ──────────────────────────────────
    final filtered = _hardFilter(pool, song, excludeBvids, diag: diag, onLog: onLog);
    if (filtered.isEmpty) {
      diag.add('Stage2：全部候选被硬过滤淘汰');
      // 降级策略（设计文档 10.1「全部候选被硬过滤」）：
      // 放宽黑名单，重新过一遍，但结果全部标 REVIEW（不允许 AUTO）
      final relaxed = _hardFilterRelaxed(pool, song, excludeBvids);
      if (relaxed.isEmpty) {
        return MatchResult(diagnostics: diag);
      }
      diag.add('Stage2降级：放宽黑名单后保留 ${relaxed.length} 条，结果强制 REVIEW');
      _stage(onLog, 'Stage2', '降级保留 ${relaxed.length} 条',
          fields: {'count': relaxed.length});
      return _enrichAndScore(
        relaxed,
        song,
        diag: diag,
        onLog: onLog,
        forceReview: true,
      );
    }
    _stage(onLog, 'Stage2', '硬过滤后剩 ${filtered.length} 条',
        fields: {'count': filtered.length});

    // ── Stage 3 + Stage 4 ────────────────────────────────
    return _enrichAndScore(filtered, song, diag: diag, onLog: onLog);
  }

  /// 阶段日志：同时喂给调用方的 [onLog] 回调与诊断日志。
  ///
  /// ## 为什么两边都写
  /// `onLog` 是**给调用方看的**（批量匹配时把进度打到界面上），
  /// 但它只在调用方主动传时才存在，且不落盘——事后无法复盘。
  /// 诊断日志是**给自己看的**：写盘、默认开启、可在设置页回看。
  /// 两者信息同源，所以在这里统一出口，调用点只写一次。
  static void _stage(
    void Function(String stage, String msg)? onLog,
    String stage,
    String msg, {
    DiagLevel level = DiagLevel.info,
    Map<String, Object?> fields = const {},
  }) {
    onLog?.call(stage, msg);
    DiagLog.instance.log(
      level,
      DiagCategory.match,
      '[$stage] $msg',
      fields: {'event': stage, 'stage': stage, ...fields},
    );
  }

  // ── Stage 1：候选召回（设计文档 4.3）──────────────────────

  /// 四路并行查询 → 去重 → 按播放量截断。
  ///
  /// ## 四路的分工
  ///   Q1 精确路 `歌名 歌手`      覆盖最常见的命名
  ///   Q2 宽松路 `歌名`           覆盖标题不带歌手（纯音乐分享号）
  ///   Q3 强化路 `歌名 歌手 专辑`  覆盖标题含专辑
  ///   Q4 质量路 `歌名 歌手 无损`  定向召回认真处理过音源的投稿
  ///
  /// Q4 的「无损」是**查询词增强而非硬过滤**——部分优质音源标题不写「无损」，
  /// 当成过滤条件会把它们全杀掉（设计文档 13.6 修正项 ①）。
  /// [allowFullScanFallback] 见下方「分档搜索为空」处的说明。
  /// **外部调用方不要传 false**，它只服务于内部的一次性回退。
  Future<List<VideoCandidate>> _recall(
    Song song, {
    void Function(String stage, String msg)? onLog,
    bool allowFullScanFallback = true,
  }) async {
    final artist1 = _firstArtist(song.artist);
    final durationFilter = MatchConfig.durationFilterFor(song.duration * 1000);
    const suffix = MatchConfig.qualitySuffix;

    final q1 = artist1.isEmpty ? song.title : '${song.title} $artist1';
    final q2 = song.title;

    // 第一层只跑最有价值的两路。Q3/Q4 只有在召回质量仍不足时才启动，
    // 避免每首歌固定消耗 4 次搜索额度。
    final firstQueries = <String>[q1, q2];
    final firstLists = await Future.wait(
      firstQueries.map((q) => _searchSafe(q, durationFilter, onLog)),
    );

    var pool = _mergeAndTrim(firstLists);

    if (_recallIsAlreadyStrong(pool, song)) {
      _stage(
        onLog,
        'Stage1',
        'Q1/Q2 已获得足够强候选，跳过 Q3/Q4',
        fields: {
          'firstLayer': pool.length,
          'skippedQueries': 2,
        },
      );
    } else {
      final extraQueries = <String>[];
      if (artist1.isNotEmpty && song.album.isNotEmpty) {
        extraQueries.add('${song.title} $artist1 ${song.album}');
      }
      if (artist1.isNotEmpty) {
        extraQueries.add('${song.title} $artist1 $suffix');
      }

      if (extraQueries.isNotEmpty) {
        final extraLists = await Future.wait(
          extraQueries.map((q) => _searchSafe(q, durationFilter, onLog)),
        );
        pool = _mergeAndTrim([...firstLists, ...extraLists]);
      }
    }

    // 服务端分档可能过度过滤。这里只允许一次显式全量回退。
    if (pool.isEmpty && durationFilter != 0 && allowFullScanFallback) {
      _stage(
        onLog,
        'Stage1',
        '分档搜索为空，回退全量搜索',
        level: DiagLevel.warn,
      );
      return _recall(song, onLog: onLog, allowFullScanFallback: false);
    }

    return pool;
  }

  List<VideoCandidate> _mergeAndTrim(
    List<List<VideoCandidate>> lists,
  ) {
    final merged = <String, VideoCandidate>{};
    for (final list in lists) {
      for (final c in list) {
        // 保留先出现者，Q1 > Q2 > Q3 > Q4。
        merged.putIfAbsent(c.bvid, () => c);
      }
    }

    final pool = merged.values.toList()
      ..sort((a, b) => b.play.compareTo(a.play));

    if (pool.length <= MatchConfig.maxCandidates) return pool;
    return pool.sublist(0, MatchConfig.maxCandidates);
  }

  /// 搜索阶段只使用已经存在的字段做廉价判断。
  /// 同时要求“数量 + 强证据”，避免因为单个偶然命中而跳过 Q3/Q4。
  bool _recallIsAlreadyStrong(
    List<VideoCandidate> candidates,
    Song song,
  ) {
    if (candidates.length < MatchConfig.minRecallCandidates) return false;

    final songTitle = TextNormalizer.normalize(song.title);
    if (songTitle.isEmpty) return false;
    final songMs = song.duration * 1000;

    var strong = 0;
    for (final v in candidates) {
      final title = TextNormalizer.normalize(v.title);
      final titleHit = title == songTitle || title.contains(songTitle);
      if (!titleHit) continue;

      if (songMs > 0 && v.durationMs > 0) {
        final diff = (v.durationMs - songMs).abs();
        if (diff > 5000) continue;
      }

      // 标题/时长已经是两个最高权重判断维；这里不调用完整 scorer，
      // 避免为了决定是否发搜索请求又做大量模糊匹配。
      strong++;
      if (strong >= 3) return true;
    }
    return false;
  }

  Future<List<VideoCandidate>> _searchSafe(
    String keyword,
    int durationFilter,
    void Function(String stage, String msg)? onLog, {
    int maxRetries = 3,
  }) async {
    // 缓存 key：关键词 + 分档。同词不同档是不同结果集，必须区分。
    final key = '$durationFilter|$keyword';
    final hit = _searchCache[key];
    if (hit != null && DateTime.now().difference(hit.at) < _searchTtl) {
      _stage(onLog, 'Stage1', '查询「$keyword」命中缓存 ${hit.list.length} 条',
          fields: {'keyword': keyword, 'count': hit.list.length, 'cache': 1});
      // 返回副本：上层（_mergeAndTrim 等）虽然目前只读遍历，
      // 副本保证缓存永远不会被上层的排序/修改操作污染。
      return hit.list.toList();
    }
    // 过期条目顺手清掉，避免它继续占着容量上限（与详情缓存同做法）
    if (hit != null) _searchCache.remove(key);

    try {
      final list = await api.searchWithFallback(
        keyword,
        durationFilter: durationFilter,
        maxRetries: maxRetries,
      );
      // 每路返回条数都记下来：Stage1「四路召回」各自贡献多少，
      // 是判断"要不要砍掉某一路"的直接依据（限流优化的数据来源）
      _stage(onLog, 'Stage1', '查询「$keyword」返回 ${list.length} 条',
          fields: {'keyword': keyword, 'count': list.length});

      if (_searchCache.length >= _searchCacheCap) {
        _searchCache.remove(_searchCache.keys.first);
      }
      // 存不可变副本：_searchSafe 的调用方拿到的 list 若被原地排序，
      // 也不会污染缓存内容
      _searchCache[key] = _CachedSearch(
        List<VideoCandidate>.unmodifiable(list),
        DateTime.now(),
      );
      return list;
    } catch (e) {
      _stage(onLog, 'Stage1', '查询「$keyword」失败：$e',
          level: DiagLevel.warn, fields: {'keyword': keyword});
      // 失败不写缓存：一次网络抖动不该让这首歌在 TTL 内匹配不到
      return const [];
    }
  }

  // ── Stage 2：硬过滤（设计文档 4.4）──────────────────────

  List<VideoCandidate> _hardFilter(
    List<VideoCandidate> pool,
    Song song,
    Set<String> excludeBvids, {
    required List<String> diag,
    void Function(String stage, String msg)? onLog,
  }) {
    final songMs = song.duration * 1000;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final result = <VideoCandidate>[];
    // 黑名单词的小写副本提到循环外：原来「每候选 × 每词」都重复
    // toLowerCase()，词表是 const，预计算一次即可（诊断仍报原始拼写）。
    final blockLower = MatchConfig.blockTitlePatternsLower;

    for (final v in pool) {
      if (excludeBvids.contains(v.bvid)) {
        diag.add('${v.bvid}：已知失效音源，排除');
        continue;
      }

      // 1) 标题黑名单。标题小写也只算一次，供全部词复用
      final titleLower = v.title.toLowerCase();
      var hitWord = '';
      for (var i = 0; i < blockLower.length; i++) {
        if (titleLower.contains(blockLower[i])) {
          hitWord = MatchConfig.blockTitlePatterns[i];
          break;
        }
      }
      if (hitWord.isNotEmpty) {
        diag.add('${v.bvid}：标题命中黑名单「$hitWord」');
        continue;
      }

      // 2) 时长粗筛。用绝对值：音乐视频常加片头/封面页，B站时长会比歌曲略长
      if (songMs > 0 && v.durationMs > 0) {
        final diff = (v.durationMs - songMs).abs();
        if (diff > MatchConfig.durationToleranceMs) {
          diag.add('${v.bvid}：时长粗筛不过（差 ${diff ~/ 1000}s）');
          continue;
        }
      }

      // 3) 可用性预检：零播放 + 近期发布，多为废稿
      if (v.play == 0 &&
          v.pubdate > 0 &&
          now - v.pubdate < MatchConfig.zeroPlayAgeDays * 86400) {
        diag.add('${v.bvid}：零播放且近期发布，疑似废稿');
        continue;
      }

      result.add(v);
    }
    return result;
  }

  /// 降级版硬过滤：只保留「时长粗筛 + 失效排除」，放开黑名单。
  ///
  /// 用在「全部候选被硬过滤」的场景——与其直接判定无音源，
  /// 不如把翻唱/伴奏这类候选交给人来判，结果强制标 REVIEW
  /// （设计文档 10.1）。
  List<VideoCandidate> _hardFilterRelaxed(
    List<VideoCandidate> pool,
    Song song,
    Set<String> excludeBvids,
  ) {
    final songMs = song.duration * 1000;
    return pool.where((v) {
      if (excludeBvids.contains(v.bvid)) return false;
      if (songMs > 0 && v.durationMs > 0) {
        final diff = (v.durationMs - songMs).abs();
        // 降级时也放宽时长：从 30s 放到 60s
        if (diff > MatchConfig.durationToleranceMs * 2) return false;
      }
      return true;
    }).toList();
  }

  // ── Stage 3 + Stage 4 ────────────────────────────────────

  /// Stage 3 预筛：把候选池按「搜索阶段已有的字段」粗排，只保留前
  /// [MatchConfig.enrichTopKMin..MatchConfig.enrichTopKMax] 条进详情接口。
  ///
  /// ## 为什么必须要有这一步
  /// 详情接口是**每个候选一次请求**，而全局限流只有 30 次/分钟
  /// （见 [RateLimiter]）。候选池满 30 条时光 Stage 3 就要 30 次请求，
  /// 加上 Stage 1 的四路搜索共 34 次 —— 在 30 次/分钟的额度下
  /// 等于 **68 秒/首**，导入 20 首要等 20 分钟以上。
  /// 但最终只有 1 条胜出，另外 29 次请求是纯浪费。
  ///
  /// ## 为什么粗排是可靠的
  /// 六维权重里最高的两维是标题(0.30)与时长(0.30)，这两个**搜索接口
  /// 就已经给全了**（`VideoCandidate.title / author / durationSec`）。
  /// 详情接口补的是精确时长、分P、分区与标签 —— 其中分区(0.08)与
  /// 文本规范度(0.07) 合计仅 0.15，且缺失时对**所有**候选是同向影响，
  /// 不改变相对次序。
  ///
  /// 还有一层保险：Stage 2 的时长粗筛（±30 秒）**已经**在搜索结果时长上
  /// 执行过了，所以进入这里的候选彼此时长差距本就不大，
  /// 「搜索时长不准导致排错序」的空间被限制在 30 秒以内。
  ///
  /// 结论：预筛只承担**粗排序**，把明显没戏的挡在详情请求之外；
  /// 真正决定胜负的精确比对仍在补全之后（Stage 4）进行。
  List<_PreselectedCandidate> _preselect(
    List<VideoCandidate> candidates,
    Song song, {
    void Function(String stage, String msg)? onLog,
  }) {
    if (candidates.isEmpty) return const [];

    // 每条只打一次分，避免 sort comparator 重复计算。
    final scored = candidates
        .map((c) => _PreselectedCandidate(
              candidate: c,
              coarseScore: MatchScorer.score(c, song).total,
            ))
        .toList()
      ..sort((a, b) => b.coarseScore.compareTo(a.coarseScore));

    final k = _dynamicEnrichTopK(scored);
    final selected = scored.take(k).toList();

    _stage(
      onLog,
      'Stage3',
      '预筛 ${candidates.length} → $k 条，省下 ${candidates.length - k} 次详情请求',
      fields: {
        'before': candidates.length,
        'after': k,
        'saved': candidates.length - k,
      },
    );
    return selected;
  }

  int _dynamicEnrichTopK(List<_PreselectedCandidate> scored) {
    final max = scored.length < MatchConfig.enrichTopKMax
        ? scored.length
        : MatchConfig.enrichTopKMax;
    if (max <= MatchConfig.enrichTopKMin) return max;

    final top = scored.first.coarseScore;
    final second = scored.length > 1 ? scored[1].coarseScore : 0.0;
    final gap = top - second;

    if (top >= 0.86 && gap >= 0.08) {
      return MatchConfig.enrichTopKMin;
    }
    if (top >= 0.80 && gap >= 0.04) {
      return max < 4 ? max : 4;
    }
    return max;
  }

  Future<MatchResult> _enrichAndScore(
    List<VideoCandidate> candidates,
    Song song, {
    required List<String> diag,
    void Function(String stage, String msg)? onLog,
    bool forceReview = false,
  }) async {
    final selected = _preselect(candidates, song, onLog: onLog);
    if (selected.isEmpty) {
      diag.add('Stage3：预筛无候选');
      return MatchResult(diagnostics: diag);
    }

    final scored = <ScoredCandidate>[];
    var requested = 0;

    // 分批补详情。首批已经出现“非常强且明显领先”的候选时，
    // 不再请求后续候选，避免为一个已经确定的结果继续消耗限流额度。
    for (var start = 0; start < selected.length; start += MatchConfig.enrichBatchSize) {
      final end = (start + MatchConfig.enrichBatchSize).clamp(0, selected.length).toInt();
      final batch = selected.sublist(start, end);
      requested += batch.length;

      final enriched = await mapWithConcurrency(
        batch.map((e) => e.candidate).toList(),
        MatchConfig.enrichConcurrency,
        (v) => _enrichOne(v, song, diag),
      );

      for (final v in enriched) {
        scored.add(MatchScorer.score(v, song));
      }

      if (scored.isNotEmpty) {
        scored.sort((a, b) => b.total.compareTo(a.total));
        final best = scored.first;
        final nextIndex = end;
        final nextCoarse = nextIndex < selected.length
            ? selected[nextIndex].coarseScore
            : -1.0;

        if (!forceReview &&
            best.total >= MatchConfig.earlyAutoThreshold &&
            (nextCoarse < 0 || best.total - nextCoarse >= MatchConfig.earlyStopGap)) {
          _stage(
            onLog,
            'Stage3',
            '提前终止详情请求：${best.video.bvid} ${best.score100}分',
            fields: {
              'best': best.total,
              'nextCoarse': nextCoarse,
              'requested': requested,
              'planned': selected.length,
            },
          );
          break;
        }
      }
    }

    _stage(
      onLog,
      'Stage3',
      '详情补全并评分 ${scored.length} 条，实际请求 $requested/${selected.length} 条'
      '（候选池 ${candidates.length} 条）',
      fields: {
        'scored': scored.length,
        'requested': requested,
        'planned': selected.length,
        'pool': candidates.length,
      },
    );

    if (scored.isEmpty) {
      diag.add('Stage3：全部候选详情接口失败');
      return MatchResult(diagnostics: diag);
    }

    scored.sort((a, b) => b.total.compareTo(a.total));

    var finalScored = scored;
    if (forceReview) {
      finalScored = scored
          .map((s) => ScoredCandidate(
                video: s.video,
                total: s.total,
                detail: s.detail,
                confidence: s.confidence == MatchConfidence.auto
                    ? MatchConfidence.review
                    : s.confidence,
              ))
          .toList();
    }

    final best = finalScored.first;
    diag.add('胜出：${best.toString()}');

    final runnerUps = finalScored
        .skip(1)
        .where((s) => s.confidence != MatchConfidence.rejected)
        .take(3)
        .toList();

    return MatchResult(
      best: best,
      runnerUps: runnerUps,
      diagnostics: diag,
    );
  }

  /// 单条候选的精确校验：拿详情 + 选最佳分P（设计文档 4.5）
  Future<VideoCandidate?> _enrichOne(
    VideoCandidate base,
    Song song,
    List<String> diag,
  ) async {
    final VideoDetail? detail;
    try {
      detail = await _detailOf(base.bvid);
    } catch (e) {
      diag.add('${base.bvid}：详情接口异常 $e');
      DiagLog.instance.w(DiagCategory.match, '详情接口异常：$base.bvid',
          {'bvid': base.bvid, 'error': '$e'});
      return null;
    }

    if (detail == null) {
      // 视频已删除 / 权限不足。设计文档 10.1 明确要求：
      // **跳过该候选，不降级使用搜索结果**——搜索结果的时长不够准，
      // 拿它打分会导致误判。
      diag.add('${base.bvid}：详情不可用（已删除或受限）');
      DiagLog.instance.i(DiagCategory.match, '候选详情不可用：$base.bvid',
          {'bvid': base.bvid, 'reason': 'deleted_or_forbidden'});
      return null;
    }

    // 多分P处理（设计文档 4.5.2）：合辑视频的标题通常含专辑名，
    // 时长校验必须落到分P粒度才能通过。
    final bestPage = _pickBestPage(detail.pages, song.duration * 1000);

    if (bestPage != null) {
      return base.copyWith(
        durationSec: bestPage.durationSec,
        cid: bestPage.cid,
        author: detail.ownerName,
        typename: detail.tname,
        play: detail.playCount,
        pubdate: detail.pubdate,
        tag: detail.tag,
        desc: detail.desc,
      );
    }

    // 没找到时长吻合的分P：
    // 单P视频用详情时长；多P视频用第一P但**降低可信度**由打分自然体现
    final isMultiPage = detail.pages.length > 1;
    if (isMultiPage) {
      diag.add('${base.bvid}：多分P（${detail.pages.length}）但无时长吻合的P');
    }

    return base.copyWith(
      durationSec: detail.durationSec > 0 ? detail.durationSec : base.durationSec,
      cid: detail.cid,
      author: detail.ownerName,
      typename: detail.tname,
      play: detail.playCount,
      pubdate: detail.pubdate,
      tag: detail.tag,
      desc: detail.desc,
    );
  }

  /// 带缓存的详情查询。只缓存成功结果（null 代表视频失效，必须每次现查）。
  Future<VideoDetail?> _detailOf(String bvid) async {
    final hit = _detailCache[bvid];
    if (hit != null && DateTime.now().difference(hit.at) < _detailTtl) {
      return hit.detail;
    }
    // 过期条目顺手清掉，避免它继续占着容量上限
    if (hit != null) _detailCache.remove(bvid);

    final detail = await api.fetchVideoDetail(bvid);
    if (detail != null) {
      if (_detailCache.length >= _detailCacheCap) {
        _detailCache.remove(_detailCache.keys.first);
      }
      _detailCache[bvid] = _CachedDetail(detail, DateTime.now());
    }
    return detail;
  }

  /// 从分P列表里挑时长最接近歌曲的那一P
  ///
  /// 设计文档 13.7 第 4 项提醒：NeriPlayer 只靠 `part == songName` 精确匹配
  /// 分P名，但分P名常带序号前缀（如 `01. 秘密`）。这里的策略是
  /// **优先用时长匹配**（物理证据比文本更可靠），必要时再结合分P名。
  VideoPage? _pickBestPage(List<VideoPage> pages, int songMs) {
    if (pages.isEmpty || songMs <= 0) return null;

    VideoPage? best;
    var bestDiff = MatchConfig.pageMatchToleranceMs + 1;

    for (final p in pages) {
      if (p.durationSec <= 0) continue;
      final diff = (p.durationSec * 1000 - songMs).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = p;
      }
    }
    return best;
  }

  // ── 工具 ─────────────────────────────────────────────────

  /// 「歌手1/歌手2」→ 第一个（主唱）
  static String _firstArtist(String artist) {
    final parts = artist.split(RegExp('[/、,&]'));
    for (final p in parts) {
      final t = p.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }
}

class _PreselectedCandidate {
  final VideoCandidate candidate;
  final double coarseScore;

  const _PreselectedCandidate({
    required this.candidate,
    required this.coarseScore,
  });
}

/// 详情缓存条目：结果 + 写入时刻（用于 TTL 判定）
class _CachedDetail {
  final VideoDetail detail;
  final DateTime at;

  const _CachedDetail(this.detail, this.at);
}

/// 搜索缓存条目：不可变候选列表 + 写入时刻（用于 TTL 判定）。
/// 列表存 [List.unmodifiable]，命中时再 `toList()` 出副本。
class _CachedSearch {
  final List<VideoCandidate> list;
  final DateTime at;

  const _CachedSearch(this.list, this.at);
}
