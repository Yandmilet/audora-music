/// 播放页顶部：错误横幅 + 标题栏（返回 / 歌手入口 / 更多）。
///
/// 从 player_screen.dart 拆出（P3 结构整理，纯代码搬运）。
/// [ErrorBanner] / [TopBar] 被 PlayerScreen 直接构建，因此公开；
/// [_ArtistTap] 只被 TopBar 使用，保持私有。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/qqmusic/qqmusic_catalog_dto.dart'
    show SingerBrief;
import '../../state/app_state.dart';
import '../../theme.dart';
import '../browse_screen.dart' show BrowseScreen;

/// 播放失败提示条。
///
/// 用内联横幅而非 SnackBar：播放错误（音源失效、网络不通）是**持续状态**
/// 而不是一次性事件——用户需要它在界面上留着，直到自己重新匹配成功。
/// SnackBar 几秒就消失，用户回头再看时已经不知道刚才发生了什么。
class ErrorBanner extends StatelessWidget {
  final AppState st;
  const ErrorBanner({super.key, required this.st});

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

class TopBar extends StatelessWidget {
  final AppState st;
  final Song song;
  const TopBar({super.key, required this.st, required this.song});

  @override
  Widget build(BuildContext context) {
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
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 1),
                // 歌手名可点击 → 进入歌手详情页
                _ArtistTap(st: st, song: song),
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

/// 顶部歌手名：可点击 → 进入歌手详情页。
///
/// 有 singerMid 时构造完整 [SingerBrief] 并 push；
/// 没有时（旧数据 / mock）仍显示但不可点击——避免用户点了报错。
class _ArtistTap extends StatelessWidget {
  final AppState st;
  final Song song;
  const _ArtistTap({required this.st, required this.song});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = Text(
      song.artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 11,
        color: t.colorScheme.onSurfaceVariant,
        // 有 singerMid 时可点击，加下划线暗示
        decoration: song.singerMid != null
            ? TextDecoration.underline
            : TextDecoration.none,
      ),
    );
    final mid = song.singerMid;
    if (mid == null || mid.isEmpty) return text;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final singer = SingerBrief(
          mid: mid,
          singerId: song.singerId,
          name: song.artist,
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BrowseScreen.singer(
              st,
              singer,
              initialTab: 1,
              targetAlbumMid: song.albumMid,
            ),
          ),
        );
      },
      child: text,
    );
  }
}
