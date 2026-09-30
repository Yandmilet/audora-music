/// 匹配算法的全部可调参数集中在这里。
///
/// 对应设计文档附录 A「核心配置项集中管理」——把权重、阈值、黑名单
/// 从算法逻辑里剥离出来，调参时只改这一个文件，不用碰打分代码。
///
/// ## 调参的正确姿势
/// 不要凭感觉改数字。设计文档 5.2 给的标定方法才是正路：
/// 人工标注 100 首 → 跑算法 → 画「阈值-准确率」曲线 → 选准确率 ≥97%
/// 的最低分作 AUTO 阈值。`score_detail` 落库就是为了积累这些样本。
library;

/// 置信度分级（设计文档 4.6.8）
enum MatchConfidence {
  /// ≥ AUTO_THRESHOLD：自动绑定，用户无感
  auto,

  /// REVIEW_THRESHOLD ~ AUTO_THRESHOLD：进人工队列，UI 预选最高分
  review,

  /// < REVIEW_THRESHOLD：不自动绑定，仅留在备选池
  rejected,
}

extension MatchConfidenceX on MatchConfidence {
  String get label => switch (this) {
        MatchConfidence.auto => 'AUTO',
        MatchConfidence.review => 'REVIEW',
        MatchConfidence.rejected => 'REJECTED',
      };

  /// 是否已自动绑定（可直接播放）
  bool get isBound => this == MatchConfidence.auto;
}

/// 匹配类型（落库用，对应设计文档 3.3 的 `match_type`）
enum MatchType {
  autoMatched,
  manualBound,
  userSelected,
}

extension MatchTypeX on MatchType {
  String get label => switch (this) {
        MatchType.autoMatched => 'AUTO_MATCHED',
        MatchType.manualBound => 'MANUAL_BOUND',
        MatchType.userSelected => 'USER_SELECTED',
      };
}

class MatchConfig {
  MatchConfig._();

  // ── 六维权重（设计文档 4.6.1，v0.2 标定值）─────────────────
  //
  // 标题(0.30) + 时长(0.30) = 0.60，两个性质完全不同的维度共同主导：
  // 标题会被「翻唱同名」骗过，时长会被「同样长的同曲」骗过，
  // 但两者同时命中时正确概率极高 —— 这是整套算法抗噪的根本。
  static const double wTitleArtist = 0.30;
  static const double wDuration = 0.30;

  /// v0.2 由 0.12 上调：音乐区活跃搬运号才是搬运正例的真正特征信号
  static const double wUploader = 0.19;

  /// v0.2 由 0.13 下调：老歌由 UP 主近年搬运是高频正例，重罚会大量误杀
  static const double wPublish = 0.06;

  static const double wCategory = 0.08;
  static const double wFormat = 0.07;

  // ── 阈值 ──────────────────────────────────────────────────
  static const double autoThreshold = 0.82;
  static const double reviewThreshold = 0.62;

  // ── Stage 2 硬过滤 ────────────────────────────────────────

  /// 时长粗筛容忍（毫秒）。用绝对值判断，因为音乐视频常加片头/封面页，
  /// 导致 B站时长**比歌曲略长**，单向条件会误杀。
  static const int durationToleranceMs = 30 * 1000;

  /// 零播放 + 30 天内发布 → 多为废稿
  static const int zeroPlayAgeDays = 30;

  // ── Stage 3 精确校验 ──────────────────────────────────────

  /// 分P时长匹配容忍（毫秒），设计文档 4.5.2
  static const int pageMatchToleranceMs = 5 * 1000;

  /// Stage 3 详情接口并发数
  static const int enrichConcurrency = 4;

  /// Stage 3 详情接口的**实际调用上限** —— 预筛后只对最有希望的 K 条调详情。
  ///
  /// ## 这是决定匹配速度的头号参数
  /// 详情接口是「每候选一次请求」，而全局限流只有 30 次/分钟。
  /// 候选池 30 条全部补详情 = 单首歌 30 次请求 + Stage 1 的 4 次搜索
  /// = 34 次 ≈ **68 秒/首**，导入 20 首就要等 20 分钟以上。
  /// 而最终只有 1 条胜出，其余请求全是浪费。
  ///
  /// 调小 → 更快（线性），代价是极端情况下可能把正确音源挡在详情之外。
  /// 取值参考：6 相当于把 30 条候选的详情请求压到 6 次（≈3× 提速）。
  static const int enrichTopKMin = 3;
  static const int enrichTopKMax = 6;

  /// 首批详情请求后，如果已经得到明显高置信度候选，可提前结束。
  static const double earlyAutoThreshold = 0.92;

  /// 最高精确分与“下一名预筛分”之间的最低安全间隔。
  static const double earlyStopGap = 0.10;

  /// Stage 3 每批详情请求数。与并发数保持一致，便于分批提前终止。
  static const int enrichBatchSize = enrichConcurrency;

  // ── Stage 1 候选召回 ──────────────────────────────────────

  /// 候选池上限（**召回**用，不直接等于网络开销）。
  ///
  /// 池子只做本地计算（硬过滤 + 预筛），成本可忽略；
  /// 真正发请求的数量由动态 TopK（[enrichTopKMin] ~ [enrichTopKMax]）控制。所以这里可以放宽 ——
  /// 池子越大，预筛能挑到的正确音源越不容易被漏掉。
  static const int maxCandidates = 60;

  /// 第一层只请求 Q1/Q2；若已有足够强的候选，则跳过 Q3/Q4。
  static const int minRecallCandidates = 12;

  /// 质量路查询后缀（设计文档 13.6 修正项 ①）
  static const String qualitySuffix = '无损';

  static const int searchPageSize = 20;

  /// 服务端时长分档：按歌曲时长反推。0=全部/1=<10分/2=10-30分/3=30-60分/4=>60分
  static int durationFilterFor(int durationMs) {
    final sec = durationMs ~/ 1000;
    if (sec <= 0) return 0;
    if (sec < 10 * 60) return 1;
    if (sec < 30 * 60) return 2;
    if (sec < 60 * 60) return 3;
    return 4;
  }

  // ── 文本黑名单（设计文档 4.4.1）──────────────────────────
  //
  // 只放语义上**确定是二次创作**的词。刻意排除「歌词」「动态歌词」
  // 这类可能是正规投稿的描述——设计文档 4.4.1 明确提醒过这个副作用。
  static const List<String> blockTitlePatterns = [
    // 翻唱与改编
    '翻唱', 'cover', '改版', '改编', '鬼畜', '鬼畜调教',
    '纯音乐', '钢琴版', '吉他版', '古筝版', '伴奏', 'instrumental',
    '卡拉OK', 'karaoke', 'remix', '混音', 'MIX',
    // 教学与解说
    '教学', '教程', '谱子', '简谱', '吉他谱', '如何弹', '教你弹',
    '解析', '解说', 'reaction', '听后感',
    // 剪辑与二次创作
    '剪辑', '混剪', '卡点', 'MV盘点', '合集', '串烧', '收音',
    '1小时', '循环版', '单曲循环', '洗脑循环', '精编',
    // 其它
    '原神', '语音包', '铃声', '彩铃',
  ];

  /// 黑名单词的小写副本（预计算，只算一次）。
  ///
  /// 硬过滤是「每候选 × 每词」的双重循环，原实现在循环体内对每个词重复
  /// `toLowerCase()`。词表是 const，小写副本在类加载时算一次即可；
  /// 诊断文案仍引用 [blockTitlePatterns] 的原始拼写（如「MIX」大写）。
  static final List<String> blockTitlePatternsLower =
      [for (final w in blockTitlePatterns) w.toLowerCase()];

  /// 营销词的小写副本（预计算，用途同 [blockTitlePatternsLower]）。
  static final List<String> marketingWordsLower =
      [for (final w in marketingWords) w.toLowerCase()];

  /// 音乐相关分区（加分）
  static const Set<String> musicPartitions = {
    '音乐', '音乐综合', 'MV', '原创音乐', '翻唱',
  };

  /// 明确低相关的分区（减分）
  static const Set<String> lowRelevancePartitions = {
    '鬼畜', '搞笑', '生活', '游戏', '科技', '知识',
  };

  /// 营销词堆砌（文本规范度扣分）
  static const List<String> marketingWords = [
    '必听', '神曲', '震惊', '史上最', '天花板', '封神',
  ];

  // ── 时长缺失的降级处理（设计文档 10.1）────────────────────
  //
  // 歌曲无时长时，时长维度给中性分，整体权重重新归一化，
  // 且置信度上限压到 REVIEW —— 不允许在缺关键证据时自动绑定。
  static const double durationNeutralScore = 0.5;

  /// 歌手字段为空时，标题维度权重从 0.30 提升到 0.45（权重转移）
  static const double wTitleWhenNoArtist = 0.45;
}
