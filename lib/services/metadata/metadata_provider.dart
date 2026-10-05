/// 元数据 Provider 抽象接口 —— 搜索 / 详情 / 歌词 / 批量解析。
///
/// 本接口定义「如何把一段文字（歌名 + 歌手）变成一首有完整元数据的歌」。
/// 当前由 [QQMusicProvider] 实现（通过 QQMusicMetadataAdapter），
/// 未来换网易云 / Spotify / 本地音乐库都只需再写一个 Adapter。
///
/// ## 职责边界
/// 本接口只管**元数据**：歌名、歌手、专辑、封面、时长、发行时间、歌词、词曲编。
/// 音源（去哪里找音频文件、怎么拉流）由 [AudioSourceProvider] 负责。
/// 匹配引擎（怎么把元数据和音源关联起来）保持在 [MatchEngine] 内部。
library;

import '../../models/models.dart';

// ═══════════════════════════════════════════════════════════════
// 通用 DTO —— 源无关
// ═══════════════════════════════════════════════════════════════

/// 源无关的歌曲元数据中间表示。
///
/// 不同音乐源（QQ音乐 / 网易云 / Spotify 等）的搜索 / 详情接口返回字段各不相同，
/// 这里做一次归一化。调用方（LibraryRepository）只认这一套字段。
///
/// ## 与领域模型 [Song] 的区别
/// [Song] 是纯领域对象，刻意不含存储概念（没有 sourceId）。
/// [MetaSong] 是 Provider 边界上的中间表示，**必须带** sourceId ——
/// 它是后续取歌词、入库去重的唯一凭据。丢掉它，歌词功能静默失效。
class MetaSong {
  /// 这个源内部的唯一标识（QQ的 songMid / 网易云的 id / Spotify 的 track uri 等）。
  /// **不能为空** —— 空意味着入库时只能派生 `local:` 兜底键。
  final String sourceId;

  /// 元数据来源标识（'qq' / 'netease' / 'spotify' / …）。
  /// 用于日志、UI 展示、以及 Repository 按源做分支（例如歌词获取）。
  final String sourceType;

  final String title;

  /// 多歌手保留原始顺序（首位是主唱，影响匹配引擎权重）。
  final List<String> artists;

  final String album;

  /// 时长（秒）
  final int durationSec;

  /// 专辑 / 封面的源内部标识（QQ 的 albumMid / 网易云的 album id）。
  /// 用于拼封面 URL；为空时 coverUrl 可能仍有值（源直接返回了 URL）。
  final String coverSourceId;

  /// 封面 URL。源直接返回就填这里；需要用 coverSourceId 拼接的由 Adapter 负责。
  final String? coverUrl;

  final DateTime? releaseDate;

  /// 副标题（形如「原曲：《ヤキモチ》—高桥优」），某些源有。
  final String subtitle;

  const MetaSong({
    required this.sourceId,
    required this.sourceType,
    required this.title,
    this.artists = const [],
    this.album = '',
    this.durationSec = 0,
    this.coverSourceId = '',
    this.coverUrl,
    this.releaseDate,
    this.subtitle = '',
  });

  String get artistString => artists.join('/');

  bool get hasSourceId => sourceId.isNotEmpty;
}

/// 通用的创作者信息（作词 / 作曲 / 编曲）。
///
/// 不同源返回方式不同：有的在 JSON 里直接给，有的藏在 LRC 歌词头部。
/// Adapter 负责统一。
class MetaCredits {
  final String? lyricist;
  final String? composer;
  final String? arranger;

  const MetaCredits({this.lyricist, this.composer, this.arranger});

  static const empty = MetaCredits();

  bool get isEmpty =>
      (lyricist == null || lyricist!.trim().isEmpty) &&
      (composer == null || composer!.trim().isEmpty) &&
      (arranger == null || arranger!.trim().isEmpty);
}

/// 通用的歌词结果。
///
/// 原文 [lrc] 是必带的；译文 [translation] 和创作者 [credits] 拿不到就给 null。
/// 不同源对译文的支持差异很大：QQ 匿名请求不给译文、网易云给 tlyric、Spotify 根本没译文。
/// 调用方应该用 [hasTranslation] 判断，不要假设一定有。
class MetaLyric {
  /// 原文 LRC（已解码的纯文本）
  final String lrc;

  /// 译文 LRC。拿不到译文时为 null —— 不要与「译文为空字符串」混淆。
  final String? translation;

  /// 创作者信息（作词 / 作曲 / 编曲）。拿不到时为 [MetaCredits.empty]。
  final MetaCredits credits;

  const MetaLyric({
    required this.lrc,
    this.translation,
    this.credits = MetaCredits.empty,
  });

  bool get hasTranslation =>
      translation != null && translation!.trim().isNotEmpty;
}

// ── 批量解析 DTO ──────────────────────────────────────────────
//
// 这四个类型原本定义在 qqmusic_dto.dart，但它们是通用的「文字 → 歌曲」
// 流水线产物，与 QQ 无关。搬到这里让 MetadataProvider 的批量解析签名独立。

/// 批量解析的单条输入：标题 + 歌手 + 期望时长。
///
/// 严格模式（三重校验）必须知道期望时长，否则时长这一维失效。
/// 用三元组而非裸关键词，强制调用方把手上已有的信息交全 ——
/// 曲库导入的原始素材（B站收藏夹 / 本地歌单）天然带时长。
class BatchQuery {
  final String title;
  final String artist;

  /// 期望时长（秒）。<=0 表示调用方确实没有时长信息（会跳过该维度校验）。
  final int durationSec;

  /// 调用方自带的标识（如 B站 bvid），便于把失败结果映射回原始条目。
  final String refId;

  const BatchQuery({
    required this.title,
    required this.artist,
    this.durationSec = 0,
    this.refId = '',
  });

  @override
  String toString() => '$title - $artist'
      '${durationSec > 0 ? ' (${durationSec}s)' : ''}';
}

/// 一条被淘汰的记录。批量导入最怕「30 首进去、24 首出来、不知道丢的是哪 6 首」。
class BatchRejection {
  final BatchQuery query;
  final String reason;

  const BatchRejection(this.query, this.reason);

  @override
  String toString() => '${query.refId.isNotEmpty ? '[${query.refId}] ' : ''}'
      '$query → $reason';
}

/// 批量解析的单条成功结果。
///
/// 领域模型 [Song] **刻意不含存储字段**（没有 sourceId / coverSourceId），
/// 所以 Provider 返回时必须把这两个源主键与 Song 一起带回 ——
/// 丢了 sourceId，入库只能派生 `local:` 兜底键，歌词功能静默失效。
class ResolvedEntry {
  /// 输入 query（用于对齐诊断信息 / 取调用方自带的 refId）
  final BatchQuery query;

  /// 解析出的领域对象（不含存储字段）
  final Song song;

  /// 源内部的歌曲唯一标识（QQ 的 songMid / 网易云的 id / …）。**入库必须用它**。
  final String sourceId;

  /// 专辑 / 封面的源内部标识，用于拼封面 URL；可能为空。
  final String coverSourceId;

  const ResolvedEntry({
    required this.query,
    required this.song,
    required this.sourceId,
    this.coverSourceId = '',
  });

  @override
  String toString() => 'ResolvedEntry($sourceId, ${song.title})';
}

/// 批量解析的完整结果。
///
/// ## 为什么 successes / rejections 而不是平行 List
/// `songs` 与输入的 `queries` **索引不对齐**——失败项被跳过了，
/// 调用方若天真地用 `queries[i]` 去取对应输入，只要前面失败过一首，
/// 后面全部错位。用 (query, song) 配对，从类型上杜绝错位。
class BatchResolveResult {
  /// 成功项：输入 query / Song / 真实 sourceId 三者配对
  final List<ResolvedEntry> successes;

  final List<BatchRejection> rejections;

  const BatchResolveResult({
    required this.successes,
    required this.rejections,
  });

  List<Song> get songs => successes.map((e) => e.song).toList();

  int get total => successes.length + rejections.length;
  int get successCount => successes.length;
  int get rejectedCount => rejections.length;

  double get successRate => total == 0 ? 0 : successCount / total;

  @override
  String toString() =>
      'BatchResolveResult($successCount/$total 成功, '
      '${(successRate * 100).toStringAsFixed(0)}%)';
}

// ═══════════════════════════════════════════════════════════════
// 抽象接口
// ═══════════════════════════════════════════════════════════════

/// 元数据 Provider 抽象接口。
///
/// 实现方只需要把「一个关键词」变成「一首带完整元数据的歌」，
/// 至于接口叫什么、鉴权怎么做、限频怎么控 —— 全是 Adapter 内部的事。
///
/// ## 实现方约束
/// - 所有方法在网络失败时**必须抛异常**（由调用方 catch），
///   不要静默返回 null 或空列表（除非是真的「没有结果」）。
/// - 返回空列表不视为失败。
/// - sourceId 为空字符串的条目视为无效，调用方应该跳过。
abstract class MetadataProvider {
  /// 元数据来源标识（用于日志 / UI 展示 / Repository 按源分支）。
  ///
  /// 约定值：'qq' / 'netease' / 'spotify' / …
  String get sourceType;

  // ── 核心能力 ─────────────────────────────────────────────

  /// 搜索歌曲。返回按官方相关性排序的候选列表。
  ///
  /// [keyword] 可以是歌名、歌手、或组合。空关键词返回空列表。
  /// [pageSize] 是请求的候选上限，实际返回可能少于此数。
  Future<List<MetaSong>> search(String keyword, {int pageSize = 20});

  /// 拉歌曲详情（精确时长 / 发行日期 / 封面等补全）。
  ///
  /// 搜索接口返回的 [MetaSong] 字段可能是截断的、粗略的 ——
  /// 比如时长只精确到秒级整数、标题被截断、专辑封面缺失。
  /// 这个方法用 sourceId 去拉一次详情补全。
  ///
  /// 源上找不到时返回 null（不是抛异常）。
  Future<MetaSong?> fetchDetail(MetaSong base);

  /// 拉歌词（原文 LRC + 可选译文 LRC + 词曲编）。
  ///
  /// 拿不到歌词时返回 null（不是抛异常）—— 歌词属展示增强，
  /// 失败不应该影响播放主流程。
  Future<MetaLyric?> fetchLyric(String sourceId);

  /// 批量解析：把一批 (title, artist, durationSec) 三元组变成完整歌曲。
  ///
  /// 每一项走**严格三重校验**（标题互相包含 + 歌手命中 + 时长容差），
  /// 不合格的进 [BatchResolveResult.rejections] 而非静默丢弃。
  ///
  /// 内部应有串行间隔避免触发风控；并发度由实现方决定。
  Future<BatchResolveResult> resolveBatch(
    List<BatchQuery> queries, {
    int durationToleranceSec = 5,
    bool withLyricCredits = false,
    void Function(int done, int total)? onProgress,
    void Function(BatchQuery query, String reason)? onReject,
  });
}
