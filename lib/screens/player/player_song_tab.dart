/// 播放页「歌曲」tab：黑胶封面 + 进度 + 分段切换。
///
/// 从 player_screen.dart 拆出（P3 结构整理，纯代码搬运）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/qqmusic/qqmusic_catalog_dto.dart'
    show AlbumBrief;
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../browse_screen.dart' show BrowseScreen;

class SongTab extends StatelessWidget {
  final AppState st;
  final Song song;
  final AnimationController spin;

  const SongTab({super.key, required this.st, required this.song, required this.spin});

  // 唱片几何：胶片 240 / 封面 172（≈72%，外圈环宽 34px）。调整轨迹：
  // 208/100 → 208/120 → 208/150（用户逐轮反馈封面偏小）→ **240/172 整体放大**
  // （封面单独加大会把胶片挤成「CD 模式」，环宽必须随之恢复）。改封面直径
  // 必须同步 _GroovePainter 的起始半径（已引用 _coverSize 自动跟随）。
  static const double _discSize = 240;
  static const double _coverSize = 172;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // SegTabs 已上提至 _PlayerScreenState 顶层，这里只放唱片。
        const Spacer(),
        // 黑胶唱片：封面作为「盘芯」放进旋转体内部，与胶片一起随播放
        // 缓慢自转（播放中 repeat，暂停时 AnimationController.stop 保持角度）。
        SizedBox(
          width: _discSize,
          height: _discSize,
          child: RotationTransition(
            turns: spin,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 胶片本体
                Container(
                  width: _discSize,
                  height: _discSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: [Color(0xFF2A2E36), Color(0xFF14171C)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.32),
                        blurRadius: 34,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: CustomPaint(
                    painter: _GroovePainter(startRadius: _coverSize / 2 + 5),
                  ),
                ),
                // 圆形封面（盘芯，随盘旋转）：QQ 音乐真实专辑图；
                // 点击进入当前歌曲所在专辑的歌曲列表
                _VinylCover(
                  song: song,
                  size: _coverSize,
                  onTap: () {
                    final albumMid = song.albumMid;
                    if (albumMid == null || albumMid.isEmpty) return;
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => BrowseScreen.album(
                        st,
                        AlbumBrief(
                          mid: albumMid,
                          name: song.album.isNotEmpty ? song.album : '专辑',
                          cover: song.coverUrl ?? '',
                          singerName: song.artist,
                          releaseDate: '',
                          totalNum: 0,
                        ),
                      ),
                    ));
                  },
                ),
                // 中心轴孔：纯装饰；圆形对称，转不转视觉一致
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF14171C),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }
}

/// 唱片盘芯封面：优先 QQ 音乐真实专辑图（`y.gtimg.cn` CDN，由
/// `Song.coverUrl` 拼装自 album_mid）；无 URL / 加载中 / 加载失败时
/// 露出底层 [CoverArt] 占位渐变——盘芯任何情况下都不出现空白。
///
/// 可点击进入当前歌曲所在专辑的歌曲列表（由外层 [SongTab] 传入 [onTap]）。
class _VinylCover extends StatelessWidget {
  final Song song;
  final double size;
  final VoidCallback? onTap;

  const _VinylCover({required this.song, required this.size, this.onTap});

  @override
  Widget build(BuildContext context) {
    final url = song.coverUrl;
    Widget child = SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 回退层：始终铺底，网络图加载中/失败时它就是可见内容
          CoverArt(seed: song.coverSeed, size: size, radius: size / 2),
          if (url != null)
            ClipOval(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                // 失败画透明，露出底层渐变（不在 errorWidget 里重复画）
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
                // 加载中画透明露出渐变，下载完成后淡入图片；
                // 默认 fadeInDuration 500ms 已能柔化从占位到图片的切换。
                placeholder: (_, __) => const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
    if (onTap != null) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      );
    }
    return child;
  }
}

/// 唱片纹路：从盘芯（封面）外缘留 5px 缝隙开始，向外画一圈圈细环。
class _GroovePainter extends CustomPainter {
  /// 纹路起始半径 = 封面半径 + 5，避免 groove 压在封面上。
  final double startRadius;

  _GroovePainter({required this.startRadius});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.045);
    for (var r = startRadius; r < size.width / 2 - 6; r += 7) {
      canvas.drawCircle(c, r, p);
    }
  }

  @override
  bool shouldRepaint(covariant _GroovePainter old) =>
      old.startRadius != startRadius;
}

/// 歌曲 / 歌词 的分段切换器（顶部固定，跨页不变）。
///
/// ## 双源：PageController + AppState.playerTab
/// 滑动跟随由 [PageController.position] 计算偏移量；点击切换则由
/// [AppState.playerTab] 触发 jumpToPage。两路都不会循环——
/// onPageChanged 在程序化 jumpToPage 时不触发（见 Flutter 文档）。
class SegTabs extends StatefulWidget {
  final AppState st;
  final PageController page;
  const SegTabs({super.key, required this.st, required this.page});

  @override
  State<SegTabs> createState() => _SegTabsState();
}

class _SegTabsState extends State<SegTabs> {
  /// 当前 PageView 的滚动位置（0..1，歌词页 = 1）。
  /// 由 PageController 监听提供，用于让指示器跟手滑动而不是瞬切。
  double _pagePos = 0;

  @override
  void initState() {
    super.initState();
    widget.page.addListener(_onPageScroll);
    _pagePos = widget.page.initialPage.toDouble();
  }

  @override
  void dispose() {
    widget.page.removeListener(_onPageScroll);
    super.dispose();
  }

  void _onPageScroll() {
    if (!mounted || !widget.page.hasClients) return;
    final p = widget.page.page;
    if (p == null) return;
    // 只重建处于动画区间的值（0..1 之外是 over-scroll，置回边界）
    final clamped = p.clamp(0.0, 1.0);
    if (clamped == _pagePos) return;
    setState(() => _pagePos = clamped);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 双项等宽时容器宽度 = 两个胶囊 + gap。这里给容器一个固定宽度，
    // 让指示器位置能按比例算偏移。
    const double itemW = 60; // 与下方 padding(22) + Text 一行的视觉宽度匹配
    const double gap = 6;
    const double totalW = itemW * 2 + gap;

    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: dark ? Tokens.surface2Dark : Tokens.surface2,
        borderRadius: BorderRadius.circular(Tokens.rFull),
      ),
      child: SizedBox(
        width: totalW + 16, // 容器内左右各 8px 留白，整体看起来更舒展
        height: 32,
        child: Stack(
          children: [
            // 滑动的指示器。位置按 _pagePos (0..1) 在两个 item 间过渡。
            AnimatedPositioned(
              duration: Tokens.durFast,
              curve: Curves.easeOutCubic,
              left: 8 + _pagePos * (itemW + gap),
              top: 0,
              bottom: 0,
              width: itemW,
              child: Container(
                decoration: BoxDecoration(
                  color: dark ? Tokens.surfaceDark : Tokens.surface,
                  borderRadius: BorderRadius.circular(Tokens.rFull),
                ),
              ),
            ),
            // 两个 label
            Row(
              children: [
                _segLabel(0, '歌曲', totalW),
                _segLabel(1, '歌词', totalW),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _segLabel(int i, String label, double totalW) {
    final active = widget.st.playerTab == i;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (widget.st.playerTab == i) return;
          widget.st.setPlayerTab(i);
          widget.page.jumpToPage(i);
        },
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
