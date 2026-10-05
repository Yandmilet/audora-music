/// Tab 4：新歌推荐（巅峰榜·新歌，直接铺歌单行）。
///
/// 从 home_screen.dart 拆出（P3 结构整理，纯代码搬运）。
library;
import 'package:flutter/material.dart';

import '../../services/qqmusic/qqmusic_catalog_dto.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../browse_screen.dart';
import 'remote_view.dart';

// ═══════════════════════════════════════════════════════════════
// Tab 4：新歌推荐（巅峰榜·新歌，直接铺歌单行）
// ═══════════════════════════════════════════════════════════════

class NewSongsTab extends StatelessWidget {
  final AppState st;
  const NewSongsTab({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    return RemoteView<ToplistDetail>(
      load: () async {
        final qq = st.qq;
        if (qq == null) throw StateError('数据层未接入');
        return qq.fetchToplistDetail(kNewSongTopId);
      },
      builder: (context, detail) {
        final items = detail.songs.map(asOnlineSong).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      detail.updateTime.isEmpty
                          ? '${items.length} 首新歌'
                          : '${items.length} 首新歌 · 更新于 ${detail.updateTime}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // 播放全部
                  TextButton.icon(
                    onPressed:
                        items.isEmpty ? null : () => st.playOnline(items, 0),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('播放全部',
                        style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: Tokens.brand,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                itemCount: items.length,
                itemBuilder: (c, i) {
                  final s = items[i].song;
                  return SongRow(
                    rank: i + 1,
                    song: s,
                    currentKey: st.current?.key,
                    onTap: () => st.playOnline(items, i),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
