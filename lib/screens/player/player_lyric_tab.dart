/// 播放页「歌词」tab：滚动歌词 + 时间偏移校准 + 空态。
///
/// 从 player_screen.dart 拆出（P3 结构整理，纯代码搬运）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/lyric/lrc_parser.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

/// 歌词页：真实 LRC 歌词 + 按播放进度自动滚动。
///
/// ## 三种状态各有对应界面
/// 1. 加载中 → 转圈（避免"暂无歌词"闪一下又变成有词）
/// 2. 无歌词（纯音乐 / 未匹配元数据 / 解析失败）→ 明确的空状态文案
/// 3. 有歌词 → 列表 + 自动居中当前行
///
/// 之前这里是**写死的《起风了》8 行词**，播任何歌都显示它——
/// 比显示"暂无歌词"更有误导性，用户会以为歌词滚动错位。已彻底移除。
class LyricTab extends StatefulWidget {
  final AppState st;
  const LyricTab({super.key, required this.st});

  @override
  State<LyricTab> createState() => _LyricTabState();
}

class _LyricTabState extends State<LyricTab> {
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
  ///
  /// 主歌词最多 2 行（maxLines: 2），非高亮 13×1.5×2=39，高亮 22×1.5×2=66，
  /// 取 72——高亮长行折 2 行在新字号下是常态，余量必须按高亮行算。
  static const _lineHeightPlain = 72.0;

  /// 有译文时的行高：主歌词最多 2 行（高亮 22×1.5×2=66）+ 3px 间距
  /// + 译文最多 2 行（高亮 13.5×1.35×2≈36）≈ 105，取 108 留余量。
  static const _lineHeightWithTrans = 108.0;

  double get _lineHeight =>
      widget.st.lyric.hasTranslation ? _lineHeightWithTrans : _lineHeightPlain;

  /// 已滚动的目标行，避免同一行反复触发动画
  int _scrolledTo = -1;

  /// 列表**顶部**留白。故意取小：第 0 行歌词就该贴在「自动对齐」校准条
  /// 下面。以前上下各留 0.3 屏高，前奏期整份歌词被顶到视口中线以下，
  /// 看起来就是「歌词空了半屏才下来」。
  static const _topPad = 8.0;

  /// 列表**底部**留白：只要够最后一行滚到视口中线即可。
  ///
  /// 定位计算（[_onState]）与列表内边距（build）必须用同一来源，
  /// 否则算出的偏移和真实布局对不上。取 0.3 屏高，比「视口一半」只多
  /// 不少，多出来的是尾部一点可滚余量，无害。
  double get _bottomPad => MediaQuery.of(context).size.height * 0.3;

  /// 上次定位时的歌词对象。首次加载 / 切歌后是新实例，
  /// 此时的第一次定位用 jumpTo 瞬移，而不是从旧位置滑过去。
  ParsedLyric? _lastLyric;

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_onState);
    // 滚动跟随的第二路驱动：**秒级进度通道**。
    // 位置推进不再触发 AppState 的全局通知（见 [AppState.posTick]），
    // 少了这一行就会「高亮在变、列表不滚」——而且只在播放中暴露，
    // 静止调试看不出来。
    widget.st.posTick.addListener(_onState);
  }

  @override
  void dispose() {
    widget.st.removeListener(_onState);
    widget.st.posTick.removeListener(_onState);
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
    // ★ 目标偏移必须包含 ListView 的上内边距：item 的内容坐标
    // = topPad + i * 行高。漏掉 topPad 会让当前行停在视口底部而不是
    // 垂直居中（真机实测问题）。
    //
    // topPad 只有 8 之后，前面几行（active 还小）算出来是**负数**，
    // 被下面 clamp(0) 抬成 0——这正是要的行为：歌词开局贴顶排布，
    // 唱过视口中线之后列表才开始往上滚。
    final target =
        _topPad + (active * _lineHeight) - (viewport / 2) + (_lineHeight / 2);
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
        if (lines.isNotEmpty) _buildOffsetBar(t, st),
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
              // 当前行高亮同样跟着秒级进度走，且**只重建歌词列表**：
              // 歌词有几十到上百行，跟着整棵树一起重建是这里最贵的开销。
              return ValueListenableBuilder<int>(
                valueListenable: st.posTick,
                builder: (_, __, ___) => _buildList(t, st, lines),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 歌词校准条：手动微调 LRC 时间轴。
  ///
  /// ±按钮做整曲平移（MV 片头/片尾/尾奏场景，调一次全曲准），
  /// 立即生效并写入数据库；变速场景长按歌词行做「本句对齐」两点校准。
  Widget _buildOffsetBar(ThemeData t, AppState st) {
    final offset = st.current?.lyricOffsetMs ?? 0;
    final slope = st.current?.lyricSlope ?? 1.0;
    final hasOffset = offset != 0;
    final hasSlope = (slope - 1.0).abs() > 0.0005;
    final pending = st.lyricAlignPending;
    final calibrated = hasOffset || hasSlope;
    final dark = t.brightness == Brightness.dark;

    // 主状态：待配对提示 > 变速 > 平移 > 默认
    final String status;
    if (pending) {
      status = '已记录第 1 个对齐点';
    } else if (hasSlope) {
      final pct = (slope - 1.0) * 100;
      status =
          '变速 ${pct > 0 ? '+' : ''}${pct.toStringAsFixed(1)}%'
          '${hasOffset ? '  ${offset > 0 ? '+' : ''}$offset ms' : ''}';
    } else if (hasOffset) {
      status = '${offset > 0 ? '+' : ''}$offset ms';
    } else {
      status = '自动对齐';
    }
    final statusActive = pending || calibrated;

    // 字轴来源：这条信息只对「歌词看起来不准」的排查有用，所以放在
    // 校准条而不是歌词角落——后者会在每一首歌上多出一个视觉噪声。
    // 「近似」= 均分推算（跟不上真实语速），「精确」= AMLL 的 Apple 逐字轴。
    final String? wordBadge = !st.lyric.hasWords
        ? null
        : st.lyric.wordsAllEstimated
            ? '逐字 · 近似'
            : '逐字 · 精确';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: dark ? Tokens.surface2Dark : Tokens.surface2,
        borderRadius: BorderRadius.circular(Tokens.rMd),
      ),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          // —— 大步长 ±5s —— 专治 MV 片头/片尾几十秒级错位
          _offsetBtn(t,
              icon: Icons.fast_rewind_rounded,
              label: '-5s',
              onPressed: () => st.adjustLyricOffset(-5000)),
          // —— 中步长 ±500ms —— 中等错位
          _offsetBtn(t,
              icon: Icons.remove_rounded,
              label: '-500ms',
              onPressed: () => st.adjustLyricOffset(-500)),
          // —— 小步长 ±50ms —— 细调
          _offsetBtn(t,
              icon: Icons.remove,
              label: '-50ms',
              small: true,
              onPressed: () => st.adjustLyricOffset(-50)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: statusActive
                        ? Tokens.brand
                        : t.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (pending)
                  Text(
                    '在间隔 20 秒以上的另一处再对准一次',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: t.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                    ),
                  )
                else if (calibrated)
                  GestureDetector(
                    onTap: () => st.resetLyricOffset(),
                    child: Text(
                      '重置',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: t.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.7),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  )
                else
                  Text(
                    '长按歌词行可快速对齐',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: t.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.55),
                    ),
                  ),
                // 默认态才显示字轴来源徽标：调过偏移时把位置让给更需要的信息
                if (!pending && !calibrated && wordBadge != null)
                  Text(
                    wordBadge,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: wordBadge.contains('精确')
                          ? Tokens.brand.withValues(alpha: 0.85)
                          : t.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _offsetBtn(t,
              icon: Icons.add,
              label: '+50ms',
              small: true,
              onPressed: () => st.adjustLyricOffset(50)),
          _offsetBtn(t,
              icon: Icons.add_rounded,
              label: '+500ms',
              onPressed: () => st.adjustLyricOffset(500)),
          _offsetBtn(t,
              icon: Icons.fast_forward_rounded,
              label: '+5s',
              onPressed: () => st.adjustLyricOffset(5000)),
        ],
      ),
    );
  }

  Widget _offsetBtn(
    ThemeData t, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool small = false,
  }) {
    final size = small ? 28.0 : 36.0;
    return Tooltip(
      message: label,
      preferBelow: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Tokens.rSm),
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            child: Icon(icon, size: small ? 16 : 20),
          ),
        ),
      ),
    );
  }

  Widget _buildList(ThemeData t, AppState st, List<LyricLine> lines) {
    // 当前行下标：用映射后的 LRC 空间位置查找，与 AppState._updateLyricLine
    // 同源——后者也用 mappedLyricMs，两边必须一致，否则滚动和高亮会打架
    final active = st.lyric.indexAt(Duration(milliseconds: st.mappedLyricMs));

    // 当前行两层的样式：字号/字重/行高完全一致，只有颜色不同。
    // 逐字层必须与右侧 else 分支的高亮样式对齐，否则激活瞬间会跳字距。
    //
    // 22 / 13 的 1.7 倍反差是指定口径：当前行要一眼锁得住。
    const fillStyle = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w800,
      height: 1.5,
      color: Tokens.brand,
    );
    final dimStyle = fillStyle.copyWith(color: t.colorScheme.onSurfaceVariant);

    return ListView.builder(
      controller: _scroll,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.only(
        left: 34,
        right: 34,
        // 上下不对称是有意为之：顶部只留 8 让第 0 行贴着校准条，
        // 底部留够当前行的居中空间（与 _onState 的定位计算同源）。
        top: _topPad,
        bottom: _bottomPad,
      ),
      itemCount: lines.length,
      itemExtent: _lineHeight,
      itemBuilder: (c, i) {
        final on = i == active;
        final near = active >= 0 && (i - active).abs() == 1;
        // 逐字扫光只给「当前行 + 有字轴」这一种情况：
        // 一行一个 Ticker，同屏最多 1 个在跑；其余行仍是普通的
        // AnimatedDefaultTextStyle，跟着秒级 posTick 走（见 build）。
        final karaoke = on && lines[i].hasWords;
        return GestureDetector(
          // 点歌词行 seek 到该行时间：找词时比拖进度条精确得多。
          // 反变换：LRC 行时间 → 真实音频时间（抵消 mappedLyricMs 做的正向映射）
          onTap: () => _seekToLine(st, i),
          // 长按 = 校准入口：「把这句对准当前位置」是两点校准的锚点操作
          onLongPress: () => _showLineActions(context, st, i),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (karaoke)
                  _KaraokeLine(
                    key: ValueKey('karaoke-$i-${lines[i].text}'),
                    st: st,
                    index: i,
                    line: lines[i],
                    dim: dimStyle,
                    fill: fillStyle,
                  )
                else
                  AnimatedDefaultTextStyle(
                    duration: Tokens.durFast,
                    style: TextStyle(
                      fontSize: on ? 22 : 13,
                      fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                      height: 1.5,
                      color: on
                          ? Tokens.brand
                          : t.colorScheme.onSurfaceVariant
                              .withValues(alpha: near ? 0.75 : 0.42),
                    ),
                    textAlign: TextAlign.center,
                    child: Text(
                      lines[i].text,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
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

/// 点击歌词行：seek 到该行对应的真实音频时间。
///
/// 反变换：LRC 行时间 → 真实音频时间（抵消 mappedLyricMs 做的正向映射），
/// 再按真实总时长换算成进度比例交给播放器。
void _seekToLine(AppState st, int i) {
  final total = st.duration;
  if (total <= 0) return;
  final realMs = _lrcToRealMs(st, st.lyrics[i].time.inMilliseconds);
  final pos = (realMs / 1000 / total).clamp(0.0, 1.0);
  st.seekTo(pos);
}

/// 长按歌词行弹出的操作：跳转 / 两点校准。
void _showLineActions(BuildContext context, AppState st, int i) {
  final t = Theme.of(context);
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              st.lyrics[i].text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.play_arrow_rounded),
            title: const Text('跳转到这句'),
            onTap: () {
              Navigator.pop(ctx);
              _seekToLine(st, i);
            },
          ),
          ListTile(
            leading: const Icon(Icons.my_location_rounded),
            title: const Text('把这句对准当前位置'),
            subtitle: const Text('声音唱到这句时按此校准；在间隔较远的另一处再做一次可校准变速'),
            onTap: () {
              Navigator.pop(ctx);
              final msg = st.alignLyricLine(i);
              if (msg != null) st.showToast(msg);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 把 LRC 行的时间戳（毫秒）反变换为真实音频时间（毫秒）。
///
/// 这是 AppState.mappedLyricMs 正向变换的逆运算：
/// `lrcMs = realMs * slope + offsetMs`
/// → `realMs = (lrcMs - offsetMs) / slope`
int _lrcToRealMs(AppState st, int lrcMs) {
  final slope = st.current?.lyricSlope ?? 1.0;
  final userOffset = st.current?.lyricOffsetMs ?? 0;
  final adjusted = lrcMs - userOffset;
  return slope != 0 ? (adjusted / slope).round() : adjusted;
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
            instrumental ? Icons.music_note_rounded : Icons.lyrics_outlined,
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

/// 逐字歌词的一行：卡拉OK式连续扫光。
///
/// ## 为什么只有当前行是独立 Widget
/// 扫光要 60fps 才看得出「连续」，而歌词列表有几十到上百行。
/// 如果把毫秒进度接进 [AppState] 的全局通知或 [AppState.posTick]，
/// 就等于每秒 60 次重建整棵树 / 整个列表——正是 `posTick` 注释里
/// 记录过、已经修掉的那个卡顿源。
///
/// 所以：**当前位置不进任何通知链**。本组件自持一个 Ticker，每帧向
/// [AppState.karaokeLyricMs] 拉一次「外推位置」，重绘范围只有这一行。
/// 整行高亮与自动滚动保持原来的秒级节奏，一行都不多重建。
///
/// ## 三条自动省电路
/// 1. 本页在 PageView 里，切到「歌曲」tab 时 `TickerMode` 自动静音，
///    看不见的地方不会空转。
/// 2. 位置不再变化（暂停）→ 停表；只剩入场字号补间那 180ms 在跑。
/// 3. 没有字轴的行根本不会构造本组件（`_buildList` 里按 `hasWords` 分流）。
class _KaraokeLine extends StatefulWidget {
  final AppState st;
  final int index;
  final LyricLine line;

  /// 未唱 / 已唱两层的样式。字号字重行高必须一致，只有颜色不同，
  /// 否则两层文字会错开半个字，扫光边缘就糊了。
  final TextStyle dim;
  final TextStyle fill;

  /// 行刚成为当前行时，字号从 13 长到 22 的补间时长。
  ///
  /// 原本这条补间由 `AnimatedDefaultTextStyle` 提供；换成自绘后不补，
  /// 当前行就会「啪」地跳大一号。借同一个 Ticker 的计时实现，零额外状态。
  static const entryDur = Duration(milliseconds: 180);

  const _KaraokeLine({
    super.key,
    required this.st,
    required this.index,
    required this.line,
    required this.dim,
    required this.fill,
  });

  @override
  State<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends State<_KaraokeLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// 上次驱动重绘的歌词位置（LRC 时间空间毫秒）
  int _lrcMs = -0x7FFFFFFF;

  /// 本表已跑过的时间。[Ticker] 不公开自己的计时，只把它作为回调入参给出，
  /// 所以自己存一份——入场字号补间要用。
  Duration _elapsed = Duration.zero;

  /// 排版缓存。两个 TextPainter 只内容色不同，布局参数完全一致。
  ///
  /// 不做缓存的话每帧要重排两次文字；入场补间那 180ms 内字号在变，
  /// 必须重排，之后 `cacheKey` 命中就一行代码都不排。
  TextPainter? _dimTp;
  TextPainter? _fillTp;
  String _cacheKey = '';

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _dimTp?.dispose();
    _fillTp?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    _elapsed = elapsed;
    final entering = elapsed < _KaraokeLine.entryDur;
    final ms = widget.st.karaokeLyricMs();
    if (ms != _lrcMs) {
      setState(() => _lrcMs = ms);
    } else if (!entering) {
      _syncTicker();
    }
  }

  @override
  void didUpdateWidget(covariant _KaraokeLine old) {
    super.didUpdateWidget(old);
    // 父级每秒重建一次（posTick 驱动）。暂停中 seek 时 Ticker 是停的，
    // 位置变了但没人推帧——在这里补一次，否则填充会冻在旧位置上。
    final ms = widget.st.karaokeLyricMs();
    if (ms != _lrcMs) {
      setState(() => _lrcMs = ms);
    }
    _syncTicker();
  }

  /// 只在「播放中」或「入场补间未完」时保持跑表。
  void _syncTicker() {
    if (!mounted) return;
    final needs = widget.st.playing || _elapsed < _KaraokeLine.entryDur;
    if (needs && !_ticker.isActive) {
      _ticker.start();
    } else if (!needs && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final maxW = cons.maxWidth.isFinite ? cons.maxWidth : 320.0;

      final emphasis =
          (_elapsed.inMilliseconds / _KaraokeLine.entryDur.inMilliseconds)
              .clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(emphasis);
      final fontSize = 13.0 + (22.0 - 13.0) * eased;
      final weight = FontWeight.lerp(FontWeight.w600, FontWeight.w800, eased)!;

      final dim = widget.dim.copyWith(fontSize: fontSize, fontWeight: weight);
      final fill = widget.fill.copyWith(fontSize: fontSize, fontWeight: weight);

      final key = '${widget.line.text}|$fontSize|$weight|$maxW';
      if (key != _cacheKey) {
        _dimTp?.dispose();
        _fillTp?.dispose();
        // maxLines / ellipsis 必须与普通行一致：固定 itemExtent 只有
        // 两行的余量，排到第三行就会溢出去压下一句。
        _dimTp = _layoutText(widget.line.text, dim, maxW, context);
        _fillTp = _layoutText(widget.line.text, fill, maxW, context);
        _cacheKey = key;
      }

      final tp = _dimTp!;
      final fillChars = widget.st.lyric
          .fillAt(widget.index, Duration(milliseconds: _lrcMs))
          .charsDone;

      return CustomPaint(
        size: Size(maxW, tp.height),
        painter: _KaraokePainter(
          dim: tp,
          painted: _fillTp!,
          totalChars: widget.line.text.length,
          fillChars: fillChars,
        ),
      );
    });
  }

  static TextPainter _layoutText(
      String text, TextStyle style, double maxWidth, BuildContext context) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: Directionality.of(context),
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  }
}

/// 逐字行在盒子里需要补的水平位移（永不为负）。
///
/// 抽成顶层纯函数只为了让「当前行偏左」这个 bug 有测试能钉住——
/// [_KaraokePainter] 是私有的，绘制结果也没法从 widget 树上量出来。
@visibleForTesting
double karaokeCenterDx(double boxWidth, double textWidth) {
  final dx = (boxWidth - textWidth) / 2;
  return dx.isFinite && dx > 0 ? dx : 0;
}

/// 两层文字的裁剪绘制：未唱色打底，已唱色按「唱到第几个字」裁出来盖上。
class _KaraokePainter extends CustomPainter {
  final TextPainter dim;
  final TextPainter painted;
  final int totalChars;
  final double fillChars;

  const _KaraokePainter({
    required this.dim,
    required this.painted,
    required this.totalChars,
    required this.fillChars,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ★ 必须先补一次水平位移再画：TextPainter 的 textAlign.center 对
    // **单行**段落不生效——layout(maxWidth: 300) 之后 tp.width 缩成文字
    // 本身的宽度（实测 54），字形也不会按 maxWidth 往右挪，paint(Offset.zero)
    // 就是贴着左边画。普通行走的是 Text 组件（RenderParagraph 会自己居中），
    // 所以只有「当前行 = 逐字扫光」这一条分支看起来偏左。
    //
    // 位移统一作用在两层之上，裁剪矩形保持在段落本地坐标系里，
    // 扫光边缘不会因为这次平移而错位。
    final dx = karaokeCenterDx(size.width, dim.width);
    canvas.save();
    if (dx > 0) canvas.translate(dx, 0);
    _paintParagraph(canvas);
    canvas.restore();
  }

  /// 段落本地坐标系（原点 = 文字左上角）下的两层绘制。
  void _paintParagraph(Canvas canvas) {
    dim.paint(canvas, Offset.zero);
    if (totalChars == 0 || fillChars <= 0) return;

    final w = dim.width;
    if (fillChars >= totalChars) {
      painted.paint(canvas, Offset.zero);
      return;
    }

    final cut = fillChars.floor();
    final frac = fillChars - cut;
    final caretBox = Rect.fromLTRB(0, 0, w, dim.height);
    final a = dim.getOffsetForCaret(TextPosition(offset: cut), caretBox);
    final b = dim.getOffsetForCaret(
        TextPosition(offset: cut + 1 < totalChars ? cut + 1 : totalChars),
        caretBox);

    // 换行处不能 lerp：a 在本行末、b 在下一行首，插值出来的 x 会横穿整行。
    // 这种边界直接取 a.dx，剩下的交给「上方整行」那块矩形覆盖。
    final x = b.dy == a.dy ? a.dx + (b.dx - a.dx) * frac : a.dx;
    // 行高取自实际排版结果而不是 style.fontSize*height：字体兜底、
    // 升降部超出、系统字体缩放都会让两者不等，用估算值会裁进/漏掉半行。
    final metrics = dim.computeLineMetrics();
    final lineH = metrics.isEmpty ? dim.height : metrics.first.height;

    _paintClipped(canvas, Rect.fromLTRB(0, 0, w, a.dy)); // 之前的视觉行：已唱完
    _paintClipped(canvas, Rect.fromLTRB(0, a.dy, x, a.dy + lineH)); // 当前行进到 x
  }

  void _paintClipped(Canvas canvas, Rect rect) {
    if (rect.isEmpty) return;
    canvas.save();
    canvas.clipRect(rect);
    painted.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KaraokePainter old) =>
      old.fillChars != fillChars ||
      old.totalChars != totalChars ||
      old.dim != dim ||
      old.painted != painted;
}
