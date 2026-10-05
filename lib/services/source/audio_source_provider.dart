/// 音源 Provider 抽象接口 —— 搜索 / 详情 / 拉流。
///
/// 本接口定义「如何找到能播的音频源」：给一段文字关键词，返回候选列表；
/// 给 sourceKey + sourceSubKey，返回可播的音频直链（URL）。
///
/// 当前由 [BiliApi] 实现（通过 BiliAudioSourceAdapter），
/// 未来换 YouTube Music / 网易云音频直链 / 本地音乐库都只需再写一个 Adapter。
///
/// ## 职责边界
/// 本接口只管**音源**：候选搜索、详情补全、音频流 URL 解析。
/// 元数据（歌名 / 歌手 / 专辑 / 封面 / 歌词）由 [MetadataProvider] 负责。
/// 匹配引擎（怎么把一首歌和一个音源关联起来）保持在 [MatchEngine] 内部。
/// 缓存过期判定、自动重匹配等播放链路逻辑由 [SourceResolver] 负责 ——
/// 本接口只给原始能力，不关心这些。
library;

// ═══════════════════════════════════════════════════════════════
// 通用 DTO —— 源无关
// ═══════════════════════════════════════════════════════════════

/// 源无关的音源搜索候选。
///
/// 不同音频源返回的搜索结果字段不同 —— B站给 bvid + cid + 播放量，
/// YouTube Music 给 videoId + 时长 + 点赞数。这里统一成通用字段。
///
/// ## 与 MetadataProvider 的 MetaSong 的区别
/// MetaSong 描述「一首歌是什么」（歌名 + 歌手 + 专辑）。
/// SourceCandidate 描述「哪里有音频」（视频 / 音频文件 + 时长 + 热度）。
/// 匹配引擎（MatchEngine）负责把两者关联起来。
class SourceCandidate {
  /// 源类型标识（'bilibili' / 'youtube' / 'netease' / …）。
  final String sourceType;

  /// 源主键（B站 bvid / YouTube videoId / 网易云 track id 等）。
  /// **不能为空** —— 空意味着这条候选无法进一步请求详情或拉流。
  final String sourceKey;

  /// 源子键。多分区 / 多轨道 / 多版本的音频源需要它来精确定位
  /// （B站的 cid / YouTube Music 的 track index / …）。
  /// 没有子键的源保持为空字符串。
  final String sourceSubKey;

  final String title;
  final String author;
  final int durationSec;
  final int playCount;

  /// 分区名 / 类型标签（可选，用于匹配引擎的硬过滤）。
  final String category;

  const SourceCandidate({
    required this.sourceType,
    required this.sourceKey,
    this.sourceSubKey = '',
    this.title = '',
    this.author = '',
    this.durationSec = 0,
    this.playCount = 0,
    this.category = '',
  });

  int get durationMs => durationSec * 1000;

  bool get hasSourceKey => sourceKey.isNotEmpty;

  SourceCandidate copyWith({
    String? sourceType,
    String? sourceKey,
    String? sourceSubKey,
    String? title,
    String? author,
    int? durationSec,
    int? playCount,
    String? category,
  }) =>
      SourceCandidate(
        sourceType: sourceType ?? this.sourceType,
        sourceKey: sourceKey ?? this.sourceKey,
        sourceSubKey: sourceSubKey ?? this.sourceSubKey,
        title: title ?? this.title,
        author: author ?? this.author,
        durationSec: durationSec ?? this.durationSec,
        playCount: playCount ?? this.playCount,
        category: category ?? this.category,
      );

  @override
  String toString() => 'SourceCandidate($sourceKey/$sourceSubKey, '
      '"$title", $author, ${durationSec}s, play=$playCount)';
}

/// 音源的多分区条目（某些源把一首歌拆成多段）。
///
/// B站的 VideoPage 就是这个概念：一个 bvid 下有多个 cid，
/// 每个 cid 对应一段音频 / 一个分P。
class SourceSubItem {
  /// 这个分区的 sourceSubKey（B站的 cid 对应这里）
  final String sourceSubKey;

  /// 分区在父项中的顺序（1-based）
  final int pageIndex;

  /// 分区标题（B站叫 part，用户会给分P起名字）
  final String title;

  /// 这个分区单独的时长（秒）
  final int durationSec;

  const SourceSubItem({
    required this.sourceSubKey,
    required this.pageIndex,
    this.title = '',
    this.durationSec = 0,
  });
}

/// 源无关的音源详情（搜索结果可能不完整，用这个补全）。
///
/// 搜索接口通常只返回粗略时长和标题，详情接口才给精确时长、完整描述、
/// 所有分区列表等。匹配引擎的 Stage 3（精确校验）依赖详情接口的数据。
class SourceDetail {
  /// 源类型标识（与 [SourceCandidate.sourceType] 同值）
  final String sourceType;

  /// 源主键（与 [SourceCandidate.sourceKey] 同值）
  final String sourceKey;

  /// 默认 / 主分区的 sourceSubKey
  final String sourceSubKey;

  final String title;
  final String uploaderName;
  final int uploaderId;
  final int durationSec;
  final int playCount;
  final String coverUrl;

  /// 分区名 / 类型标签（与 SourceCandidate.category 同语义）。
  /// 用于匹配引擎的硬过滤。不可用时为空串。
  final String category;

  /// 所有分区（合辑场景）。只有一个分区时也是长度为 1 的列表。
  final List<SourceSubItem> subItems;

  /// 发布时间（Unix 时间戳，秒级）。不可用时为 0。
  final int pubdate;

  /// 标签（用于匹配引擎的硬过滤）。不可用时为空串。
  final String tag;

  const SourceDetail({
    required this.sourceType,
    required this.sourceKey,
    this.sourceSubKey = '',
    this.title = '',
    this.uploaderName = '',
    this.uploaderId = 0,
    this.durationSec = 0,
    this.playCount = 0,
    this.coverUrl = '',
    this.category = '',
    this.subItems = const [],
    this.pubdate = 0,
    this.tag = '',
  });

  int get durationMs => durationSec * 1000;
}

/// 源无关的音频流信息（拉流结果）。
///
/// 这是「能直接喂给播放器的 URL + 元信息」。不同源返回的流格式差异大：
/// B站给 DASH 音频流（mimeType 通常是 audio/mp4），
/// YouTube Music 给 opus 或 mp4 流，
/// 网易云可能给 m4a 直接链接。
///
/// Adapter 负责向源请求所有可用的音质档位，按 [qualityCeiling] 挑最优的返回。
/// 调用方（SourceResolver）拿到就直接播 —— 不关心内部的音质档位系统。
class AudioSourceInfo {
  /// 可播放的音频直链。**使用时必须带上** [AudioSourceProvider.requiredHeaders]
  /// 里的请求头 —— 某些 CDN（如 B站 bilivideo.com）会校验 Referer。
  final String url;

  /// 源内部的音质标识。用于落库缓存（下次可直接复用）。
  /// 每个源的音质 ID 体系不同，Adapter 内部知道怎么选。
  final int qualityId;

  /// 该流的实际码率（bytes/s），UI 可展示。
  final int bandwidth;

  final String mimeType;

  const AudioSourceInfo({
    required this.url,
    this.qualityId = 0,
    this.bandwidth = 0,
    this.mimeType = 'audio/mp4',
  });
}

// ═══════════════════════════════════════════════════════════════
// 抽象接口
// ═══════════════════════════════════════════════════════════════

/// 音源 Provider 抽象接口。
///
/// 实现方只需要把「一个关键词」变成「候选音频列表」，
/// 再把「sourceKey + sourceSubKey」变成「能播的 URL」。
///
/// ## 实现方约束
/// - 所有方法在网络失败时**必须抛异常**（由调用方 catch），
///   不要静默返回 null 或空列表（除非是真的「没有结果」）。
/// - 返回空列表不视为失败。
/// - sourceKey 为空字符串的条目视为无效，调用方应该跳过。
///
/// ## CDN 请求头
/// 某些源的 CDN 会校验请求头（Referer / User-Agent / Authorization 等）。
/// Adapter 必须把所有必要的头放在 [requiredHeaders] getter 里，
/// 调用方（SourceResolver）在请求音频 URL 时带上它。
/// 没有特殊头的源返回空 Map 即可。
abstract class AudioSourceProvider {
  /// 源类型标识（用于日志 / UI 展示 / Repository 按源分支）。
  ///
  /// 约定值：'bilibili' / 'youtube' / 'netease' / 'local' / …
  String get sourceType;

  /// 播放音频直链时需要额外带的请求头。
  ///
  /// 典型值：B站要求 `Referer: https://www.bilibili.com`
  /// 以及 `Origin: https://www.bilibili.com`；其他源可能不需要。
  /// 调用方（SourceResolver / just_audio 播放器）会在拉流请求里自动带上。
  ///
  /// 返回空 Map 表示没有特殊要求。
  Map<String, String> get requiredHeaders;

  // ── 核心能力 ─────────────────────────────────────────────

  /// 搜索音频候选。
  ///
  /// [keyword] 可以是歌名、歌手、或「歌名 + 歌手」组合。
  /// 空关键词返回空列表。
  ///
  /// [durationFilter] 是源特定的时长筛选参数（B站 0=全部/1=<10min/2=10-30min…）。
  /// 不同源的取值域不同 —— 传给 Adapter 让它翻译。
  ///
  /// [maxRetries] 允许调用方控制重试行为：交互式搜索传 1（快速反馈），
  /// 后台批量匹配传 3（稳健）。
  Future<List<SourceCandidate>> searchCandidates(
    String keyword, {
    int durationFilter = 0,
    int pageSize = 20,
    int maxRetries = 3,
  });

  /// 搜索并自动回退：分档搜不到时改全量搜。
  ///
  /// 这是一个**便利方法** —— 默认实现是：先按 durationFilter 搜，
  /// 结果为空且 filter != 0 时再用 filter=0 搜一次。
  /// 源有自己的「按时长搜」机制时可以 override 这个默认实现。
  Future<List<SourceCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int pageSize = 20,
    int maxRetries = 3,
  }) async {
    var items = await searchCandidates(
      keyword,
      durationFilter: durationFilter,
      pageSize: pageSize,
      maxRetries: maxRetries,
    );
    if (items.isEmpty && durationFilter != 0) {
      items = await searchCandidates(
        keyword,
        durationFilter: 0,
        pageSize: pageSize,
        maxRetries: maxRetries,
      );
    }
    return items;
  }

  /// 音源详情。用于补全搜索结果里缺失的字段（精确时长 / 分区列表等）。
  ///
  /// 源上找不到时返回 null（不是抛异常）—— 视频被删 / 权限不足 /
  /// 分P被合并都属正常淘汰，不视为网络失败。
  Future<SourceDetail?> fetchSourceDetail(String sourceKey);

  /// 解析音频流 URL —— 把 sourceKey + sourceSubKey 变成能播的 URL。
  ///
  /// [qualityCeiling] 是用户的音质上限偏好（0 = 不限制）。
  /// Adapter 向源请求**所有可用音质**，在不超过 ceiling 的范围内挑最高的返回。
  /// 若该音源**只有高于 ceiling 的档**，返回可用的最高档（宁肯音质好一点也别静默无声）。
  ///
  /// 音源无可用音频时返回 null（不是抛异常）—— 充电专属 / 下架 / 被删都属正常。
  Future<AudioSourceInfo?> fetchAudioStream(
    String sourceKey,
    String sourceSubKey, {
    int qualityCeiling = 0,
  });
}
