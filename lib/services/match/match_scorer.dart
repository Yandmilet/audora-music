/// Stage 4：六维加权打分 + 版本惩罚（设计文档 4.6 + v0.4 §5/§6）。
///
/// ## 为什么是六维而不是三维
/// NeriPlayer 用「标题 / 歌手 / 时长」三维就够，因为它是**播放时兜底**——
/// 匹配错了跳过即可。Audora 是**曲库级批量预匹配**，一次错配会被固化进
/// 数据库、反复播放到错误的音频。所以需要额外三个弱信号（UP主 / 分区标签 /
/// 文本规范度）在同一首歌的多个**正确候选**之间做排序。
///
/// 注意这三维的定位差异：
///   - 标题 + 时长（各 0.30）：做**判断**
///   - UP主 / 分区 / 规范度 / 发布先验：做**排序**
/// 混淆这两者会导致把弱信号当强证据用，那是准确率崩塌的开始。
///
/// ## v0.4 增量：版本惩罚（设计文档 §5）
/// 六维加权总分之外，再按标题版本特征扣分（伴奏 0.25 / 翻唱·cover·remix
/// 0.20 / Live·现场 0.05），见 [VersionDetector]。硬过滤（Stage 2）仍是
/// 二次创作的第一道闸，惩罚只是兜底网 + 覆盖「Live 不杀只罚」的语义。
/// 扣分值落 `score_detail.penalty` 供调参回溯。
library;

import '../../models/models.dart';
import '../bilibili/bili_dto.dart';
import 'match_config.dart';
import 'text_normalizer.dart';
import 'version_detector.dart';

/// 六维分数明细。落库到 `score_detail`，是后续调参的唯一依据。
class ScoreDetail {
  final double s1TitleArtist;
  final double s2Duration;
  final double s3Uploader;
  final double s4Publish;
  final double s5Category;
  final double s6Format;

  /// v0.4：版本惩罚扣分（[VersionDetector.penalty]，0 ~ 0.25）。
  /// 带默认值 0：老 score_detail JSON 无此键，`parsedDetail` 解析时兜 0。
  final double penalty;

  const ScoreDetail({
    required this.s1TitleArtist,
    required this.s2Duration,
    required this.s3Uploader,
    required this.s4Publish,
    required this.s5Category,
    required this.s6Format,
    this.penalty = 0.0,
  });

  Map<String, double> toJson() => {
        's1': double.parse(s1TitleArtist.toStringAsFixed(4)),
        's2': double.parse(s2Duration.toStringAsFixed(4)),
        's3': double.parse(s3Uploader.toStringAsFixed(4)),
        's4': double.parse(s4Publish.toStringAsFixed(4)),
        's5': double.parse(s5Category.toStringAsFixed(4)),
        's6': double.parse(s6Format.toStringAsFixed(4)),
        'penalty': double.parse(penalty.toStringAsFixed(4)),
      };

  @override
  String toString() => 'S1=${s1TitleArtist.toStringAsFixed(2)} '
      'S2=${s2Duration.toStringAsFixed(2)} '
      'S3=${s3Uploader.toStringAsFixed(2)} '
      'S4=${s4Publish.toStringAsFixed(2)} '
      'S5=${s5Category.toStringAsFixed(2)} '
      'S6=${s6Format.toStringAsFixed(2)} '
      'P=${penalty.toStringAsFixed(2)}';
}

/// 打分结果：总分 + 明细 + 分级
class ScoredCandidate {
  final VideoCandidate video;
  final double total;
  final ScoreDetail detail;
  final MatchConfidence confidence;

  const ScoredCandidate({
    required this.video,
    required this.total,
    required this.detail,
    required this.confidence,
  });

  /// 百分制，UI 展示用
  int get score100 => (total * 100).round();

  @override
  String toString() => '${video.bvid} "$video.title" '
      '$score100分 (${confidence.label}) [$detail]';
}

class MatchScorer {
  MatchScorer._();

  /// 主入口：对单个候选算总分并分级。
  ///
  /// [songDurationSec] <= 0 表示歌曲时长缺失，走降级路径：
  /// 时长维度给中性分、权重归一化、置信度上限压到 REVIEW
  /// （设计文档 10.1：不允许在缺关键物理证据时自动绑定）。
  ///
  /// [trustedUploaderMids]：v0.7 跨歌学习。已被其他歌曲验证过的 UP 主 mid 集合，
  /// 传入后 S3 维度会给这些 UP 主的候选额外加分。空集 = 不启用跨歌学习。
  static ScoredCandidate score(
    VideoCandidate video,
    Song song, {
    Set<int> trustedUploaderMids = const {},
  }) {
    final songMs = song.duration * 1000;
    final hasDuration = songMs > 0;
    final artists = _splitArtists(song.artist);
    final hasArtist = artists.isNotEmpty;

    final s1 = _titleArtistScore(video, song, artists);
    final s2 = hasDuration
        ? _durationScore(video.durationMs, songMs)
        : MatchConfig.durationNeutralScore;
    final s3 = _uploaderScore(video, song, artists, trustedUploaderMids);
    final s4 = _publishScore(video.pubdate, song.releaseDate);
    final s5 = _categoryScore(video, song);
    final s6 = _formatScore(video.title, song);

    final rawTotal = _weightedSum(
      s1: s1,
      s2: s2,
      s3: s3,
      s4: s4,
      s5: s5,
      s6: s6,
      hasDuration: hasDuration,
      hasArtist: hasArtist,
    );

    // v0.4 §5：版本惩罚在加权总分之后扣，clamp 保底 0。
    // 输入用原始标题（含【】标签原文），标签词天然参与判定。
    final penalty = VersionDetector.penalty(video.title);
    final total = (rawTotal - penalty).clamp(0.0, 1.0);

    final detail = ScoreDetail(
      s1TitleArtist: s1,
      s2Duration: s2,
      s3Uploader: s3,
      s4Publish: s4,
      s5Category: s5,
      s6Format: s6,
      penalty: penalty,
    );

    var confidence = grade(total, detail);

    // 降级：时长缺失时不允许 AUTO
    if (!hasDuration && confidence == MatchConfidence.auto) {
      confidence = MatchConfidence.review;
    }
    // 降级：歌手缺失（纯音乐/器乐）且时长也缺失，证据链太弱
    if (!hasArtist && !hasDuration) {
      confidence = MatchConfidence.review;
    }

    return ScoredCandidate(
      video: video,
      total: total,
      detail: detail,
      confidence: confidence,
    );
  }

  /// 加权求和，并在维度缺失时**重新归一化**而不是简单给 0
  /// （给 0 等于把「不知道」当成「否定」，会系统性压低所有候选）。
  static double _weightedSum({
    required double s1,
    required double s2,
    required double s3,
    required double s4,
    required double s5,
    required double s6,
    required bool hasDuration,
    required bool hasArtist,
  }) {
    // 歌手缺失时，把歌手维度的权重并入标题维度（设计文档 10.1「权重转移」）
    final w1 = hasArtist
        ? MatchConfig.wTitleArtist
        : MatchConfig.wTitleWhenNoArtist;
    final w3 = hasArtist ? MatchConfig.wUploader : 0.0;
    // 时长缺失时，该维度不参与，其权重由分母归一化自动分摊
    final w2 = hasDuration ? MatchConfig.wDuration : 0.0;

    final weightSum = w1 +
        w2 +
        w3 +
        MatchConfig.wPublish +
        MatchConfig.wCategory +
        MatchConfig.wFormat;
    if (weightSum <= 0) return 0;

    final weighted = w1 * s1 +
        w2 * s2 +
        w3 * s3 +
        MatchConfig.wPublish * s4 +
        MatchConfig.wCategory * s5 +
        MatchConfig.wFormat * s6;

    // 除以实际参与的权重总和，把结果还原到 0-1 尺度。
    // 正常情况（六维齐全）weightSum = 1.0，这一步是恒等变换；
    // 缺维度时它保证总分不会因为「少算了一项」而凭空下跌。
    return weighted / weightSum;
  }

  // ── 维度一：标题 + 歌手（设计文档 4.6.2）────────────────────

  static double _titleArtistScore(
    VideoCandidate video,
    Song song,
    List<String> artists,
  ) {
    final nTitle = TextNormalizer.normalize(song.title);
    final nVideo = TextNormalizer.normalize(video.title);
    if (nTitle.isEmpty) return 0;

    // Step 2：歌名匹配度
    final double tTitle;
    if (nVideo == nTitle) {
      tTitle = 1.00;
    } else if (TextNormalizer.hasStandardFormat(video.title) &&
        nVideo.contains(nTitle)) {
      // ★ 提升自动绑定率的最大单点改进（设计文档 4.6.2 明确标注）：
      // B站音乐投稿绝大多数是「歌手 - 歌名」格式，给满分能让搬运正例
      // 从 0.76（REVIEW）升到 0.93（AUTO）。
      tTitle = 1.00;
    } else if (nVideo.contains(nTitle)) {
      tTitle = 0.85;
    } else if (nTitle.contains(nVideo) && nVideo.length >= 4) {
      tTitle = 0.60;
    } else if (TextNormalizer.isFuzzyMatch(nVideo, nTitle, 0.85)) {
      tTitle = 0.45;
    } else if (TextNormalizer.isFuzzyMatch(nVideo, nTitle, 0.65)) {
      tTitle = 0.20;
    } else {
      tTitle = 0.00;
    }

    // Step 3：歌手匹配度
    final tArtist = _artistScore(video, artists);

    // Step 4：合并
    if (tTitle == 0.0) return 0.0;
    if (tArtist == 0.0) {
      // 歌名命中但歌手一个都对不上：大概率是翻唱 / 同曲不同词 / 同名不同曲，
      // 可信度打骨折（设计文档 4.6.2）
      return tTitle * 0.55;
    }
    return tTitle * 0.55 + tArtist * 0.45;
  }

  /// 歌手匹配：标题命中 > UP主名命中 > 模糊命中；越靠前（主唱）权重越高
  static double _artistScore(VideoCandidate video, List<String> artists) {
    if (artists.isEmpty) return 0.0;

    final nVideo = TextNormalizer.normalize(video.title);
    final nAuthor = TextNormalizer.normalize(video.author);

    var best = 0.0;
    for (var idx = 0; idx < artists.length; idx++) {
      final nArtist = TextNormalizer.normalize(artists[idx]);
      if (nArtist.isEmpty) continue;

      final posFactor = switch (idx) {
        0 => 1.00,
        1 => 0.85,
        _ => 0.70,
      };

      final double hit;
      if (nVideo.contains(nArtist)) {
        hit = 1.0;
      } else if (nAuthor.isNotEmpty && nAuthor.contains(nArtist)) {
        hit = 0.8; // UP主名含歌手名，可能是官方账号
      } else if (TextNormalizer.fuzzyContains(nVideo, nArtist, 0.85)) {
        hit = 0.5;
      } else {
        hit = 0.0;
      }

      final weighted = hit * posFactor;
      if (weighted > best) best = weighted;
    }
    return best;
  }

  // ── 维度二：时长（设计文档 4.6.3 + v0.7 混合分档）──────────

  /// 唯一的物理硬证据——标题可以乱写，时长骗不了人。
  ///
  /// ## v0.7 混合分档（绝对差 + 相对比例保底）
  /// 原来只用绝对差（diff ≤ 5s → 0.80），对短歌太松：
  /// 30s 差 5s = 17% 偏差，Stage 2 动态容忍（15% × 30s = 4.5s）已经
  /// 接近拒绝，但打分还给 0.80。现在先按绝对差分档保留精细度，
  /// 再用相对比例做降级保底——保证打分和 Stage 2 硬过滤哲学一致。
  ///
  /// 设计文档 4.6.3 的笔误已在首版修正：用 videoMs/songMs 比值
  /// 而不是 diff/songMs 判断 50% 长度差（后者永远 ≤ 1.0）。
  static double _durationScore(int videoMs, int songMs) {
    if (songMs <= 0) return MatchConfig.durationNeutralScore;
    final diff = (videoMs - songMs).abs();

    // 1) 绝对差分档（保留原始精细度，长歌区仍靠绝对差区分）
    double base;
    if (diff <= 1500) {
      base = 1.00;
    } else if (diff <= 3000) {
      base = 0.92;
    } else if (diff <= 5000) {
      base = 0.80;
    } else if (diff <= 10000) {
      base = 0.55;
    } else if (diff <= 20000) {
      base = 0.25;
    } else {
      base = 0.05;
    }

    // 2) 相对比例保底：短歌的绝对差会被比例降级
    // 阈值与 Stage 2 动态容忍（15%）对齐
    final ratio = diff / songMs;
    if (ratio > 0.35 && base > 0.25) base = 0.25;
    if (ratio > 0.25 && base > 0.55) base = 0.55;
    if (ratio > 0.15 && base > 0.80) base = 0.80;

    // 3) 极端比例归零（视频比歌曲长 1.5 倍 / 短到只剩 2/3）
    final longerRatio = videoMs / songMs;
    final shorterRatio = songMs / videoMs;
    if (longerRatio > 1.5 || shorterRatio > 1.5) base = 0.00;

    return base;
  }

  // ── 维度三：UP主可信度（设计文档 4.6.4）────────────────────

  static double _uploaderScore(
    VideoCandidate video,
    Song song,
    List<String> artists,
    Set<int> trustedUploaderMids,
  ) {
    var score = 0.4; // 基础分

    // v0.7：UP 主已被其他歌曲验证过（跨歌学习信号）
    // 同一个 UP 主发过正确音源 → 值得更高的初始信任度
    if (trustedUploaderMids.isNotEmpty &&
        video.mid > 0 &&
        trustedUploaderMids.contains(video.mid)) {
      score += 0.20;
    }

    // UP主名与歌手名高度重合（官方账号 / 官方 MCN）
    final nAuthor = TextNormalizer.normalize(video.author);
    if (nAuthor.isNotEmpty) {
      for (final a in artists) {
        final nA = TextNormalizer.normalize(a);
        if (nA.isNotEmpty && nAuthor.contains(nA)) {
          score += 0.3;
          break;
        }
      }
    }

    if (MatchConfig.musicPartitions.contains(video.typename)) score += 0.15;

    if (video.play > 100000) score += 0.1;
    if (video.play > 1000000) score += 0.05;

    return score > 1.0 ? 1.0 : score;
  }

  // ── 维度四：发布先验（设计文档 4.6.5）──────────────────────

  /// 时间逻辑：B站视频不可能发布于歌曲发行之前。
  ///
  /// ★ v0.2 的两处修正都必须保留：
  ///   1. 「早于发行 30 天以上」从 0.10 改归零
  ///   2. 「3~10 年」从 0.45 上调到 0.75 —— 老歌搬运是高频正例，重罚会误杀
  static double _publishScore(int videoPubdate, DateTime? releaseDate) {
    if (releaseDate == null) return 0.5; // 无发行时间，给中性分

    final releaseSec = releaseDate.millisecondsSinceEpoch ~/ 1000;
    if (videoPubdate <= 0) return 0.5;

    final gapDays = (videoPubdate - releaseSec) ~/ 86400;

    if (gapDays < -30) return 0.00; // 早于发行 30 天以上，基本可判异常
    if (gapDays < 0) return 0.50; // 早于发行，存疑
    if (gapDays <= 365) return 1.00; // 一年内，最佳窗口
    if (gapDays <= 365 * 3) return 0.90;
    if (gapDays <= 365 * 10) return 0.75;
    return 0.60; // 十年以上，多为音频修复 / 搬运
  }

  // ── 维度五：分区与标签（设计文档 4.6.6）────────────────────

  static double _categoryScore(VideoCandidate video, Song song) {
    var s = 0.3;

    if (MatchConfig.musicPartitions.contains(video.typename)) s += 0.3;
    if (MatchConfig.lowRelevancePartitions.contains(video.typename)) s -= 0.3;

    final tags = TextNormalizer.normalize(video.tag);
    if (tags.isNotEmpty) {
      if (tags.contains(TextNormalizer.normalize(song.title))) s += 0.15;
      final artists = _splitArtists(song.artist);
      for (final a in artists) {
        if (tags.contains(TextNormalizer.normalize(a))) {
          s += 0.15;
          break;
        }
      }
      if (song.album.isNotEmpty &&
          tags.contains(TextNormalizer.normalize(song.album))) {
        s += 0.1;
      }
    }

    return s.clamp(0.0, 1.0);
  }

  // ── 维度六：文本规范度（设计文档 4.6.7）────────────────────

  /// 弱先验，仅用于同分候选的区分。别指望它做判断。
  static double _formatScore(String videoTitle, Song song) {
    var s = 0.3;

    if (TextNormalizer.hasStandardFormat(videoTitle)) s += 0.2;

    final len = videoTitle.length;
    if (len >= 5 && len <= 60) {
      s += 0.2;
    } else if (len >= 61 && len <= 90) {
      s += 0.05;
    }

    // 标题小写与营销词小写副本都预计算，不再每词重复 toLowerCase
    // （containsIgnoreCase 语义保持：空词恒不命中）。
    final titleLower = videoTitle.toLowerCase();
    final hasMarketing = MatchConfig.marketingWordsLower
        .any((w) => w.isNotEmpty && titleLower.contains(w));
    if (!hasMarketing) s += 0.15;

    final idx = videoTitle.indexOf(song.title);
    if (idx >= 0 && idx <= 25) s += 0.15;

    return s.clamp(0.0, 1.0);
  }

  // ── 工具 ─────────────────────────────────────────────────

  /// 「歌手1/歌手2」→ 列表，保留原始顺序（首位是主唱，影响权重）
  static List<String> _splitArtists(String artist) {
    if (artist.trim().isEmpty) return const [];
    return artist
        .split(RegExp('[/、,&]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 总分 → 置信度分级（设计文档 4.6.8 + v0.7 判断维抬升）
  ///
  /// ## v0.7 抬升规则：S1 + S2 双高 → 直接 AUTO
  /// 贯彻「标题+时长做判断，弱信号只做排序」的设计哲学：
  /// S1≥0.93（标准格式命中或精确包含）且 S2≥0.80（时长差 ≤ 5s）时，
  /// 正确概率极高。但弱信号（S3/S4/S5/S6）的低分可能把 total 压到
  /// 0.60~0.70 区间（如 UP 主是普通搬运号、分区标了「生活」），
  /// 导致本该 AUTO 的候选被推给人工确认。
  ///
  /// 抬升触发条件：
  ///   - S1 ≥ 0.93 且 S2 ≥ 0.80（双硬证据充足）
  ///   - penalty < 0.15（非翻唱/伴奏/不插电等二次创作；Live 的 0.05 允许抬升）
  ///
  /// 不抬升的边界：
  ///   - 时长缺失时 S2 = 0.5 < 0.80 → 自动不触发
  ///   - 纯音乐（无歌手）时 S1 上限 0.55 → 无法到 0.93 → 自动不触发
  ///   - 版本惩罚 ≥ 0.15（翻唱/伴奏）→ 尊重惩罚结果
  ///   - 抬升后若缺少关键证据（时长缺失），score() 末尾的降级规则仍会压到 REVIEW
  static MatchConfidence grade(double total, [ScoreDetail? detail]) {
    // ★ 判断维双高抬升（仅当有 detail 时才可用）
    if (detail != null &&
        detail.s1TitleArtist >= 0.93 &&
        detail.s2Duration >= 0.80 &&
        detail.penalty < 0.15) {
      return MatchConfidence.auto;
    }

    if (total >= MatchConfig.autoThreshold) return MatchConfidence.auto;
    if (total >= MatchConfig.reviewThreshold) return MatchConfidence.review;
    return MatchConfidence.rejected;
  }
}
