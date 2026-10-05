/// 播放页「歌词」tab：滚动歌词 + 时间偏移校准 + 空态。
///
/// 从 player_screen.dart 拆出（P3 结构整理，纯代码搬运）。
library;

import 'package:flutter/material.dart';

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
  /// 主歌词最多 2 行（maxLines: 2），非高亮 15×1.5×2=45，高亮 18×1.5×2=54，
  /// 加一点上下留白取 60——之前 52 只够单行，高亮长行折 2 行就溢出压到下一行。
  static const _lineHeightPlain = 60.0;

  /// 有译文时的行高：主歌词最多 2 行（高亮 18×1.5×2=54）+ 3px 间距
  /// + 译文最多 2 行（高亮 13.5×1.35×2≈36）≈ 93，取 96 留余量。
  static const _lineHeightWithTrans = 96.0;

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
    // ★ 目标偏移必须包含 ListView 的上内边距（_edgePad = 0.3 屏高）：
    // item 的内容坐标 = topPad + i * 行高。漏掉 topPad 会让当前行
    // 停在视口底部而不是垂直居中（真机实测问题）。
    final target =
        _edgePad + (active * _lineHeight) - (viewport / 2) + (_lineHeight / 2);
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
  /// 自动比例映射能消除 UP 主加速减速的整曲等比例错位，
  /// 但 MV 片头/片尾这类「只在开头/结尾出问题」的错位
  /// 需要用户手动 ±ms 微调。调整立即生效并写入数据库。
  Widget _buildOffsetBar(ThemeData t, AppState st) {
    final offset = st.current?.lyricOffsetMs ?? 0;
    final hasOffset = offset != 0;
    final dark = t.brightness == Brightness.dark;
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
                  hasOffset ? '${offset > 0 ? '+' : ''}${offset}ms' : '自动对齐',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: hasOffset
                        ? Tokens.brand
                        : t.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (hasOffset)
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
          // 点歌词行跳到该行时间：找歌词时比拖进度条精确得多。
          // 反变换：LRC 行时间 → 真实音频时间（抵消 mappedLyricMs 做的正向映射）
          onTap: () {
            final total = st.duration;
            if (total <= 0) return;
            final lrcMs = lines[i].time.inMilliseconds;
            final realMs = _lrcToRealMs(st, lrcMs);
            final pos = (realMs / 1000 / total).clamp(0.0, 1.0);
            st.seekTo(pos);
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

/// 把 LRC 行的时间戳（毫秒）反变换为真实音频时间（毫秒）。
///
/// 这是 AppState.mappedLyricMs 正向变换的逆运算。
/// 点击歌词行 seek 时需要用它：用户看到的是 LRC 时间，
/// 但播放器只认真实音频时间。
int _lrcToRealMs(AppState st, int lrcMs) {
  final lines = st.lyrics;
  final realTailMs = st.duration * 1000;
  final userOffset = st.current?.lyricOffsetMs ?? 0;

  if (lines.isEmpty || realTailMs <= 0) return lrcMs - userOffset;

  final lrcTailMs = lines.last.time.inMilliseconds;
  final scale =
      (lrcTailMs > 0 && realTailMs > 0) ? (lrcTailMs / realTailMs) : 1.0;

  // lrcMs = realMs * scale + userOffset
  // → realMs = (lrcMs - userOffset) / scale
  final adjusted = (lrcMs - userOffset);
  return scale != 0 ? (adjusted / scale).round() : adjusted;
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
