import 'dart:math';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme.dart';

/// 用渐变 + 几何图形生成封面（原型阶段不依赖网络图片）
class CoverArt extends StatelessWidget {
  final int seed;
  final double size;
  final double radius;

  const CoverArt({
    super.key,
    required this.seed,
    this.size = 52,
    this.radius = Tokens.rMd,
  });

  static const _palettes = <List<Color>>[
    [Color(0xFFE5484D), Color(0xFFF2708C)],
    [Color(0xFF6C5CE7), Color(0xFF9B8CFF)],
    [Color(0xFF0EA5A4), Color(0xFF5EEAD4)],
    [Color(0xFFF59E0B), Color(0xFFFCD34D)],
    [Color(0xFF2563EB), Color(0xFF60A5FA)],
    [Color(0xFFDB2777), Color(0xFFF472B6)],
    [Color(0xFF059669), Color(0xFF34D399)],
    [Color(0xFF7C3AED), Color(0xFFC084FC)],
    [Color(0xFFDC2626), Color(0xFFFB7185)],
    [Color(0xFF0891B2), Color(0xFF22D3EE)],
    [Color(0xFFEA580C), Color(0xFFFDBA74)],
    [Color(0xFF4F46E5), Color(0xFF818CF8)],
  ];

  @override
  Widget build(BuildContext context) {
    final p = _palettes[seed.abs() % _palettes.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p,
        ),
      ),
      child: CustomPaint(painter: _BubblePainter(seed)),
    );
  }
}

class _BubblePainter extends CustomPainter {
  final int seed;
  _BubblePainter(this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(seed);
    final p1 = Paint()..color = Colors.white.withValues(alpha: 0.13);
    final p2 = Paint()..color = Colors.white.withValues(alpha: 0.09);
    canvas.drawCircle(
      Offset(size.width * (0.6 + rnd.nextDouble() * 0.25), size.height * 0.28),
      size.width * 0.26, p1,
    );
    canvas.drawCircle(
      Offset(size.width * 0.24, size.height * (0.65 + rnd.nextDouble() * 0.2)),
      size.width * 0.19, p2,
    );
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) => old.seed != seed;
}

/// 音源状态徽章
class SourceBadge extends StatelessWidget {
  final SourceStatus status;
  final bool compact;

  const SourceBadge({super.key, required this.status, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (bg, ink, label) = switch (status) {
      SourceStatus.ok => (
          dark ? SemColor.okBgDark : SemColor.okBg,
          dark ? SemColor.okInkDark : SemColor.okInk,
          '已匹配',
        ),
      SourceStatus.pending => (
          dark ? SemColor.pendingBgDark : SemColor.pendingBg,
          dark ? SemColor.pendingInkDark : SemColor.pendingInk,
          '待确认',
        ),
      SourceStatus.none => (
          dark ? SemColor.noneBgDark : SemColor.noneBg,
          dark ? SemColor.noneInkDark : SemColor.noneInk,
          '无音源',
        ),
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Tokens.rFull),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 9.5 : 10.5,
          fontWeight: FontWeight.w700,
          color: ink,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 迷你播放条
class MiniPlayer extends StatelessWidget {
  final Song song;
  final bool playing;
  final double progress;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onNext;

  const MiniPlayer({
    super.key,
    required this.song,
    required this.playing,
    required this.progress,
    required this.onToggle,
    required this.onTap,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      decoration: BoxDecoration(
        color: dark ? Tokens.surfaceDark : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.rLg),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.4 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(Tokens.rLg),
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
                child: Row(
                  children: [
                    CoverArt(seed: song.coverSeed, size: 38, radius: Tokens.rSm),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: t.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggle,
                      icon: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 28,
                        color: Tokens.brand,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onNext,
                      icon: const Icon(Icons.skip_next_rounded, size: 24),
                    ),
                  ],
                ),
              ),
              // 细进度条
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 2.5,
                    backgroundColor: dark ? Tokens.lineDark : Tokens.line,
                    valueColor: const AlwaysStoppedAnimation(Tokens.brand),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 区块标题
class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;

  const SectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Text(
                    action!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 通用空状态。
///
/// ## 为什么必须统一走这一个组件而不是各页自己写
/// 「曲库为空」这个状态在首页 / 搜索 / 榜单 / 常听 / 收藏 五处都会出现。
/// 分散写的话，各处文案与「下一步该做什么」的指引会不一致——
/// 用户看到「空空如也」却不知道该去导入歌曲，就只能干瞪眼。
/// 统一组件保证每处都给出**同一个可操作的去处**。
///
/// [actionLabel] + [onAction] 必须成对传：空状态的价值不在于「告诉用户这里是空的」，
/// 而在于「告诉用户可以做什么」。
class EmptyState extends StatelessWidget {
  final IconData icon;

  /// 一句话主标题，如「曲库还没有歌」
  final String title;

  /// 补一行说明「为什么空 / 怎么解决」
  final String? message;

  /// 行动按钮文案（如「去导入歌曲」）。为 null 时只显示文案不显示按钮。
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 紧凑模式：用于嵌在小卡片里（榜单 / 常听），只显示一行图文
  final bool compact;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sub = t.colorScheme.onSurfaceVariant;
    final hasAction = actionLabel != null && onAction != null;

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(icon, size: 20, color: sub),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 12.5, color: sub),
              ),
            ),
            if (hasAction)
              GestureDetector(
                onTap: onAction,
                behavior: HitTestBehavior.opaque,
                child: Text(
                  actionLabel!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Tokens.brand,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // Center + SingleChildScrollView：空态可能出现在高度很小的容器里
    // （比如首页 tab 区、弹层内），Column 内容超出可用高度时会直接
    // RenderFlex overflow。可滚动让它自适应收缩——内容装得下时
    // 居中观感不变，装不下时可滚，不会红黄条纹报错。
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52, color: sub.withValues(alpha: 0.6)),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: sub, height: 1.6),
                ),
              ],
              if (hasAction) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(actionLabel!),
                  style: FilledButton.styleFrom(
                    backgroundColor: Tokens.brand,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 手势：右滑返回 + 一级双击退出
// ═══════════════════════════════════════════════════════════════

/// 用整页水平 pan 模拟边缘右滑返回手势。
///
/// ## 解决的具体问题
/// Flutter 默认只在 Android 系统手势区触发 Navigator.pop（屏幕左缘 18px）。
/// 用户要求"从屏幕中部右滑也能返回"——这里包一层 HorizontalDragRecognizer。
///
/// ## 触发条件（满足任一即触发）
/// 1. 滑动结束时**累计位移** ≥ [threshold]（适合慢滑的用户）
/// 2. 滑动结束时**水平速度** ≥ [velocityThreshold] px/s（适合快滑的用户）
///
/// ## 取舍
/// - **不**与 ScrollView 抢占：纵向滚动交给 ListView 自己的 GestureRecognizer，
///   Flutter 用 arena 自动仲裁；这里只用 `onHorizontalDragEnd` 读累计结果，
///   不抢 onUpdate 事件，纵向滚动不受影响。
/// - **只接向右滑**：向左忽略（避免与潜在左侧抽屉打架）。
/// - **不影响 Navigator 默认 pop**：用户在左缘 18px 处右滑仍走系统手势（先到）；
///   这里处理的是中部右滑的补充路径。
class SwipeBack extends StatefulWidget {
  /// 触发阈值（逻辑像素）。向右滑超过这个距离调用 [onBack]。
  final double threshold;

  /// 速度阈值（逻辑像素/秒）。快速右滑到这个速度也算触发。
  final double velocityThreshold;

  final VoidCallback onBack;
  final Widget child;

  /// false 时完全不注册手势识别器。
  ///
  /// ## 为什么需要门控而不是在回调里判空
  /// 播放页/搜索页打开时，Shell 的 [ExitConfirm]（退出确认）仍在手势
  /// 竞技场里。虽然子层 SwipeBack 通常会赢，但只要父层还参与竞技，
  /// 「播放页右滑 → 误触发退出」这类边界就始终存在。直接不注册，
  /// 竞技场里只剩子层，行为完全确定。
  final bool enabled;

  const SwipeBack({
    super.key,
    required this.onBack,
    required this.child,
    this.threshold = 80,
    this.velocityThreshold = 300,
    this.enabled = true,
  });

  @override
  State<SwipeBack> createState() => _SwipeBackState();
}

class _SwipeBackState extends State<SwipeBack> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _dx = 0,
      onHorizontalDragUpdate: (d) => _dx += d.primaryDelta ?? 0,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        // 只接向右滑（位移 > 0 且速度 > 0）
        if ((v >= widget.velocityThreshold) || _dx >= widget.threshold) {
          widget.onBack();
        }
        _dx = 0;
      },
      child: widget.child,
    );
  }
}

/// 一级主界面的"再次右滑退出"二次确认。
///
/// ## 用法
/// 包住 [Shell] 的整个 body。第一次右滑不退出，只提示；
/// 在 [window] 内再次右滑才真正退出。
///
/// ## 为什么是状态对象而不是纯回调
/// 状态保留"上次触发时间"，跨两次构建仍有效。StatefulWidget 才能做到。
/// 切到 Plan 模式时不需要它——只在一级主界面用。
class ExitConfirm extends StatefulWidget {
  /// 第一次右滑触发的回调（一般是弹 SnackBar/Toast 提示）
  final VoidCallback onFirstTrigger;

  /// 第二次右滑触发的回调（一般是 SystemNavigator.pop）
  final VoidCallback onConfirmExit;

  /// 二次确认的时间窗
  final Duration window;

  /// false 时本层完全不参与手势（子树原样透传）。
  /// 播放页/搜索页打开时必须关闭——那两层的右滑归各自的 SwipeBack 管。
  final bool enabled;

  final Widget child;

  const ExitConfirm({
    super.key,
    required this.onFirstTrigger,
    required this.onConfirmExit,
    required this.child,
    this.window = const Duration(seconds: 2),
    this.enabled = true,
  });

  @override
  State<ExitConfirm> createState() => _ExitConfirmState();
}

class _ExitConfirmState extends State<ExitConfirm> {
  DateTime? _lastTrigger;

  void _trigger() {
    final now = DateTime.now();
    if (_lastTrigger != null &&
        now.difference(_lastTrigger!) <= widget.window) {
      _lastTrigger = null;
      widget.onConfirmExit();
    } else {
      _lastTrigger = now;
      widget.onFirstTrigger();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      threshold: 60,
      enabled: widget.enabled,
      onBack: _trigger,
      child: widget.child,
    );
  }
}
