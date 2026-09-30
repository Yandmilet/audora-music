/// v0.4 版本检测：评分惩罚制（设计文档 §5）。
///
/// ## 与 Stage 2 硬过滤的关系（重要）
/// 硬过滤词表（`MatchConfig.blockTitlePatterns`）已拦截 翻唱/伴奏/instrumental/
/// remix/混音 等确定二次创作，本类是 **Stage 4 的兜底网**，职责边界：
///   1. 兜住硬过滤漏网的变体写法；
///   2. 覆盖硬过滤**刻意不拦**的词（live/现场 罚 0.05 不杀——正版 Live
///      专辑投稿是高频正例，直接过滤会误杀，设计文档 §13「正版 Live /
///      Audio 不再误过滤」）。
/// 不把硬过滤词移到惩罚制的理由：那会让大量翻唱候选涌入 Stage 3 详情
/// 请求，在 30 次/分钟限流下挤兑配额（-412 风控），红线不让步。
///
/// 惩罚应用点：`MatchScorer.score` 尾部 `total = base - penalty`，
/// 并落 `score_detail.penalty` 供调参回溯。
class VersionDetector {
  VersionDetector._();

  /// 版本惩罚。同一标题命中多类时取**最高档**而非累加
  /// （「翻唱 remix」是同一件事的两种描述，累加会双倍惩罚）。
  static double penalty(String text) {
    final value = text.toLowerCase();

    if (value.contains('instrumental') || value.contains('伴奏')) {
      return 0.25;
    }

    if (value.contains('cover') || value.contains('翻唱')) {
      return 0.20;
    }

    if (value.contains('remix')) {
      return 0.20;
    }

    if (value.contains('live') || value.contains('现场')) {
      return 0.05;
    }

    return 0;
  }
}
