/// Tab 2：歌单推荐（双列封面网格 + 推荐/最新切换）。
///
/// 从 home_screen.dart 拆出（P3 结构整理，纯代码搬运）。
library;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/qqmusic/qqmusic_catalog_dto.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../browse_screen.dart';
import 'remote_view.dart';

// ═══════════════════════════════════════════════════════════════
// Tab 2：歌单推荐（双列封面网格 + 推荐/最新切换）
// ═══════════════════════════════════════════════════════════════

class PlaylistsTab extends StatefulWidget {
  final AppState st;
  const PlaylistsTab({super.key, required this.st});

  @override
  State<PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<PlaylistsTab> {
  int _sortId = 5; // kPlaylistSorts 里的「推荐」
  int _page = 0; // 下拉刷新递增，翻到底自动归零循环
  final _remoteKey = GlobalKey<RemoteViewState<List<PlaylistBrief>>>();

  Future<void> _onRefresh() async {
    final qq = widget.st.qq;
    if (qq == null) return;
    _page++;
    // 先预取一页数据写入缓存，确保 RefreshIndicator 和 RemoteView 都能正确 await
    final batch = await qq.fetchPlaylists(sortId: _sortId, page: _page);
    if (batch.isEmpty) {
      // 翻到底了，归零重来
      _page = 0;
      await qq.fetchPlaylists(sortId: _sortId, page: 0);
    }
    if (!mounted) return;
    // 通过 GlobalKey 触发 reload，避免 widget 销毁重建造成闪烁
    _remoteKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Column(
      children: [
        // 排序切换。只放两档——实测接口只有这两档真的不同
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              for (final (id, label) in kPlaylistSorts) ...[
                if (id != _sortId) const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    if (id == _sortId) return;
                    _sortId = id;
                    _page = 0; // 换分类从第一页开始
                    _remoteKey.currentState?.reload();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: id == _sortId
                          ? Tokens.brand
                          : (dark ? Tokens.surface2Dark : Tokens.surface),
                      borderRadius: BorderRadius.circular(Tokens.rFull),
                      border: Border.all(
                        color: id == _sortId
                            ? Tokens.brand
                            : (dark ? Tokens.lineDark : Tokens.line),
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: id == _sortId
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: id == _sortId
                            ? Colors.white
                            : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: RemoteView<List<PlaylistBrief>>(
            key: _remoteKey,
            load: () async {
              final qq = st.qq;
              if (qq == null) throw StateError('数据层未接入');
              return qq.fetchPlaylists(sortId: _sortId, page: _page);
            },
            builder: (context, playlists) {
              return RefreshIndicator(
                onRefresh: _onRefresh,
                child: GridView.builder(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.86,
                  ),
                  itemCount: playlists.length,
                  itemBuilder: (c, i) =>
                      _PlaylistCard(brief: playlists[i], onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => BrowseScreen.playlist(st, playlists[i]),
                    ));
                  }),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final PlaylistBrief brief;
  final VoidCallback onTap;

  const _PlaylistCard({required this.brief, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Tokens.rLg),
                    child: brief.cover.isEmpty
                        ? CoverArt(
                            seed: brief.dissId.hashCode,
                            size: 200,
                            radius: 0,
                          )
                        : CachedNetworkImage(
                            imageUrl: brief.cover,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => CoverArt(
                              seed: brief.dissId.hashCode,
                              size: 200,
                              radius: 0,
                            ),
                          ),
                  ),
                ),
                // 收听数角标
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(Tokens.rFull),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.headphones_rounded,
                            size: 10, color: Colors.white),
                        const SizedBox(width: 3),
                        Text(
                          _listenText(brief.listenNum),
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          Text(
            brief.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.35),
          ),
          const SizedBox(height: 2),
          Text(
            brief.creator,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _listenText(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}
