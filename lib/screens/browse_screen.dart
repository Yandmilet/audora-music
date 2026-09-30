/// 通用「目录歌曲列表」页：榜单详情 / 歌手歌曲 / 歌单详情 共用。
///
/// ## 设计立场
/// 这一页是「浏览优先」产品的核心：用户从目录点进来，**点任何一首就播**，
/// 不存在「导入」按钮。整批歌曲在点击瞬间静默入库（[AppState.playOnline]
/// → `persistOnline`），然后交给既有的按需匹配链路——首次播放约 20 秒，
/// 由全局状态条给出进度反馈。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/repository/library_repository.dart';
import '../models/models.dart';
import '../services/qqmusic/qqmusic_catalog_dto.dart';
import '../services/qqmusic/qqmusic_dto.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 把目录里的歌转成可入库播放的 [OnlineSong]。
///
/// 统一放在这里而不是散在各 tab：`songMid` 是入库唯一凭据，漏传的话
/// 歌词会静默失效（E23 的同类陷阱）。QQSongMeta 本身就带全三个字段。
OnlineSong asOnlineSong(QQSongMeta m) => OnlineSong(
      song: m.toSong(),
      songMid: m.songMid,
      albumMid: m.albumMid,
    );

class BrowseScreen extends StatefulWidget {
  final AppState st;

  /// 标题（榜单名 / 歌手名 / 歌单名）
  final String title;

  /// 副标题（更新时间 / 收听数等），可空
  final String? subtitle;

  /// 封面 URL（歌单封面 / 榜单头图）。加载失败回退到气泡封面。
  final String? coverUrl;

  /// 歌曲加载器。**懒加载**：进入页面才请求，失败可整页重试。
  final Future<List<QQSongMeta>> Function() loader;

  /// 是否显示名次列（榜单是 1..N，歌单/歌手歌不是排名）
  final bool showRank;

  const BrowseScreen({
    super.key,
    required this.st,
    required this.title,
    required this.loader,
    this.subtitle,
    this.coverUrl,
    this.showRank = false,
  });

  /// 榜单详情入口
  factory BrowseScreen.toplist(AppState st, ToplistBrief brief) {
    return BrowseScreen(
      st: st,
      title: brief.title,
      subtitle: brief.updateTime.isEmpty ? null : '更新于 ${brief.updateTime}',
      showRank: true,
      loader: () => st.qq!.fetchToplistDetail(brief.topId).then((d) => d.songs),
    );
  }

  /// 歌手歌曲入口
  factory BrowseScreen.singer(AppState st, SingerBrief singer) {
    return BrowseScreen(
      st: st,
      title: singer.name,
      subtitle: singer.otherName.isEmpty ? null : singer.otherName,
      loader: () => st.qq!.fetchSingerSongs(singer.mid),
    );
  }

  /// 歌单详情入口
  factory BrowseScreen.playlist(AppState st, PlaylistBrief brief) {
    return BrowseScreen(
      st: st,
      title: brief.title,
      subtitle: brief.creator.isEmpty ? null : '创建者：${brief.creator}',
      coverUrl: brief.cover.isEmpty ? null : brief.cover,
      loader: () => st.qq!.fetchPlaylistDetail(brief.dissId).then((d) => d.songs),
    );
  }

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  late Future<List<QQSongMeta>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _retry() {
    setState(() => _future = widget.loader());
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
        titleSpacing: 4,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.2),
        ),
      ),
      body: SwipeBack(
        onBack: () => Navigator.of(context).maybePop(),
        child: FutureBuilder<List<QQSongMeta>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return EmptyState(
              icon: Icons.cloud_off_outlined,
              title: '加载失败',
              message: '${snap.error}\n请检查网络后重试。',
              actionLabel: '重试',
              onAction: _retry,
            );
          }
          final songs = snap.data ?? const [];
          if (songs.isEmpty) {
            return const EmptyState(
              icon: Icons.music_off_outlined,
              title: '这里没有歌',
              message: '可能是内容已下架，换个榜单或歌单试试。',
            );
          }
          final items = songs.map(asOnlineSong).toList();

          return Column(
            children: [
              // 头部信息 + 播放全部
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Row(
                  children: [
                    _CoverOrArt(url: widget.coverUrl, seed: widget.title.hashCode),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.subtitle != null) ...[
                            Text(
                              widget.subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: t.colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            '${items.length} 首 · 点击即播，首次播放约 20 秒完成音源匹配',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: t.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  itemCount: items.length,
                  itemBuilder: (c, i) {
                    final s = items[i].song;
                    return BrowseSongRow(
                      rank: widget.showRank ? i + 1 : null,
                      song: s,
                      currentKey: widget.st.current?.key,
                      onTap: () => widget.st.playOnline(items, i),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      ),
    );
  }
}

/// 封面：有 URL 用网络图（失败回退气泡封面），没有直接气泡封面
class _CoverOrArt extends StatelessWidget {
  final String? url;
  final int seed;
  const _CoverOrArt({this.url, required this.seed});

  @override
  Widget build(BuildContext context) {
    const size = 64.0;
    if (url == null || url!.isEmpty) {
      return CoverArt(seed: seed, size: size, radius: Tokens.rMd);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Tokens.rMd),
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) =>
            CoverArt(seed: seed, size: size, radius: 0),
      ),
    );
  }
}

/// 单行歌曲（公开：首页的「新歌推荐」tab 复用同一观感）。
/// 与搜索页的行保持一致的观感，但行为不同：点 = 播。
class BrowseSongRow extends StatelessWidget {
  final int? rank;
  final Song song;
  final VoidCallback onTap;

  /// 当前正在播的 key。高亮它，让用户知道点过之后哪首在放。
  final String? currentKey;

  const BrowseSongRow({
    super.key,
    this.rank,
    required this.song,
    required this.onTap,
    this.currentKey,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isCurrent = currentKey == song.key;
    final top3 = rank != null && rank! <= 3;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            if (rank != null)
              SizedBox(
                width: 26,
                child: Text(
                  '$rank',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: top3 ? Tokens.brand : t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: isCurrent ? Tokens.brand : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
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
            const SizedBox(width: 8),
            Text(
              song.durationText,
              style: TextStyle(
                fontSize: 10.5,
                color: t.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
