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
import 'title_parser.dart';
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

  /// P0-4：矛盾证据分（0 ~ 1.0）。
  /// B 站检测到的版本与 QQ 元数据预期版本不一致时产生。
  /// 越高越"这不是同一个录音"。矛盾 ≥ 0.5 时强制 REVIEW。
  final double contradiction;

  const ScoreDetail({
    required this.s1TitleArtist,
    required this.s2Duration,
    required this.s3Uploader,
    required this.s4Publish,
    required this.s5Category,
    required this.s6Format,
    this.penalty = 0.0,
    this.contradiction = 0.0,
  });

  Map<String, double> toJson() => {
        's1': double.parse(s1TitleArtist.toStringAsFixed(4)),
        's2': double.parse(s2Duration.toStringAsFixed(4)),
        's3': double.parse(s3Uploader.toStringAsFixed(4)),
        's4': double.parse(s4Publish.toStringAsFixed(4)),
        's5': double.parse(s5Category.toStringAsFixed(4)),
        's6': double.parse(s6Format.toStringAsFixed(4)),
        'penalty': double.parse(penalty.toStringAsFixed(4)),
        'contradiction': double.parse(contradiction.toStringAsFixed(4)),
      };

  @override
  String toString() => 'S1=${s1TitleArtist.toStringAsFixed(2)} '
      'S2=${s2Duration.toStringAsFixed(2)} '
      'S3=${s3Uploader.toStringAsFixed(2)} '
      'S4=${s4Publish.toStringAsFixed(2)} '
      'S5=${s5Category.toStringAsFixed(2)} '
      'S6=${s6Format.toStringAsFixed(2)} '
      'P=${penalty.toStringAsFixed(2)} '
      'C=${contradiction.toStringAsFixed(2)}';
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

/// P1 连续平滑辅助：时长差-分数控制点。
/// 线性插值在控制点之间平滑过渡，避免阶梯断崖。
class _DP {
  final int diff;
  final double score;
  const _DP(this.diff, this.score);
}

class MatchScorer {
  MatchScorer._();

  /// 主入口：对单个候选算总分并分级。
  ///
  /// [songDurationSec] <= 0 表示歌曲时长缺失，走降级路径：
  /// 时长维度给中性分、权重归一化、置信度上限压到 REVIEW
  /// （设计文档 10.1：不允许在缺关键物理证据时自动绑定）。
  ///
  /// [trustedUploaderProfile]：P1 Uploader Bayesian Profile。
  /// 已被其他歌曲验证过的 UP 主 mid → 正确次数映射。
  /// 传入后 S3 维度会按验证次数加权加分（首次验证 +0.12，封顶 0.25）。
  /// 空 map = 不启用跨歌学习。
  static ScoredCandidate score(
    VideoCandidate video,
    Song song, {
    Map<int, int> trustedUploaderProfile = const {},
  }) {
    final songMs = song.duration * 1000;
    final hasDuration = songMs > 0;
    final artists = _splitArtists(song.artist);
    final hasArtist = artists.isNotEmpty;

    final s1 = _titleArtistScore(video, song, artists);
    final s2 = hasDuration
        ? _durationScore(video.durationMs, songMs)
        : MatchConfig.durationNeutralScore;
    final s3 = _uploaderScore(video, song, artists, trustedUploaderProfile);
    final s4 = _publishScore(video, song);
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

    // P0-4：版本矛盾检测。B 站版本 与 QQ 预期版本 不一致时产生。
    // 矛盾分 ≥ 0.5 会在 grade() 里强制 REVIEW。
    final contradiction = _contradictionScore(song, video.title);

    final detail = ScoreDetail(
      s1TitleArtist: s1,
      s2Duration: s2,
      s3Uploader: s3,
      s4Publish: s4,
      s5Category: s5,
      s6Format: s6,
      penalty: penalty,
      contradiction: contradiction,
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
    final w1 =
        hasArtist ? MatchConfig.wTitleArtist : MatchConfig.wTitleWhenNoArtist;
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

  // ── 维度一：标题 + 歌手（设计文档 4.6.2 + P1-3 TitleParser）──────────

  static double _titleArtistScore(
    VideoCandidate video,
    Song song,
    List<String> artists,
  ) {
    final nTitle = TextNormalizer.normalize(song.title);
    final nVideo = TextNormalizer.normalize(video.title);
    if (nTitle.isEmpty) return 0;

    // P1-3：用 TitleParser 提取去标签后的干净标题 + 精确 artist 段。
    // 这解决 contains 路径的两个盲区：
    //   1. 【4K修复】张三 - 李四 - 完美 → contains(normalize(李四)) 容易在
    //      后半段命中，TitleParser 拆出 "李四 - 完美" 更精确地定位标题主体
    //   2. contains 命中 artist（hit=1.0）太宽松——任何位置出现就算，
    //      TitleParser 用 `-` 分隔符拆分出的前缀 artist 段更精确
    final parsed = TitleParser.parse(video.title);
    final nParsedTitle = TextNormalizer.normalize(parsed.title);
    final nParsedArtist = TextNormalizer.normalize(parsed.artist);

    // Step 2：歌名匹配度（两条路径：完整 normalize + TitleParser 去标签）
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

    // P1-3：用 parsed.title（去标签后）验证 contains 是否真的命中了标题主体。
    // 守卫严格：parsedTitle 必须以 songTitle 开头（带前缀标签但标题主体是 songTitle）。
    // 不能用 endsWith——"揭秘白浩寅背后的秘密"以"秘密"结尾就是假阳性。
    // 也不能用 contains 任意位置。允许 nParsedTitle == nTitle 的精确匹配但这种情况
    // 通常已经走了 nVideo == nTitle 或标准格式路径（tTitle=1.00），boost 加不加都行。
    final titleParserBoost = tTitle > 0.0 &&
            nParsedTitle != nTitle &&
            nParsedTitle.startsWith(nTitle) &&
            !TextNormalizer.hasStandardFormat(video.title)
        ? 0.04
        : 0.0;

    // Step 3：歌手匹配度
    final tArtist = _artistScore(video, artists);

    // P1-3：TitleParser 精确 artist 段验证。
    // contains 路径给 hit=1.0 太宽松——歌手名在标题任意位置出现就算。
    // TitleParser 用 `-` 拆分出标题前缀的 artist 段，精确比对：
    //   - 如果 contains 路径 artist 已经精确命中（hit=1.0）→ 不加（不重复）
    //   - 如果 contains 路径 artist 部分命中（hit<1.0）但 TitleParser 精确匹配
    //     → +0.06 bonus（更可靠的 artist 定位）
    final titleParserArtistBonus =
        tArtist < 1.0 && parsed.artist.isNotEmpty && nParsedArtist.isNotEmpty
            ? () {
                for (final a in artists) {
                  if (TextNormalizer.normalize(a) == nParsedArtist) return 0.06;
                }
                return 0.0;
              }()
            : 0.0;

    // Step 4：合并
    if (tTitle == 0.0) return 0.0;
    double base;
    if (tArtist == 0.0) {
      // 歌名命中但歌手一个都对不上：大概率是翻唱 / 同曲不同词 / 同名不同曲，
      // 可信度打骨折（设计文档 4.6.2）
      base = tTitle * 0.55;
    } else {
      base = tTitle * 0.55 + tArtist * 0.45;
    }

    // P0-3：Album Hit 加分。
    // B 站标题包含 QQ 专辑名 → 强信号（正确专辑 + 正确标题，不太可能是同名干扰）。
    // 要求 album ≠ title（避免 album="秘密", title="秘密" 这种自证）。
    final nAlbum = TextNormalizer.normalize(song.album);
    if (nAlbum.isNotEmpty &&
        nAlbum != nTitle &&
        nAlbum.length >= 2 &&
        nVideo.contains(nAlbum)) {
      // bonus 大小取决于 base 高低：base 低时加更多（有力补强），
      // base 已经很高时加一点即可（锦上添花）。
      final bonus = base < 0.7
          ? 0.10
          : base < 0.9
              ? 0.07
              : 0.04;
      base = (base + bonus).clamp(0.0, 1.0);
    }

    // P1-3：TitleParser 2.0 — 两个 bonus 叠加（已在 step 2/3 计算好）
    // titleParserBoost：去标签后 parsedTitle contains 歌名 → 小幅提信度
    // titleParserArtistBonus：contains 路径 artist 部分命中但 TitleParser 精确匹配
    base = (base + titleParserBoost + titleParserArtistBonus).clamp(0.0, 1.0);

    return base;
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

  // ── 维度二：时长（设计文档 4.6.3 + v0.7 + P1 连续平滑）──────────

  /// 唯一的物理硬证据——标题可以乱写，时长骗不了人。
  ///
  /// ## v0.7 混合分档（绝对差 + 相对比例保底）
  /// 原来只用绝对差（diff ≤ 5s → 0.80），对短歌太松：
  /// 30s 差 5s = 17% 偏差，Stage 2 动态容忍（15% × 30s = 4.5s）已经
  /// 接近拒绝，但打分还给 0.80。现在先按绝对差分档保留精细度，
  /// 再用相对比例做降级保底——保证打分和 Stage 2 硬过滤哲学一致。
  ///
  /// ## P1 连续平滑（替换阶梯分档）
  /// v0.7 是阶梯分档，边界处有断崖（diff=2999ms → 0.92；diff=3000ms → 0.80
  /// 差 0.12 分）。P1 改成**线性插值**在控制点之间平滑过渡：
  ///   diff=0 → 1.00, 1.5s→1.00, 3s→0.92, 5s→0.80, 10s→0.55, 20s→0.25, >20s→0.05
  /// 控制点数值完全复用 v0.7 阶梯值 → 6 个边界值测试断言不变。
  /// 比例守卫（0.15/0.25/0.35 阈值降级）和极端比例归零（1.5×）保持不变——
  /// 它们编码的领域知识比纯插值更可靠。
  static double _durationScore(int videoMs, int songMs) {
    if (songMs <= 0) return MatchConfig.durationNeutralScore;
    final diff = (videoMs - songMs).abs();

    // 1) P1 连续平滑：控制点定义 → 线性插值
    // 控制点 (diffMs, score)
    const points = <_DP>[
      _DP(0, 1.00),
      _DP(1500, 1.00),
      _DP(3000, 0.92),
      _DP(5000, 0.80),
      _DP(10000, 0.55),
      _DP(20000, 0.25),
    ];
    double base;
    if (diff <= points.first.diff) {
      base = points.first.score;
    } else if (diff > points.last.diff) {
      base = 0.05; // 超出最远控制点给低分保底
    } else {
      // 在两个相邻控制点之间线性插值
      base = 0.05; // 兜底值（正常情况下下面的循环会覆盖它）
      for (var i = 0; i < points.length - 1; i++) {
        final a = points[i];
        final b = points[i + 1];
        if (diff >= a.diff && diff <= b.diff) {
          final t = (diff - a.diff) / (b.diff - a.diff);
          base = a.score + (b.score - a.score) * t;
          break;
        }
      }
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

  // ── 维度三：UP主可信度（设计文档 4.6.4 + P1 Bayesian Profile）────────

  static double _uploaderScore(
    VideoCandidate video,
    Song song,
    List<String> artists,
    Map<int, int> trustedUploaderProfile,
  ) {
    var score = 0.4; // 基础分

    // P1 Uploader Bayesian Profile：按验证次数加权加分
    // 公式: bonus = min(0.25, 0.08 + count * 0.04)
    //   count=1 → 0.12, count=4 → 0.24, count=5+ → 0.25 封顶
    // 相比 v0.7 的固定 +0.20，新公式让新 UP 主（只验证过 1 次）更保守，
    // 多次验证后才给满信任度——避免一次偶然正确就把 UP 主判成顶级可信。
    if (trustedUploaderProfile.isNotEmpty && video.mid > 0) {
      final count = trustedUploaderProfile[video.mid] ?? 0;
      if (count >= 1) {
        final bonus = (0.08 + count * 0.04).clamp(0.0, 0.25);
        score += bonus;
      }
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
  // ── 维度四：发布先验（设计文档 4.6.5 + V0.9-10）────────────

  static double _publishScore(VideoCandidate video, Song song) {
    final releaseDate = song.releaseDate;
    if (releaseDate == null) return 0.5;

    final releaseSec = releaseDate.millisecondsSinceEpoch ~/ 1000;
    if (video.pubdate <= 0) return 0.5;

    final deltaSec = video.pubdate - releaseSec;
    // ⚠️ 这里必须按**天边界**取整，不能用 `~/ 86400`——Dart 的 ~/ 向零截断，
    // 负数 -30.9 天会截成 -30，于是掉进下一档 `gapDays < 0 → 0.65 预热档`，
    // 而「早于发行 30 天以上」本该判 0.00（不可能档）。即：正好早 30.9 天的
    // 视频会被当成正常预热视频加分。
    // `Duration.inDays` 同样是向零截断，所以先算差值再按符号分支取整，
    // 等价于向负无穷取整（floor），与下面的 `< -30` / `< 0` 分档边界对齐。
    final gapDays = deltaSec >= 0
        ? deltaSec ~/ 86400
        : -(((-deltaSec) + 86399) ~/ 86400);

    // V0.9-10：识别「老歌修复」正例信号——
    // 10 年以上老歌，但标题含 HD/4K/Remastered/重制/修复/官方修复 → 加分到 0.80
    // 分区是「音乐」且歌词/标签有相关关键词也加分
    final titleLower = video.title.toLowerCase();
    final isRestored = titleLower.contains('remaster') ||
        titleLower.contains('4k') ||
        titleLower.contains('超清') ||
        titleLower.contains('重制') ||
        titleLower.contains('修复') ||
        titleLower.contains('官方修复');

    if (gapDays < -30) return 0.00;

    // V0.9-10：发行前 0~30 天 = 预热/剧透期，不再打 0.50 存疑分
    if (gapDays < 0) return 0.65;

    if (gapDays <= 365) return 1.00;
    if (gapDays <= 365 * 3) return 0.90;
    if (gapDays <= 365 * 5) return 0.75;

    // V0.9-10：5 年以上分档——有修复信号的不重罚
    if (gapDays <= 365 * 10) {
      return isRestored ? 0.80 : 0.75;
    }
    // 10 年以上：老歌修复信号强 → 0.80，否则 0.60
    return isRestored ? 0.80 : 0.60;
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

  /// P0-4：矛盾证据检测（B 站版本 vs QQ 预期版本）。
  ///
  /// ## QQ 预期版本推断
  /// 从 Song.album 名称推断：专辑名含 Live/现场/演唱会 → 预期 live；
  /// 含 Unplugged/不插电/Acoustic → 预期 acoustic；默认预期 studio。
  ///
  /// ## 矛盾等级
  ///   ┌───────────────────┬────────────────────────────────────────┐
  ///   │ 0.90              │ 预期 studio + 检测到 instrumental        │
  ///   │ 0.80              │ 预期 studio + 检测到 cover / remix       │
  ///   │ 0.60              │ 预期 studio + 检测到 acoustic             │
  ///   │ 0.45              │ 预期 studio + 检测到 selfCover            │
  ///   │ 0.30              │ 预期 studio + 检测到 live（弱矛盾）      │
  ///   │ 0.25              │ 预期 live + 检测到 studio（弱矛盾）       │
  ///   │ 0.0               │ 版本吻合：预期 live + 检测到 live 等      │
  ///   └───────────────────┴────────────────────────────────────────┘
  static double _contradictionScore(Song song, String videoTitle) {
    // 1) 推断 QQ 预期版本
    final nAlbum = TextNormalizer.normalize(song.album);
    final expectedType = _inferExpectedVersion(nAlbum);

    // 2) B 站检测版本
    final detected = VersionDetector.classify(videoTitle);

    // 3) 版本类型比较（基础矛盾）
    double contradiction = _versionContradiction(expectedType, detected.type);

    // P0-3 增量：Album Distractor 弱矛盾补充。
    // B 站标题含 "精选集/Greatest Hits/自选集/代表作/合集" 这类通用合辑词，
    // 但 Song.album 是具体专辑名（不含这些通用词）→ 该候选可能不是目标专辑里的版本。
    if (nAlbum.isNotEmpty) {
      final distractorHit = _albumDistractorRegExp.hasMatch(videoTitle) ||
          videoTitle.contains('精选集') ||
          videoTitle.contains('Greatest Hits') ||
          videoTitle.contains('自选集') ||
          videoTitle.contains('代表作') ||
          videoTitle.contains('巅峰之作') ||
          videoTitle.contains('合集');
      final albumIsSpecific = !nAlbum.contains('精选集') &&
          !nAlbum.contains('Greatest') &&
          !nAlbum.contains('自选集') &&
          !nAlbum.contains('代表作') &&
          !nAlbum.contains('合集');
      if (distractorHit && albumIsSpecific) {
        contradiction = (contradiction + 0.20).clamp(0.0, 1.0);
      }
    }

    return contradiction;
  }

  static final RegExp _albumDistractorRegExp =
      RegExp(r'greatest\s*hits|best\s*of', caseSensitive: false);

  /// 从专辑名推断 QQ 元数据预期的版本类型。
  ///
  /// 专辑名 "XXX Live 演唱会" → live；"XXX Unplugged" → acoustic；
  /// 默认 studio（QQ 音乐绝大多数是 Studio 专辑）。
  static VersionType _inferExpectedVersion(String nAlbum) {
    if (nAlbum.isEmpty) return VersionType.studio;
    if (nAlbum.contains('live') ||
        nAlbum.contains('现场') ||
        nAlbum.contains('演唱会') ||
        nAlbum.contains('concert')) {
      return VersionType.live;
    }
    if (nAlbum.contains('unplugged') ||
        nAlbum.contains('不插电') ||
        nAlbum.contains('acoustic')) {
      return VersionType.acoustic;
    }
    return VersionType.studio;
  }

  /// 计算两种版本类型之间的矛盾程度（0~1）。
  /// 只有明确的"预期 X，检测到完全不是 X"才产生矛盾；
  /// 预期 unknown（QQ 元数据无信息）时不产生矛盾。
  static double _versionContradiction(
    VersionType expected,
    VersionType detected,
  ) {
    // 完全吻合 → 0
    if (expected == detected) return 0.0;

    // 预期 studio（绝大多数情况）
    switch (detected) {
      case VersionType.instrumental:
        return 0.90; // 伴奏 vs 原唱，几乎一定不是同一录音
      case VersionType.cover:
      case VersionType.chiptune:
        return 0.80;
      case VersionType.remix:
        return 0.75;
      case VersionType.acoustic:
        return 0.60;
      case VersionType.selfCover:
        return 0.45; // 同歌手重唱，矛盾较弱
      case VersionType.live:
        return 0.30; // Live 版本仍可能是同一录音的现场演绎
      case VersionType.studio:
        // B 站检测为 studio 但预期不是 → 也矛盾
        return 0.25;
      case VersionType.unknown:
        return 0.0; // B 站没检测到版本信号 → 不产生矛盾
    }
  }

  /// 「歌手1/歌手2」→ 列表，保留原始顺序（首位是主唱，影响权重）
  static List<String> _splitArtists(String artist) {
    if (artist.trim().isEmpty) return const [];
    return artist
        .split(RegExp('[/、,&]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 总分 → 置信度分级（设计文档 4.6.8 + v0.7 判断维抬升 + P0-4 矛盾降级）
  ///
  /// ## P0-4 矛盾降级（最高优先级）
  /// 矛盾分 ≥ 0.5 时，即使总分超过 AUTO 阈值也强制 REVIEW。
  /// 矛盾分 ≥ 0.75 时强制 REJECTED。
  /// 理由：一个 Studio 专辑的目标撞上 Instrumental/Cover，
  /// 即使时长一模一样，**本质上不是同一个录音**。
  ///
  /// ## v0.7 抬升规则：S1 + S2 双高 → 直接 AUTO
  /// 贯彻「标题+时长做判断，弱信号只做排序」的设计哲学。
  /// P0-4 额外守卫：contradiction < 0.5 才允许抬升——
  /// 版本矛盾高时，即使标题+时长完美命中也可能是翻唱/伴奏。
  static MatchConfidence grade(double total, [ScoreDetail? detail]) {
    // ★ P0-4 矛盾降级（最高优先级，先于抬升和阈值判断）
    if (detail != null) {
      if (detail.contradiction >= 0.75) {
        return MatchConfidence.rejected;
      }
      if (detail.contradiction >= 0.50) {
        // 矛盾高但还没到完全否定 → 强制 REVIEW，不让自动绑定
        if (total >= MatchConfig.autoThreshold) {
          return MatchConfidence.review;
        }
        // 原本就不够 AUTO → 维持原样
        if (total >= MatchConfig.reviewThreshold) {
          return MatchConfidence.review;
        }
        return MatchConfidence.rejected;
      }
    }

    // ★ v0.7 判断维双高抬升（仅当有 detail 时才可用）
    if (detail != null &&
        detail.s1TitleArtist >= 0.93 &&
        detail.s2Duration >= 0.80 &&
        detail.penalty < 0.15 &&
        (detail.contradiction == 0.0 || detail.contradiction < 0.30)) {
      return MatchConfidence.auto;
    }

    if (total >= MatchConfig.autoThreshold) return MatchConfidence.auto;
    if (total >= MatchConfig.reviewThreshold) return MatchConfidence.review;
    return MatchConfidence.rejected;
  }
}
