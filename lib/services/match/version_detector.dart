/// v0.4 版本检测：惩罚制 + P0-1 升级为分类器。
///
/// ## 历史：惩罚制 → 分类器
/// v0.4 时只有 penalty()：命中版本标签 → 扣分。但"扣分"不足以表达
/// 更深层的矛盾：一首 Studio 专辑的目标，撞上 B 站标题明确写着 Cover /
/// Instrumental，即使时长对了，也**不是同一个录音**。单纯扣 0.25 无法
/// 与"Live 版本"这种弱变体区分开。
///
/// v0.8（P0-4）新增 classify()：输出结构化的版本分类结果，让调用方
/// 自己决定如何使用（矛盾检测 / 版本一致加分 / 过滤决策）。
/// penalty() 保持向后兼容，内部复用 classify 结果。
///
/// ## 惩罚表（从高到低，penalty() 仍按此返回）
///   ┌───────┬─────────────────────────────────────────────────┐
///   │ 0.25  │ instrumental / 伴奏                           │
///   │ 0.20  │ cover / 翻唱 / remix / 8bit / chiptune         │
///   │ 0.15  │ acoustic / unplugged / 不插电版               │
///   │ 0.10  │ self cover / 自翻唱                           │
///   │ 0.05  │ live / 现场                                   │
///   └───────┴─────────────────────────────────────────────────┘
library;

/// P0-4：版本分类结果。
///
/// 用 type 描述 B 站音频的版本身份，用 confidence 描述检测置信度。
/// 调用方（MatchScorer）据此判断与 QQ 元数据的版本是否矛盾。
class VersionResult {
  final VersionType type;
  final double confidence; // 0~1，越高越确信

  const VersionResult({required this.type, required this.confidence});

  bool get isLive => type == VersionType.live;
  bool get isCover =>
      type == VersionType.cover || type == VersionType.selfCover;
  bool get isSecondary =>
      type != VersionType.studio && type != VersionType.unknown;
}

enum VersionType {
  studio, // 标准录音版本（默认，无版本标签）
  live, // 现场版
  cover, // 翻唱（他人唱原歌）
  selfCover, // 自翻唱（原歌手自己重唱）
  instrumental, // 伴奏
  remix, // remix / 混音
  acoustic, // 不插电
  chiptune, // 8bit / chiptune
  unknown, // 检测不到任何版本信号
}

class VersionDetector {
  VersionDetector._();

  // ── 英文词统一用 \b 词边界，避免误伤 Alive / Undercover / Discover 等歌名 ──
  static final _reInstrumental = RegExp(r'\binstrumental\b', caseSensitive: false);
  static final _reCover = RegExp(r'\bcover\b', caseSensitive: false);
  static final _reRemix = RegExp(r'\bremix\b', caseSensitive: false);
  static final _reSelfCover = RegExp(r'\bself\s+cover\b', caseSensitive: false);
  static final _re8bit = RegExp(r'\b8bit\b', caseSensitive: false);
  static final _reChiptune = RegExp(r'\bchiptune\b', caseSensitive: false);
  static final _reAcoustic = RegExp(r'\bacoustic\b', caseSensitive: false);
  static final _reUnplugged = RegExp(r'\bunplugged\b', caseSensitive: false);
  static final _reLive = RegExp(r'\blive\b', caseSensitive: false);

  /// P0-4：版本分类。比 penalty() 更细粒度——返回结构化类型而不是扣分数值。
  ///
  /// 命中多类时取最"强"的类型（同 penalty 的优先级：instrumental > cover >
  /// remix > acoustic > selfCover > live），而不是返回多个。
  static VersionResult classify(String text) {
    final v = text.toLowerCase().replaceAll(RegExp(r'[-_\s]+'), ' ');

    // ── instrumental / 伴奏（最强信号，伴奏几乎不可能与 Studio 同录）
    if (_reInstrumental.hasMatch(v) || v.contains('伴奏')) {
      return const VersionResult(type: VersionType.instrumental, confidence: 0.95);
    }

    // ── cover 类：self cover 优先
    if (_reSelfCover.hasMatch(v) || v.contains('自翻唱')) {
      return const VersionResult(type: VersionType.selfCover, confidence: 0.85);
    }
    if (_reCover.hasMatch(v) || v.contains('翻唱')) {
      return const VersionResult(type: VersionType.cover, confidence: 0.90);
    }

    // ── remix
    if (_reRemix.hasMatch(v)) {
      return const VersionResult(type: VersionType.remix, confidence: 0.90);
    }

    // ── chipbone / 8bit
    if (_re8bit.hasMatch(v) || _reChiptune.hasMatch(v)) {
      return const VersionResult(type: VersionType.chiptune, confidence: 0.85);
    }

    // ── acoustic / unplugged
    if (_reAcoustic.hasMatch(v) ||
        _reUnplugged.hasMatch(v) ||
        v.contains('不插电')) {
      return const VersionResult(type: VersionType.acoustic, confidence: 0.85);
    }

    // ── live / 现场
    if (_reLive.hasMatch(v) || v.contains('现场')) {
      return const VersionResult(type: VersionType.live, confidence: 0.80);
    }

    // 无版本标签 → 视为 studio（不能确定但最常见的默认值）
    return const VersionResult(type: VersionType.studio, confidence: 0.55);
  }

  /// 版本惩罚。命中多个版本标签时取最高档（不累加）。
  ///
  /// P0-4：内部复用 classify() 结果，保持向后兼容——测试不依赖返回值细节。
  static double penalty(String text) {
    final result = classify(text);
    return switch (result.type) {
      VersionType.instrumental => 0.25,
      VersionType.cover || VersionType.chiptune || VersionType.remix => 0.20,
      VersionType.acoustic => 0.15,
      VersionType.selfCover => 0.10,
      VersionType.live => 0.05,
      _ => 0.0,
    };
  }
}
