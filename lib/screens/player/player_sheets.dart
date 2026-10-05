/// 底部弹层基建 + 队列 / 睡眠定时 / 音效三个弹层。
///
/// 从 player_screen.dart 拆出（P3 结构整理，纯代码搬运）。
/// [showAppSheet] / [sheetHeader] 是所有弹层共用的骨架（含键盘高度适配），
/// 音源类弹层（player_source_sheet*.dart）也复用它们，故公开。
library;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../../models/models.dart';
import '../../services/fx/audio_fx_service.dart';
import '../../services/fx/fx_preset.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';


/// SnackBar 驻留时长：固定短提示 1.5s / 操作结果 2s。
///
/// ## 为什么是这个值
/// 中文提示 10~20 字，按 5~7 字/秒的阅读速度加反应时间，1.5~2s 足够读完；
/// 此前散落的 2~3s（全局 toast 甚至 5s）用户反馈驻留过长。带「建议操作」
/// 的引导文案（如「试试手动搜索音源」）也归结果类 2s。调参改这里，勿再散写。
///
/// 公开而非私有：音源类弹层（player_source_sheet*.dart）同样用它们——
/// 弹层基建与文案时长参数统一放在这一个文件里。
const Duration kSnackHint = Duration(milliseconds: 1500);
const Duration kSnackResult = Duration(seconds: 2);

// ============ 底部弹窗 ============

void showAppSheet(BuildContext context, Widget child) {
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
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: child,
    ),
  );
}

Widget sheetHeader(String title, String sub, BuildContext ctx) {
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
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                sub,
                style: TextStyle(
                    fontSize: 11.5, color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

void showQueueSheet(BuildContext context, AppState st) {
  showAppSheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            sheetHeader(
              '播放队列',
              '${st.mode.label} · ${st.queue.length} 首 · 共 ${st.queueMinutes} 分钟',
              ctx,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
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
                          SongCover(song: s, size: 40, radius: 9),
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
                                    fontWeight:
                                        on ? FontWeight.w800 : FontWeight.w600,
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

void showTimerSheet(BuildContext context, AppState st) {
  const opts = [
    ('不开启', 0),
    ('15 分钟', 15),
    ('30 分钟', 30),
    ('60 分钟', 60),
    ('90 分钟', 90),
  ];
  showAppSheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          sheetHeader(
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
void showFxSheet(BuildContext context, AppState st) {
  // 本曲音量滑条的显示值：拖动中只改它，onChangeEnd 才走 AppState
  // （player.setVolume + track_volume 落库 + 全局广播）。
  var vol = st.trackVolume;
  showAppSheet(
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
                  sheetHeader('音效', '实时生效 · 针对 B站音源的听感修饰', ctx),
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
                                    snap.hasData ? '此设备不支持均衡器' : '正在读取均衡器参数…',
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
                                      onChanged: (db) => fx.setBandGain(
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
                                    fontSize: 13, fontWeight: FontWeight.w800)),
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
    final border =
        selected ? Tokens.brand : (dark ? Tokens.lineDark : Tokens.lineStrong);

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
    return k == k.roundToDouble()
        ? '${k.round()}k'
        : '${k.toStringAsFixed(1)}k';
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
