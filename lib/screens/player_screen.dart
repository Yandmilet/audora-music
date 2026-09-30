import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../data/db/rows.dart';
import '../models/models.dart';
import '../services/bilibili/bili_dto.dart' show VideoCandidate;
import '../services/fx/audio_fx_service.dart';
import '../services/fx/fx_preset.dart';
import '../services/lyric/lrc_parser.dart';
import '../services/match/match_config.dart' show MatchConfidenceX;
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// SnackBar 驻留时长：固定短提示 1.5s / 操作结果 2s。
///
/// ## 为什么是这个值
/// 中文提示 10~20 字，按 5~7 字/秒的阅读速度加反应时间，1.5~2s 足够读完；
/// 此前散落的 2~3s（全局 toast 甚至 5s）用户反馈驻留过长。带「建议操作」
/// 的引导文案（如「试试手动搜索音源」）也归结果类 2s。调参改这里，勿再散写。
const Duration _kSnackHint = Duration(milliseconds: 1500);
const Duration _kSnackResult = Duration(seconds: 2);

/// 播放页（全屏上滑）
class PlayerScreen extends StatefulWidget {
  final AppState st;
  const PlayerScreen({super.key, required this.st});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  /// 唱片自转周期。20s/圈 ≈ 3 RPM：真实黑胶 33⅓ RPM 太快，纯装饰旋转
  /// 用 12s 会显得急促，20s 才有「缓慢自转」的观感。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );

  /// 歌曲 / 歌词两页的翻页控制器。
  ///
  /// ## 为什么必须手动同步 [AppState.playerTab]
  /// 顶部 _SegTabs 是 PageView 的指示器：点它要切页，滑页也要更新指示器。
  /// 真实状态在 [AppState.playerTab]（决定音源/音量等是否在歌词页禁用），
  /// 这里双向同步：AppState → PageController；PageView.onPageChanged → AppState。
  late final PageController _page =
      PageController(initialPage: widget.st.playerTab);

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_onState);
    _syncSpin();
    _syncPageFromState();
  }

  void _onState() {
    _syncSpin();
    _syncPageFromState();
  }

  /// 当外部（setPlayerTab 切换 / 初始值变化）改了 playerTab 而 PageView
  /// 没跟上时，把页面滑到对应位置。
  ///
  /// 用 `_page.hasClients` 防止 build 之前 PageController 还未 attach。
  /// 用 `jumpToPage`（而非 animateToPage）避免与用户正在滑动的手势打架。
  void _syncPageFromState() {
    if (!mounted || !_page.hasClients) return;
    final target = widget.st.playerTab;
    if (_page.page?.round() == target) return;
    _page.jumpToPage(target);
  }

  void _syncSpin() {
    if (!mounted) return;
    if (widget.st.playing && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.st.playing && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    widget.st.removeListener(_onState);
    _spin.dispose();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final song = st.current;
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    if (song == null) {
      return const Scaffold(body: Center(child: Text('无播放内容')));
    }

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(st: st, song: song),
            if (st.playbackError != null) _ErrorBanner(st: st),
            // SegTabs 提到 PageView 之上：用户切页时它不动，比各 tab 自带一份
            // 切换瞬间"消失又出现"更接近 iOS 音乐 app 的体感。
            _SegTabs(st: st, page: _page),
            Expanded(
              child: PageView(
                controller: _page,
                physics: const BouncingScrollPhysics(),
                // onPageChanged 是「用户滑完松手」触发的；点 SegTabs 是程序化
                // 跳页（jumpToPage），不会触发它——所以双向同步都不会循环。
                onPageChanged: (i) {
                  if (widget.st.playerTab != i) {
                    widget.st.setPlayerTab(i);
                  }
                },
                children: [
                  _SongTab(st: st, song: song, spin: _spin),
                  _LyricTab(st: st),
                ],
              ),
            ),
            _ProgressBar(st: st),
            _Controls(st: st),
            _FootActions(st: st),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );
  }
}

/// 播放失败提示条。
///
/// 用内联横幅而非 SnackBar：播放错误（音源失效、网络不通）是**持续状态**
/// 而不是一次性事件——用户需要它在界面上留着，直到自己重新匹配成功。
/// SnackBar 几秒就消失，用户回头再看时已经不知道刚才发生了什么。
class _ErrorBanner extends StatelessWidget {
  final AppState st;
  const _ErrorBanner({required this.st});

  @override
  Widget build(BuildContext context) {
    // SemColor 有明暗两套值，必须按当前主题取，
    // 否则深色模式下会是浅底浅字（几乎看不见）。
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? SemColor.pendingBgDark : SemColor.pendingBg;
    final ink = dark ? SemColor.pendingInkDark : SemColor.pendingInk;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Tokens.rMd),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              st.playbackError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: ink,
            onPressed: st.clearPlaybackError,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final AppState st;
  final Song song;
  const _TopBar({required this.st, required this.song});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: st.closePlayer,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 1),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // 右上角原有一个「音源详情」info 按钮，与底部「音源」打开的是
          // 同一个面板——两个入口只让用户困惑，删掉；这里留一个等宽占位，
          // 否则标题会向左偏出中线。
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _SongTab extends StatelessWidget {
  final AppState st;
  final Song song;
  final AnimationController spin;

  const _SongTab({required this.st, required this.song, required this.spin});

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
                // 圆形封面（盘芯，随盘旋转）：QQ 音乐真实专辑图
                _VinylCover(song: song, size: _coverSize),
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
class _VinylCover extends StatelessWidget {
  final Song song;
  final double size;

  const _VinylCover({required this.song, required this.size});

  @override
  Widget build(BuildContext context) {
    final url = song.coverUrl;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 回退层：始终铺底，网络图加载中/失败时它就是可见内容
          CoverArt(seed: song.coverSeed, size: size, radius: size / 2),
          if (url != null)
            ClipOval(
              child: Image.network(
                url,
                fit: BoxFit.cover,
                // 失败画透明，露出底层渐变（不在 errorBuilder 里重复画）
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                // 加载中同样露出渐变，完成后再淡入图片（progress == null
                // 表示加载完成，此时才放行真正的图片帧）
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
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
class _SegTabs extends StatefulWidget {
  final AppState st;
  final PageController page;
  const _SegTabs({required this.st, required this.page});

  @override
  State<_SegTabs> createState() => _SegTabsState();
}

class _SegTabsState extends State<_SegTabs> {
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

/// 歌词页：真实 LRC 歌词 + 按播放进度自动滚动。
///
/// ## 三种状态各有对应界面
/// 1. 加载中 → 转圈（避免"暂无歌词"闪一下又变成有词）
/// 2. 无歌词（纯音乐 / 未匹配元数据 / 解析失败）→ 明确的空状态文案
/// 3. 有歌词 → 列表 + 自动居中当前行
///
/// 之前这里是**写死的《起风了》8 行词**，播任何歌都显示它——
/// 比显示"暂无歌词"更有误导性，用户会以为歌词滚动错位。已彻底移除。
class _LyricTab extends StatefulWidget {
  final AppState st;
  const _LyricTab({required this.st});

  @override
  State<_LyricTab> createState() => _LyricTabState();
}

class _LyricTabState extends State<_LyricTab> {
  final _scroll = ScrollController();

  /// 每行的固定高度（含 padding）。
  ///
  /// ⚠️ 自动滚动必须用**固定行高**来算目标偏移。如果用 `animateTo` 配合
  /// 变高 item 的 index，Flutter 需要先布局完所有项才知道偏移，
  /// 而歌词是一行长短不一的文本——算出来的位置会偏，且随字体缩放漂移。
  /// 固定行高牺牲了一点排版自由度，换来稳定的滚动定位。
  ///
  /// 有译文时整份歌词统一加高（不能逐行变高，否则 `i × 行高`
  /// 这个定位公式在第 i 行之后就全错了）。
  static const _lineHeightPlain = 52.0;

  /// 有译文时的行高：原文一行（约 27）+ 译文最多两行（约 36）+ 间距。
  /// 取 88 是为了给「原文也不短、译文也长」的情况留够空间——
  /// 固定行高的列表一旦算小了就是相邻行叠字，比行距松一点难看得多。
  static const _lineHeightWithTrans = 88.0;

  double get _lineHeight =>
      widget.st.lyric.hasTranslation ? _lineHeightWithTrans : _lineHeightPlain;

  /// 已滚动的目标行，避免同一行反复触发动画
  int _scrolledTo = -1;

  /// ListView 上下留白（让当前行能滚到视口中线的补偿空间）。
  /// 定位计算（[_onState]）与列表内边距（build）必须用同一来源，
  /// 否则算出的偏移和真实布局对不上。
  double get _edgePad => MediaQuery.of(context).size.height * 0.3;

  /// 上次定位时的歌词对象。首次加载 / 切歌后是新实例，
  /// 此时的第一次定位用 jumpTo 瞬移，而不是从旧位置滑过去。
  ParsedLyric? _lastLyric;

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_onState);
  }

  @override
  void dispose() {
    widget.st.removeListener(_onState);
    _scroll.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    if (widget.st.lyrics.isEmpty) return;

    // 换了歌词对象（首次加载 / 切歌）→ 重置定位基准
    if (!identical(widget.st.lyric, _lastLyric)) {
      _lastLyric = widget.st.lyric;
      _scrolledTo = -1;
    }

    final active = widget.st.lyricLine;
    if (active == _scrolledTo || !_scroll.hasClients) return;

    // 首次定位标记（置 _scrolledTo 之前取）
    final firstLocate = _scrolledTo == -1;
    _scrolledTo = active;

    final viewport = _scroll.position.viewportDimension;
    // ★ 目标偏移必须包含 ListView 的上内边距（_edgePad = 0.3 屏高）：
    // item 的内容坐标 = topPad + i * 行高。漏掉 topPad 会让当前行
    // 停在视口底部而不是垂直居中（真机实测问题）。
    final target = _edgePad +
        (active * _lineHeight) -
        (viewport / 2) +
        (_lineHeight / 2);
    final max = _scroll.position.maxScrollExtent;
    final offset = target.clamp(0.0, max);

    if (firstLocate) {
      // 刚打开歌词页 / 刚切歌：瞬移到位，避免「从顶部滚下来」的错觉
      _scroll.jumpTo(offset);
    } else {
      _scroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = widget.st;
    final lines = st.lyrics;

    return Column(
      children: [
        // SegTabs 已上提至 _PlayerScreenState 顶层
        Expanded(
          child: Builder(
            builder: (c) {
              if (st.lyricLoading && lines.isEmpty) {
                return const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (lines.isEmpty) {
                return _EmptyLyric(t: t, instrumental: st.lyric.instrumental);
              }
              return _buildList(t, st, lines);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildList(ThemeData t, AppState st, List<LyricLine> lines) {
    // 当前行下标：-1 表示还在前奏（未到第一句词的时间）
    final active = st.lyric.indexAt(Duration(seconds: st.position));

    return ListView.builder(
      controller: _scroll,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: 34,
        // 上下留出空白，当前行才能滚到中间（与 _onState 的定位计算同源）
        vertical: _edgePad,
      ),
      itemCount: lines.length,
      itemExtent: _lineHeight,
      itemBuilder: (c, i) {
        final on = i == active;
        final near = active >= 0 && (i - active).abs() == 1;
        return GestureDetector(
          // 点歌词行跳到该行时间：找歌词时比拖进度条精确得多
          onTap: () {
            final total = st.duration;
            if (total <= 0) return;
            final sec = lines[i].time.inSeconds;
            st.seekTo((sec / total).clamp(0.0, 1.0));
          },
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: Tokens.durFast,
                  style: TextStyle(
                    fontSize: on ? 18 : 15,
                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                    height: 1.5,
                    color: on
                        ? Tokens.brand
                        : t.colorScheme.onSurfaceVariant
                            .withValues(alpha: near ? 0.75 : 0.42),
                  ),
                  textAlign: TextAlign.center,
                  child: Text(lines[i].text, textAlign: TextAlign.center),
                ),
                // 译文只在非华语歌上出现（有译文的行高已整体加高）
                if (lines[i].translation != null) ...[
                  const SizedBox(height: 3),
                  AnimatedDefaultTextStyle(
                    duration: Tokens.durFast,
                    style: TextStyle(
                      fontSize: on ? 13.5 : 12,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      height: 1.35,
                      color: on
                          ? Tokens.brand.withValues(alpha: 0.82)
                          : t.colorScheme.onSurfaceVariant
                              .withValues(alpha: near ? 0.58 : 0.3),
                    ),
                    textAlign: TextAlign.center,
                    child: Text(
                      lines[i].translation!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 无歌词时的空状态
class _EmptyLyric extends StatelessWidget {
  final ThemeData t;
  final bool instrumental;
  const _EmptyLyric({required this.t, required this.instrumental});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            instrumental
                ? Icons.music_note_rounded
                : Icons.lyrics_outlined,
            size: 40,
            color: t.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            instrumental ? '纯音乐，请欣赏' : '暂无歌词',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          if (!instrumental) ...[
            const SizedBox(height: 5),
            Text(
              '歌词来自 QQ音乐，未收录的曲目无法显示',
              style: TextStyle(
                fontSize: 11,
                color: t.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final AppState st;
  const _ProgressBar({required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 4),
      child: Row(
        children: [
          Text(
            st.position.mmss,
            style: TextStyle(
              fontSize: 11,
              color: t.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (c, box) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => st.seekTo(d.localPosition.dx / box.maxWidth),
                onHorizontalDragUpdate: (d) =>
                    st.seekTo(d.localPosition.dx / box.maxWidth),
                child: SizedBox(
                  height: 22,
                  child: Center(
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 3.5,
                          decoration: BoxDecoration(
                            color: dark ? Tokens.lineDark : Tokens.line,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: st.progress,
                          child: Container(
                            height: 3.5,
                            decoration: BoxDecoration(
                              color: Tokens.brand,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment(st.progress * 2 - 1, 0),
                          child: Container(
                            width: 11,
                            height: 11,
                            decoration: const BoxDecoration(
                              color: Tokens.brand,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.black26, blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            st.duration.mmss,
            style: TextStyle(
              fontSize: 11,
              color: t.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  final AppState st;
  const _Controls({required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 8, 26, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 播放模式
          IconButton(
            onPressed: st.cycleMode,
            icon: Icon(
              switch (st.mode) {
                PlayMode.sequential => Icons.repeat_rounded,
                PlayMode.shuffle => Icons.shuffle_rounded,
                PlayMode.repeatOne => Icons.repeat_one_rounded,
              },
              size: 22,
              color: st.mode == PlayMode.sequential
                  ? t.colorScheme.onSurfaceVariant
                  : Tokens.brand,
            ),
          ),
          IconButton(
            onPressed: st.previous,
            icon: const Icon(Icons.skip_previous_rounded, size: 36),
          ),
          // 主按钮
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Tokens.brand.withValues(alpha: 0.34),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Tokens.brand,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: st.togglePlay,
                child: SizedBox(
                  width: 64,
                  height: 64,
                  // 拉流中显示转圈：B站拉流要几百毫秒，没有反馈的话
                  // 用户会以为"点了没反应"而反复点
                  child: st.resolvingSource
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          st.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: st.next,
            icon: const Icon(Icons.skip_next_rounded, size: 36),
          ),
          // 收藏
          IconButton(
            onPressed: () => st.toggleLike(st.current!),
            icon: Icon(
              st.isLiked(st.current!) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 22,
              color: st.isLiked(st.current!)
                  ? Tokens.brand
                  : t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FootActions extends StatelessWidget {
  final AppState st;
  const _FootActions({required this.st});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          _FootBtn(
            icon: Icons.queue_music_rounded,
            label: '播放队列',
            onTap: () => _showQueueSheet(context, st),
          ),
          _FootBtn(
            // 闹钟图标：避免与深色模式月亮图标语义重复
            icon: Icons.alarm_outlined,
            label: st.sleepTimer == null
                ? '定时关闭'
                : '${st.sleepTimer!.inMinutes} 分钟',
            active: st.sleepTimer != null,
            onTap: () => _showTimerSheet(context, st),
          ),
          // 音效按钮的 active 态（EQ 非平直 / 响度非 0）由 FX 服务驱动：
          // 服务是 ChangeNotifier，面板里改参数后按钮即时点亮/熄灭。
          ListenableBuilder(
            listenable: AudioFxService.instance,
            builder: (c, _) => _FootBtn(
              icon: Icons.graphic_eq_rounded,
              label: '音效',
              active: AudioFxService.instance.isFxActive,
              onTap: () => _showFxSheet(context, st),
            ),
          ),
          _FootBtn(
            icon: Icons.cloud_download_outlined,
            label: '音源',
            onTap: () => _showSourceSheet(context, st, st.current!),
            accent: st.current?.sourceStatus != SourceStatus.ok,
          ),
        ],
      ),
    );
  }
}

class _FootBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool accent;

  const _FootBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = accent
        ? SemColor.pendingInk
        : (active ? Tokens.brand : t.colorScheme.onSurfaceVariant);

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tokens.rMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============ 底部弹窗 ============

void _sheet(BuildContext context, Widget child) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  showModalBottomSheet(
    context: context,
    backgroundColor: dark ? Tokens.surfaceDark : Tokens.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.rXl)),
    ),
    isScrollControlled: true,
    // ⚠️ 必须吃掉键盘高度（viewInsets.bottom）：否则输入法弹出时
    // 底部弹层不动，TextField 被键盘整个盖住（真机实测问题）。
    // isScrollControlled 让弹层可以撑到全屏高，加上这个内边距后
    // 键盘弹出时内容自动上移。
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: child,
    ),
  );
}

Widget _sheetHeader(String title, String sub, BuildContext ctx) {
  final t = Theme.of(ctx);
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                sub,
                style: TextStyle(fontSize: 11.5, color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

void _showQueueSheet(BuildContext context, AppState st) {
  _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            _sheetHeader(
              '播放队列',
              '${st.mode.label} · ${st.queue.length} 首 · 共 ${st.queueMinutes} 分钟',
              ctx,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: st.queue.length,
                itemBuilder: (c, i) {
                  final s = st.queue[i];
                  final on = i == st.index;
                  return InkWell(
                    onTap: () {
                      st.jumpTo(i);
                      setSheet(() {});
                    },
                    borderRadius: BorderRadius.circular(Tokens.rSm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            child: on
                                ? const Icon(Icons.graphic_eq_rounded,
                                    size: 15, color: Tokens.brand)
                                : Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                          ),
                          CoverArt(seed: s.coverSeed, size: 40, radius: 9),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                                    color: on ? Tokens.brand : null,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  s.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (s.sourceStatus != SourceStatus.ok)
                            SourceBadge(status: s.sourceStatus, compact: true),
                          const SizedBox(width: 6),
                          Text(
                            s.durationText,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showTimerSheet(BuildContext context, AppState st) {
  const opts = [
    ('不开启', 0),
    ('15 分钟', 15),
    ('30 分钟', 30),
    ('60 分钟', 60),
    ('90 分钟', 90),
  ];
  _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader(
            '定时关闭',
            st.sleepTimer == null
                ? '播放将在设定时间后自动停止'
                : '将于 ${st.sleepTimer!.inMinutes} 分钟后停止播放',
            ctx,
          ),
          const Divider(height: 1),
          for (final (label, mins) in opts)
            ListTile(
              onTap: () {
                st.setSleepTimer(mins == 0 ? null : Duration(minutes: mins));
                setSheet(() {});
                Navigator.of(ctx).pop();
              },
              leading: Icon(
                mins == 0 ? Icons.alarm_off_outlined : Icons.alarm_outlined,
                color: (mins == 0 && st.sleepTimer == null) ||
                        (mins > 0 && st.sleepTimer?.inMinutes == mins)
                    ? Tokens.brand
                    : null,
              ),
              title: Text(
                label,
                style: TextStyle(
                  fontWeight: (mins == 0 && st.sleepTimer == null) ||
                          (mins > 0 && st.sleepTimer?.inMinutes == mins)
                      ? FontWeight.w800
                      : FontWeight.w500,
                ),
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

/// 音效面板：预设 + 均衡器 + 全局响度 + 本曲音量。
///
/// ## 为什么不需要「总开关」
/// 「平直」预设就是关闭 EQ 的语义（选中即旁路），响度拉到 0 即关闭
/// 增益——两层结构（开关+预设）反而会出现「开关关了滑条还挂着值」
/// 的困惑。底部按钮的点亮逻辑 = `fx.isFxActive`（非平直 || 响度非 0）。
///
/// ## 刷新模型
/// 外层 StatefulBuilder 只管「本曲音量」滑条的本地显示值（拖动过程
/// 不落库）；其余一切（预设/EQ/响度）由 [AudioFxService] 的
/// ChangeNotifier 通知驱动——服务方法改完参数就 notifyListeners，
/// 内层 ListenableBuilder 自动重建，无需手动 setSheet。
///
/// ## 暗色红线
/// 所有显式颜色都按 `dark` 分流，暗色分支只用 surface2Dark/lineDark
/// 等暗色令牌，绝不借亮色系（brandSoft 等）——2026-09-30 换音源面板
/// 实证过 analyze 查不出这类错误。
void _showFxSheet(BuildContext context, AppState st) {
  // 本曲音量滑条的显示值：拖动中只改它，onChangeEnd 才走 AppState
  // （player.setVolume + track_volume 落库 + 全局广播）。
  var vol = st.trackVolume;
  _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) {
        final t = Theme.of(ctx);
        return ListenableBuilder(
          listenable: AudioFxService.instance,
          builder: (ctx, _) {
            final fx = AudioFxService.instance;
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.78,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sheetHeader('音效', '实时生效 · 针对 B站音源的听感修饰', ctx),
                  const Divider(height: 1),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── 预设 ──
                          const Text('预设',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final p in FxPreset.presets)
                                _FxChip(
                                  label: p.label,
                                  selected: fx.presetId == p.id,
                                  dark: t.brightness == Brightness.dark,
                                  onTap: () => fx.setPreset(p.id),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            FxPreset.byId(fx.presetId).desc,
                            style: _fxHintStyle(t),
                          ),

                          // ── 均衡器 ──
                          const SizedBox(height: 18),
                          const Text('均衡器',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w800)),
                          FutureBuilder<ja.AndroidEqualizerParameters?>(
                            future: fx.ensureParams(),
                            builder: (c, snap) {
                              final params = snap.data;
                              if (params == null) {
                                // 还没拿到（platform 激活中）或设备不支持
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  child: Text(
                                    snap.hasData
                                        ? '此设备不支持均衡器'
                                        : '正在读取均衡器参数…',
                                    style: _fxHintStyle(t),
                                  ),
                                );
                              }
                              return Column(
                                children: [
                                  for (final band in params.bands)
                                    _FxBandSlider(
                                      hz: band.centerFrequency,
                                      value: fx.gainAt(band.centerFrequency),
                                      min: params.minDecibels,
                                      max: params.maxDecibels,
                                      onChanged: (db) => fx
                                          .setBandGain(
                                              band.centerFrequency, db),
                                    ),
                                ],
                              );
                            },
                          ),
                          Text(
                            '拖动任意滑条会从当前预设固化出一条自定义曲线',
                            style: _fxHintStyle(t),
                          ),

                          // ── 全局响度 ──
                          const SizedBox(height: 14),
                          const Text('全局响度',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w800)),
                          _FxSliderRow(
                            valueText:
                                '${fx.loudnessDb >= 0 ? '+' : ''}${fx.loudnessDb.toStringAsFixed(1)} dB',
                            min: kLoudnessMinDb,
                            max: kLoudnessMaxDb,
                            value: fx.loudnessDb,
                            divisions: 40,
                            label:
                                '${fx.loudnessDb >= 0 ? '+' : ''}${fx.loudnessDb.toStringAsFixed(1)} dB',
                            onChanged: (v) => fx.setLoudnessDb(v),
                          ),
                          Text(
                            '整体增减响度，对全部歌曲生效。B站 UP 主混音响度\n'
                            '差异大，偏小的歌 +3~5 dB 常有奇效。',
                            style: _fxHintStyle(t),
                          ),

                          // ── 本曲音量（无歌在播时不显示）──
                          if (st.current != null) ...[
                            const SizedBox(height: 14),
                            const Text('本曲音量',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800)),
                            _FxSliderRow(
                              valueText: '${(vol * 100).round()}%',
                              min: 0,
                              max: 1,
                              value: vol,
                              divisions: 100,
                              label: '${(vol * 100).round()}%',
                              onChanged: (v) => setSheet(() => vol = v),
                              onChangeEnd: (v) => st.setTrackVolume(v),
                            ),
                            Text(
                              '只对《${st.current!.title}》生效，下次播放自动恢复',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _fxHintStyle(t),
                            ),
                          ],

                          // ── 重置 ──
                          const SizedBox(height: 8),
                          Center(
                            child: TextButton.icon(
                              onPressed: () => fx.resetAll(),
                              icon: const Icon(Icons.restart_alt_rounded,
                                  size: 17),
                              label: const Text('恢复默认音效'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

TextStyle _fxHintStyle(ThemeData t) => TextStyle(
      fontSize: 11.5,
      height: 1.4,
      color: t.colorScheme.onSurfaceVariant,
    );

/// 预设胶囊。选中 = 品牌红实底白字；未选中 = 中性底，
/// 明暗各用一套令牌（暗色分支禁用亮色令牌红线）。
class _FxChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool dark;
  final VoidCallback onTap;

  const _FxChip({
    required this.label,
    required this.selected,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? Tokens.brand
        : (dark ? Tokens.surface2Dark : Tokens.surface2);
    final fg = selected
        ? Colors.white
        : (dark ? const Color(0xFFC8CDD6) : const Color(0xFF454B58));
    final border = selected
        ? Tokens.brand
        : (dark ? Tokens.lineDark : Tokens.lineStrong);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rFull),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Tokens.rFull),
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// 单个 EQ band 滑条：左频点标签 + 右滑条。
/// 取值范围用设备真实 band 参数（minDecibels~maxDecibels），
/// 显示值走 `fx.gainAt`（曲线期望值，与预设/自定义状态永远一致）。
class _FxBandSlider extends StatelessWidget {
  final double hz;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _FxBandSlider({
    required this.hz,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  static String _freqLabel(double hz) {
    if (hz < 1000) return '${hz.round()}';
    final k = hz / 1000;
    return k == k.roundToDouble() ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = value.clamp(min, max).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            _freqLabel(hz),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: ((max - min) / 0.5).round().clamp(2, 200),
            label: '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// 通用「数值 + 滑条」行（全局响度 / 本曲音量共用）。
class _FxSliderRow extends StatelessWidget {
  final String valueText;
  final double min;
  final double max;
  final double value;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const _FxSliderRow({
    required this.valueText,
    required this.min,
    required this.max,
    required this.value,
    required this.divisions,
    required this.label,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 66,
          child: Text(
            valueText,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: t.colorScheme.onSurface,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ],
    );
  }
}

void _showSourceSheet(BuildContext context, AppState st, Song song) {
  final src = song.source;
  _sheet(
    context,
    Builder(builder: (ctx) {
      final t = Theme.of(ctx);
      final dark = t.brightness == Brightness.dark;

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('音源详情', '${song.title} · ${song.artist}', ctx),
          const Divider(height: 1),
          if (src == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 42, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('暂无可用音源'),
                  const SizedBox(height: 4),
                  Text(
                    '可以先重新匹配；仍找不到就用搜索手动指定',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      // 手动兜底：匹配引擎对冷门歌经常全军覆没（召回为空
                      // 或全被硬过滤），此时唯一出路是用户自己搜、自己挑。
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _showManualSearchSheet(context, st, song);
                          },
                          icon: const Icon(Icons.manage_search_rounded,
                              size: 17),
                          label: const Text('手动搜索音源'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Tokens.brand),
                          onPressed: () async {
                            final id = song.id;
                            if (id == null) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('演示数据不支持重新匹配'),
                                  duration: _kSnackHint,
                                ),
                              );
                              return;
                            }
                            final msg = await st.rematchSong(id);
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(msg),
                                duration: _kSnackResult,
                              ),
                            );
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('重新匹配'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: dark ? Tokens.surface2Dark : Tokens.surface2,
                      borderRadius: BorderRadius.circular(Tokens.rMd),
                    ),
                    child: Column(
                      children: [
                        _srcRow(t, '平台', '哔哩哔哩'),
                        _srcRow(t, '视频', src.bvid),
                        if (src.partTitle != null)
                          _srcRow(t, '分P', src.partTitle!),
                        // ★ 优先显示「这首实际在播的音质」。
                        // src 里的 qualityLabel 是库里缓存的「上次拉流档位」，
                        // 首次播放前它是「未知音质」（质量ID 0）——用户看到
                        // 的就成了「明明在放歌，却不知道放的什么音质」。
                        _srcRow(
                          t,
                          '当前音质',
                          st.playingQualityId > 0
                              ? '${st.playingQualityLabel} · '
                                  '质量ID ${st.playingQualityId}'
                              : '${src.qualityLabel} · '
                                  '质量ID ${src.qualityId}（未开始播放）',
                          highlight: true,
                        ),
                        // 把「上限偏好」一并摊开：用户改了设置能立刻看到它
                        // 生效在哪一档，而不是只能靠耳朵猜。
                        _srcRow(t, '音质上限', st.quality.label),
                        _srcRow(
                          t,
                          '匹配分',
                          '${src.matchScore.toStringAsFixed(2)} · '
                              '${src.auto ? "AUTO 自动采用" : "REVIEW 待复核"}',
                          highlight: true,
                        ),
                        _srcRow(
                          t,
                          '时长校验',
                          src.durationDelta == 0
                              ? '完全一致'
                              : '差 ${src.durationDelta > 0 ? "+" : ""}${src.durationDelta} 秒',
                        ),
                        _srcRow(t, 'UP主', src.uploader),
                        _srcRow(
                          t,
                          '播放量',
                          '${(src.playCount / 10000).toStringAsFixed(1)} 万',
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            // 用 Navigator 而非弹层：在 SourceSheet 上叠一个
                            // 全屏页，让用户能完整浏览候选列表。
                            // 关闭时回到这里继续看当前激活音源。
                            Navigator.of(ctx).pop();
                            _showCandidateSheet(context, st, song);
                          },
                          icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                          label: const Text('手动更换音源'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Tokens.brand),
                          onPressed: () async {
                            final id = song.id;
                            if (id == null) {
                              // mock 数据没有数据库 id，无法落库重匹配
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('演示数据不支持重新匹配'),
                                  duration: _kSnackHint,
                                ),
                              );
                              return;
                            }
                            final msg = await st.rematchSong(id);
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(msg),
                                duration: _kSnackResult,
                              ),
                            );
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('重新匹配'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
        ],
      );
    }),
  );
}

Widget _srcRow(ThemeData t, String k, String v,
    {bool highlight = false, bool last = false}) {
  return Padding(
    padding: EdgeInsets.only(bottom: last ? 0 : 8),
    child: Row(
      children: [
        SizedBox(
          width: 66,
          child: Text(
            k,
            style: TextStyle(fontSize: 11.5, color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
              color: highlight ? Tokens.brand : null,
            ),
          ),
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════
// 手动更换音源面板
// ═══════════════════════════════════════════════════════════════

/// 「手动更换音源」面板：列出该歌所有候选 + 重新匹配按钮。
///
/// ## 设计取舍
/// 旧版有专门的"音源匹配管理"页面（在「我的」页设置里），但用户场景分散：
/// 想换音源的时机大多数是「播放中发现这首歌不对」，此时打开的全屏播放页
/// 才是自然入口——也就是这里。把全局页删掉后，**唯一的换音源入口就是这个面板**，
/// 不再需要全局页。
///
/// ## 行为
/// - 列出 BindingDao.getCandidates(songId) 的所有候选，按分数倒序
/// - 当前激活项标「正在使用」
/// - 点击非激活项 → AppState.switchSource 切音源并重拉流
/// - 底部「重新匹配」按钮 → AppState.rematchSong
/// - 没有候选时给「重新匹配」按钮即可（重新匹配后会自动刷新）
void _showCandidateSheet(BuildContext context, AppState st, Song song) {
  final id = song.id;

  // 演示数据没有 id → 无法落库切换。给个明确提示，避免用户以为功能坏了
  if (id == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('演示数据不支持手动匹配'),
        duration: _kSnackHint,
      ),
    );
    return;
  }

  _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) {
        final t = Theme.of(ctx);
        final dark = t.brightness == Brightness.dark;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHeader('手动更换音源',
                '${song.title} · ${song.artist}', ctx),
            const Divider(height: 1),
            FutureBuilder<List<BindingRow>>(
              future: st.loadCandidates(id),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '加载失败：${snap.error}',
                      style: TextStyle(
                        fontSize: 12,
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final rows = snap.data ?? const <BindingRow>[];
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                    child: Column(
                      children: [
                        Icon(Icons.inbox_outlined,
                            size: 36,
                            color: t.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5)),
                        const SizedBox(height: 10),
                        const Text(
                          '暂无可选音源',
                          style: TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '重新匹配让系统再召回一轮；仍不行就手动搜索指定',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Tokens.brand),
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _showManualSearchSheet(context, st, song);
                          },
                          icon: const Icon(Icons.manage_search_rounded,
                              size: 17),
                          label: const Text('手动搜索音源'),
                        ),
                      ],
                    ),
                  );
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    // 弹层在桌面/平板上太矮就难看，限制一个最小滚动高度
                    maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                  ),
                  child: ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) => _candidateTile(
                        ctx, st, setSheet, rows[i], dark),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _showManualSearchSheet(context, st, song);
                      },
                      icon: const Icon(Icons.manage_search_rounded, size: 17),
                      label: const Text('手动搜索音源'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        final msg = await st.rematchSong(id);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(msg),
                            duration: _kSnackResult,
                          ),
                        );
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('重新匹配'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// 「手动搜索音源」面板：搜索 B站 → 用户亲选 → 绑定为该歌的音源并播放。
///
/// ## 为什么需要它
/// 匹配引擎的召回+打分对冷门歌/新歌经常全军覆没（召回为空或全部被
/// Stage2 硬过滤掉），此时「重新匹配」跑一百次结果都一样。唯一出路是
/// 用户自己搜、自己挑——打分交给用户的眼睛，标题黑名单不该拦着人工判断。
///
/// ## 行为
/// - 默认关键词 = 「歌名 歌手」，可改
/// - 点结果条目 → [AppState.bindManualSource]（视频落库 + 人工绑定 +
///   激活），若是当前在播的歌立即重拉流
/// - 单次搜索只发一个请求，不触碰限流红线
void _showManualSearchSheet(BuildContext context, AppState st, Song song) {
  final id = song.id;
  if (id == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('演示数据不支持手动匹配'),
        duration: _kSnackHint,
      ),
    );
    return;
  }

  final kw = TextEditingController(text: '${song.title} ${song.artist}');
  List<VideoCandidate>? results;
  var searching = false;

  _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) {
        final t = Theme.of(ctx);

        Future<void> doSearch() async {
          final q = kw.text.trim();
          if (q.isEmpty || searching) return;
          setSheet(() {
            searching = true;
            results = null;
          });
          final r = await st.manualSearchBili(q);
          setSheet(() {
            searching = false;
            results = r;
          });
        }

        Widget body;
        if (searching) {
          body = const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          );
        } else if (results == null) {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                Icon(Icons.manage_search_rounded,
                    size: 36,
                    color: t.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                const SizedBox(height: 10),
                Text(
                  '输入关键词搜索 B站 视频\n点选任意一条即作为这首歌的音源',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          );
        } else if (results!.isEmpty) {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              '没有搜到相关视频，换个关键词试试',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        } else {
          // 结果区高度 = 45% 屏高 - 键盘占位（键盘弹出时收窄结果区，
          // 下限 120，避免小屏 + 键盘把结果压没）。
          final h = MediaQuery.of(ctx).size.height * 0.45 -
              MediaQuery.of(ctx).viewInsets.bottom;
          body = ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: h < 120 ? 120 : h,
            ),
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: results!.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (_, i) => _manualResultTile(
                ctx, st, context, id, results![i], song,
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHeader('手动搜索音源', '${song.title} · ${song.artist}', ctx),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: kw,
                      onSubmitted: (_) => doSearch(),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '歌名 歌手',
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Tokens.rMd),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Tokens.brand),
                    onPressed: searching ? null : doSearch,
                    icon: const Icon(Icons.search_rounded, size: 17),
                    label: const Text('搜索'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            body,
            SizedBox(height: MediaQuery.of(ctx).padding.bottom + 8),
          ],
        );
      },
    ),
  );
}

/// 手动搜索结果的一项。点击 → 绑定为音源 + 立即播放。
Widget _manualResultTile(
  BuildContext sheetCtx,
  AppState st,
  BuildContext outerCtx,
  int songId,
  VideoCandidate v,
  Song song,
) {
  final t = Theme.of(sheetCtx);
  final mm = v.durationSec ~/ 60;
  final ss = (v.durationSec % 60).toString().padLeft(2, '0');

  return ListTile(
    dense: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Tokens.rMd),
    ),
    title: Text(
      v.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '${v.author.isEmpty ? "未知UP" : v.author}'
        ' · $mm:$ss'
        ' · ${(v.play / 10000).toStringAsFixed(1)} 万播放'
        ' · ${v.bvid}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
      ),
    ),
    trailing: const Icon(Icons.play_circle_outline_rounded, size: 22),
    onTap: () async {
      Navigator.of(sheetCtx).pop();
      final msg = await st.bindManualSource(songId: songId, video: v);
      if (!outerCtx.mounted) return;
      ScaffoldMessenger.of(outerCtx).showSnackBar(
        SnackBar(content: Text(msg), duration: _kSnackResult),
      );
    },
  );
}

/// 候选列表的一项。点击即触发切换并重拉流（AppState.switchSource 内部完成）。
Widget _candidateTile(BuildContext ctx, AppState st,
    void Function(void Function()) setSheet, BindingRow r, bool dark) {
  final t = Theme.of(ctx);
  // REJECTED 用灰色文字——它已经在候选里，但用户选了大概率翻车，
  // 视觉上要有"不推荐"的暗示而不是和正常候选一样亮。
  final isRejected = r.confidence.label == 'REJECTED';
  final inkColor = isRejected
      ? t.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
      : t.colorScheme.onSurface;

  return InkWell(
    borderRadius: BorderRadius.circular(Tokens.rMd),
    onTap: r.isActive
        ? null
        : () async {
            // 乐观地把 UI 切到"切换中"避免用户连点；switchSource 完成后关弹层
            setSheet(() {});
            final msg = await st.switchSource(songId: r.songId, bvid: r.bvid);
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(content: Text(msg), duration: _kSnackResult),
            );
          },
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          // 激活项暗色必须用 brandSoftDark（深酒红），不能用亮色的
          // brandSoft 浅粉——浅粉底 + 暗色主题近白文字 = 不可读
          color: r.isActive
              ? (dark ? Tokens.brandSoftDark : Tokens.brandSofter)
              : (dark ? Tokens.surface2Dark : Tokens.surface2),
          borderRadius: BorderRadius.circular(Tokens.rMd),
          border: r.isActive
              ? Border.all(
                  color: Tokens.brand.withValues(alpha: dark ? 0.5 : 0.35))
              : null,
        ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.bvid,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: r.isActive
                              ? FontWeight.w800
                              : FontWeight.w700,
                          color: inkColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _confTag(t, r.confidence.label),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '匹配分 ${r.matchScore.toStringAsFixed(2)}'
                  '${isRejected ? " · 不推荐" : ""}',
                  style: TextStyle(
                    fontSize: 11,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (r.isActive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Tokens.brand,
                borderRadius: BorderRadius.circular(Tokens.rFull),
              ),
              child: const Text(
                '正在使用',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            )
          else
            Icon(
              Icons.check_circle_outline_rounded,
              size: 18,
              color: t.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    ),
  );
}

/// 候选置信度标签（AUTO / REVIEW / REJECTED 三色）。
Widget _confTag(ThemeData t, String label) {
  Color bg;
  Color ink;
  switch (label) {
    case 'AUTO':
      bg = SemColor.okBg;
      ink = SemColor.okInk;
      break;
    case 'REVIEW':
      bg = SemColor.pendingBg;
      ink = SemColor.pendingInk;
      break;
    default: // REJECTED
      bg = SemColor.noneBg;
      ink = SemColor.noneInk;
  }
  final dark = t.brightness == Brightness.dark;
  if (dark) {
    bg = label == 'AUTO'
        ? SemColor.okBgDark
        : label == 'REVIEW'
            ? SemColor.pendingBgDark
            : SemColor.noneBgDark;
    ink = label == 'AUTO'
        ? SemColor.okInkDark
        : label == 'REVIEW'
            ? SemColor.pendingInkDark
            : SemColor.noneInkDark;
  }

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(Tokens.rFull),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        color: ink,
        letterSpacing: 0.3,
      ),
    ),
  );
}
