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
      singerMid: m.singerMid,
      singerId: m.singerId,
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

  /// 歌手详情入口（独立页面，有 Tab：热门歌曲 / 专辑）
  ///
  /// [initialTab] 控制初始选中的 tab（0 = 热门歌曲，1 = 专辑）。
  /// 从播放页点击歌手名进来时默认切到专辑 tab（更自然的上下文）。
  ///
  /// [targetAlbumMid] 非空时，专辑列表加载完后自动 push 进该专辑的详情页
  /// （播放页场景：直接看当前歌曲所在专辑）。
  static Widget singer(
    AppState st,
    SingerBrief singer, {
    int initialTab = 0,
    String? targetAlbumMid,
  }) {
    return SingerDetailScreen(
      st: st,
      singer: singer,
      initialTab: initialTab,
      targetAlbumMid: targetAlbumMid,
    );
  }

  /// 专辑详情入口
  factory BrowseScreen.album(AppState st, AlbumBrief album) {
    return BrowseScreen(
      st: st,
      title: album.name,
      subtitle: album.releaseDate.isEmpty ? null : '发行于 ${album.releaseDate}',
      coverUrl: album.cover.isEmpty ? null : album.cover,
      loader: () => st.qq!.fetchAlbumDetail(album.mid).then((d) => d.songs),
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
                    CoverImage(url: widget.coverUrl, seed: widget.title.hashCode, size: 64, radius: Tokens.rMd),
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
                    return SongRow(
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
// ═══════════════════════════════════════════════════════════════
// 歌手详情页：Tab（热门歌曲 / 专辑）+ 歌手头像封面
// ═══════════════════════════════════════════════════════════════

class SingerDetailScreen extends StatefulWidget {
  final AppState st;
  final SingerBrief singer;

  /// 初始 tab（0 = 热门歌曲，1 = 专辑）。
  ///
  /// 从歌手库进来默认 0；从播放页点击歌手进来传 1 更符合「看专辑」的上下文。
  final int initialTab;

  /// 非空时，专辑列表加载完后自动 push 进该专辑的详情页。
  /// 详情页会通过 st.current?.key 自动高亮当前正在播放的歌。
  final String? targetAlbumMid;

  const SingerDetailScreen({
    super.key,
    required this.st,
    required this.singer,
    this.initialTab = 0,
    this.targetAlbumMid,
  });

  @override
  State<SingerDetailScreen> createState() => _SingerDetailScreenState();
}

class _SingerDetailScreenState extends State<SingerDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// 热门歌曲列表（来自 fetchSingerSongs）
  late final Future<List<OnlineSong>> _songsFuture;

  /// 专辑列表（来自 fetchSingerAlbums，按时间倒序）
  late final Future<List<AlbumBrief>> _albumsFuture;

  /// 是否已执行过"找到 targetAlbumMid → 自动进专辑详情"的导航
  bool _autoNavDone = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    // 监听 TabController 变化，滑动 TabBarView 时也更新指示器
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    final qq = widget.st.qq;
    _songsFuture = qq == null
        ? Future.value(const [])
        : qq.fetchSingerSongs(widget.singer.mid).then(
            (list) => list.map(asOnlineSong).toList(),
          );
    _albumsFuture = qq == null || widget.singer.singerId == null
        ? Future.value(const [])
        : qq.fetchSingerAlbums(widget.singer.singerId!);

    // 从播放页进来时，如果给了 targetAlbumMid，专辑列表加载完后
    // 自动跳转到当前歌曲所在专辑的详情页（直接落到歌曲列表）。
    // 详情页会通过 st.current?.key 自动高亮当前正在播放的歌。
    _albumsFuture.then((albums) {
      if (!mounted || _autoNavDone) return;
      final targetMid = widget.targetAlbumMid;
      if (targetMid == null || targetMid.isEmpty) return;
      final match = albums.where((a) => a.mid == targetMid).firstOrNull;
      if (match == null) return;
      _autoNavDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BrowseScreen.album(widget.st, match),
        ));
      });
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final singer = widget.singer;

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶栏 + 歌手头像
            _SingerHeader(singer: singer),
            // Tab 栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  _tabItem('热门歌曲', 0),
                  const SizedBox(width: 20),
                  _tabItem('专辑', 1),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const BouncingScrollPhysics(),
                children: [
                  _SingerSongsTab(
                    st: widget.st,
                    future: _songsFuture,
                  ),
                  _SingerAlbumsTab(
                    st: widget.st,
                    future: _albumsFuture,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabItem(String label, int index) => SegmentTabItem(
        label: label,
        active: _tabController.index == index,
        // 目录页比搜索页的 tab 字号大一档
        activeFontSize: 16,
        fontSize: 13,
        activeUnderlineWidth: 18,
        onTap: () {
          if (_tabController.index != index) {
            _tabController.animateTo(index);
            setState(() {});
          }
        },
      );
}

/// 歌手详情页的顶部：返回按钮 + 歌手头像 + 名字
class _SingerHeader extends StatelessWidget {
  final SingerBrief singer;
  const _SingerHeader({required this.singer});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 10),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
          ),
          // 歌手头像
          _SingerAvatarLarge(singer: singer, dark: dark),
          const SizedBox(width: 14),
          // 歌手名 + 别名
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  singer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                if (singer.otherName.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    singer.otherName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌手详情页的大头像（圆形，64px）
class _SingerAvatarLarge extends StatelessWidget {
  final SingerBrief singer;
  final bool dark;
  const _SingerAvatarLarge({required this.singer, required this.dark});

  @override
  Widget build(BuildContext context) {
    const size = 64.0;
    // 用 runes 取首字符，处理 emoji 等代理对
    final initial = singer.name.isEmpty
        ? '#'
        : String.fromCharCode(singer.name.runes.first);

    Widget letter() => Center(
          child: Text(
            initial.toUpperCase(),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        );

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE5484D), Color(0xFFF2708C)],
        ),
        shape: BoxShape.circle,
        border: Border.all(
          color: dark ? Tokens.lineDark : Tokens.line,
          width: 1.5,
        ),
      ),
      child: singer.pic.isEmpty
          ? letter()
          : CachedNetworkImage(
              imageUrl: singer.pic,
              fit: BoxFit.cover,
              memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              fadeInDuration: Duration.zero,
              errorWidget: (_, __, ___) => letter(),
            ),
    );
  }
}

/// 热门歌曲 Tab
class _SingerSongsTab extends StatelessWidget {
  final AppState st;
  final Future<List<OnlineSong>> future;

  const _SingerSongsTab({required this.st, required this.future});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<OnlineSong>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '加载失败',
            message: '${snap.error}\n请检查网络后重试。',
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.music_off_outlined,
            title: '暂无热门歌曲',
            message: '这位歌手暂时没有歌曲数据。',
          );
        }

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          itemCount: items.length,
          itemBuilder: (c, i) {
            final s = items[i].song;
            return SongRow(
              song: s,
              currentKey: st.current?.key,
              onTap: () => st.playOnline(items, i),
            );
          },
        );
      },
    );
  }
}

/// 专辑 Tab（按时间倒序，点击进入专辑歌曲列表）
class _SingerAlbumsTab extends StatelessWidget {
  final AppState st;
  final Future<List<AlbumBrief>> future;

  const _SingerAlbumsTab({required this.st, required this.future});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AlbumBrief>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '加载失败',
            message: '${snap.error}\n请检查网络后重试。',
          );
        }
        final albums = snap.data ?? const [];
        if (albums.isEmpty) {
          return const EmptyState(
            icon: Icons.album_outlined,
            title: '暂无专辑',
            message: '这位歌手暂时没有专辑数据。',
          );
        }
        // 确保按时间倒序
        final sorted = AlbumBrief.sortByDateDesc(albums);

        return GridView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.75,
          ),
          itemCount: sorted.length,
          itemBuilder: (c, i) {
            final album = sorted[i];
            return AlbumCard(
              album: album,
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BrowseScreen.album(st, album),
                ));
              },
            );
          },
        );
      },
    );
  }
}
