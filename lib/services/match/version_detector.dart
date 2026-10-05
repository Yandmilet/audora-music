/// v0.4 版本检测：评分惩罚制（设计文档 §5 + v0.6 增量）。
///
/// ## 惩罚表（从高到低）
///   ┌───────┬─────────────────────────────────────────────────┐
///   │ 0.25  │ instrumental / 伴奏                           │
///   │ 0.20  │ cover / 翻唱 / remix / 8bit / chiptune         │
///   │ 0.15  │ acoustic / unplugged / 不插电版               │
///   │ 0.10  │ self cover / 自翻唱（原歌手自己唱自己，惩罚轻） │
///   │ 0.05  │ live / 现场（硬过滤不拦，罚一下做区分）        │
///   └───────┴─────────────────────────────────────────────────┘
///
/// 同一标题命中多类时取**最高档**而非累加
/// （「翻唱 remix」是同一件事的两种描述，累加会双倍惩罚）。
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

  // ── 英文词统一用 \b 词边界，避免误伤 Alive / Undercover / Discover 等歌名 ──
  // 中文词天然无空格分词问题，保持 contains 即可。
  // 注：输入在 penalty 里已把 [-_\s] 全替换成空格，\b 对空格边界正常工作。
  static final _reInstrumental = RegExp(r'\binstrumental\b', caseSensitive: false);
  static final _reCover = RegExp(r'\bcover\b', caseSensitive: false);
  static final _reRemix = RegExp(r'\bremix\b', caseSensitive: false);
  static final _reSelfCover = RegExp(r'\bself\s+cover\b', caseSensitive: false);
  static final _re8bit = RegExp(r'\b8bit\b', caseSensitive: false);
  static final _reChiptune = RegExp(r'\bchiptune\b', caseSensitive: false);
  static final _reAcoustic = RegExp(r'\bacoustic\b', caseSensitive: false);
  static final _reUnplugged = RegExp(r'\bunplugged\b', caseSensitive: false);
  static final _reLive = RegExp(r'\blive\b', caseSensitive: false);

  /// 版本惩罚。命中多个版本标签时取最高档（不累加）。
  static double penalty(String text) {
    // 归一化：把连字符/下划线统一成空格，兼容 "self-cover" / "self_cover" / "self cover"
    final v = text.toLowerCase().replaceAll(RegExp(r'[-_\s]+'), ' ');

    // ── 0.25：instrumental / 伴奏（最高档）────────────────
    if (_reInstrumental.hasMatch(v) || v.contains('伴奏')) return 0.25;

    // ── 0.20：cover / 翻唱 / remix / 芯片音乐 ─────────────
    // 注意：self cover 在前面先判掉，不会落到这里被普通 cover 误匹配
    if (_reSelfCover.hasMatch(v) || v.contains('自翻唱')) {
      return 0.10; // 原歌手自己唱自己，惩罚轻一档
    }
    if (_reCover.hasMatch(v) || v.contains('翻唱')) return 0.20;
    if (_reRemix.hasMatch(v)) return 0.20;
    if (_re8bit.hasMatch(v) || _reChiptune.hasMatch(v)) return 0.20;

    // ── 0.15：不插电版（acoustic/unplugged）──────────────
    if (_reAcoustic.hasMatch(v) || _reUnplugged.hasMatch(v) || v.contains('不插电')) {
      return 0.15;
    }

    // ── 0.05：live / 现场（硬过滤不拦，罚一下做区分）───────
    if (_reLive.hasMatch(v) || v.contains('现场')) return 0.05;

    return 0;
  }
}
