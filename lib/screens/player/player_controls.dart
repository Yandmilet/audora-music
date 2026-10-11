/// 播放页控制区：进度条 + 播放控制 + 底部功能条。
///
/// 从 player_screen.dart 拆出（P3 结构整理，纯代码搬运）。
/// 底部功能条负责打开各个底部弹层（队列 / 睡眠 / 音效 / 音源），
/// 因此依赖 player_sheets.dart 与 player_source_sheet.dart 的公开入口。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/fx/audio_fx_service.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../player/player_sheets.dart';
import '../player/player_source_sheet.dart';

class ProgressBar extends StatelessWidget {
  final AppState st;
  const ProgressBar({super.key, required this.st});

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

class Controls extends StatelessWidget {
  final AppState st;
  const Controls({super.key, required this.st});

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
              st.isLiked(st.current!)
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
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

class FootActions extends StatelessWidget {
  final AppState st;
  const FootActions({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          _FootBtn(
            icon: Icons.queue_music_rounded,
            label: '播放队列',
            onTap: () => showQueueSheet(context, st),
          ),
          _FootBtn(
            // 闹钟图标：避免与深色模式月亮图标语义重复
            icon: Icons.alarm_outlined,
            label: st.sleepTimer == null
                ? '定时关闭'
                : '${st.sleepTimer!.inMinutes} 分钟',
            active: st.sleepTimer != null,
            onTap: () => showTimerSheet(context, st),
          ),
          // 下载（未下载 → 百分比 → 已下载，三态都在这一个位置上）
          _DownloadFootBtn(st: st, song: st.current!),
          // 音效按钮的 active 态（EQ 非平直 / 响度非 0）由 FX 服务驱动：
          // 服务是 ChangeNotifier，面板里改参数后按钮即时点亮/熄灭。
          ListenableBuilder(
            listenable: AudioFxService.instance,
            builder: (c, _) => _FootBtn(
              icon: Icons.graphic_eq_rounded,
              label: '音效',
              active: AudioFxService.instance.isFxActive,
              onTap: () => showFxSheet(context, st),
            ),
          ),
          _FootBtn(
            icon: Icons.cloud_download_outlined,
            label: '音源',
            onTap: () => showSourceSheet(context, st, st.current!),
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
  final VoidCallback? onTap;
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

/// 播放页的下载按钮：三态（未下载 / 百分比 / 已下载）。
///
/// 单独一个 StatelessWidget 而不是内联在 [FootActions] 里，是因为它要同时
/// 处理「点一下开始」「点第二下取消」「已下载点了是移除」三条分支，加上
/// 确认弹窗和 SnackBar——内联会让那一行 Row 难读到看不出结构。
class _DownloadFootBtn extends StatelessWidget {
  final AppState st;
  final Song song;

  const _DownloadFootBtn({required this.st, required this.song});

  @override
  Widget build(BuildContext context) {
    final ui = st.downloadUi(song);
    final downloaded = ui.done;

    return _FootBtn(
      icon: downloaded
          ? Icons.download_done_rounded
          : ui.running
              ? Icons.download_rounded
              : Icons.download_outlined,
      label: ui.label,
      // 已下载 = 绿色高亮；下载中同样高亮，让这一格在五个按钮里明显是「活的」
      active: downloaded || ui.running,
      onTap: ui.enabled
          ? () {
              if (downloaded) {
                _removeDownload(context, st, song);
              } else if (ui.running) {
                _report(context, st.cancelDownload());
              } else if (ui.label == '重试') {
                _report(context, st.retryDownload(song));
              } else {
                _report(context, st.startDownload(song));
              }
            }
          : null,
    );
  }
}

/// 移除已下载要二次确认：这一步会**真的删掉手机上的文件**。
Future<void> _removeDownload(
  BuildContext context,
  AppState st,
  Song song,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除已下载的文件？', style: TextStyle(fontSize: 16)),
      content: Text(
        '「${song.title}」的本地文件会被删掉，之后播放这首歌重新走在线音源。',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  // 弹窗挂着的时候播放页可能被 pop 掉（用户下滑关闭），
  // 回来时 context 可能已经不在树上。
  if (!context.mounted) return;
  await _report(context, st.removeDownload(song));
}

/// 把「一句原因」如实说给用户。null = 成功，什么都不弹。
Future<void> _report(BuildContext context, Future<String?> op) async {
  final msg = await op;
  if (msg == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
