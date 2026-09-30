/// 音乐页（首页）：歌手库 / 歌单推荐 / 榜单 / 新歌推荐。
///
/// ## 产品形态（2026-09 方向调整）
/// 旧版是「导入优先」：先去搜索导入歌，首页才有内容。
/// 新版是「浏览优先」：打开就是 QQ音乐 的目录内容，点任何一首歌
/// 即播（后台静默入库 + 按需匹配），**不需要用户导入任何东西**。
///
/// ## 数据纪律（与空态契约同源）
/// 目录内容来自远端（`st.qq`），加载中就是转圈、失败就是重试，
/// **没有任何 mock 兜底**。曲库本地为空只影响「随便听一下」，
/// 不影响目录浏览——那本来就是两条独立的数据链。
library;

import 'package:flutter/material.dart';

import '../services/qqmusic/qqmusic_catalog_dto.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'browse_screen.dart';

/// 首页目录的 4 个 tab。顺序即用户的构想顺序。
const _kTabs = ['歌手库', '歌单推荐', '榜单', '新歌推荐'];

class HomeScreen extends StatelessWidget {
  final AppState st;

  const HomeScreen({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Container(
      color: dark ? Tokens.bgDark : Tokens.bg,
      child: SafeArea(
        bottom: false,
        child: DefaultTabController(
          length: _kTabs.length,
          child: Column(
            children: [
              // 顶栏
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 6, 0),
                child: Row(
                  children: [
                    const Text(
                      '音乐',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: st.toggleTheme,
                      icon: Icon(
                        st.isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 21,
                      ),
                    ),
                  ],
                ),
              ),

              // 搜索框
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: _SearchBar(onTap: st.openSearch),
              ),

              // 随便听一下（只依赖本地曲库，有歌才出现）
              if (st.library.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: _ShuffleCard(onPlay: st.shufflePlay),
                ),

              // 目录 tabs
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  splashBorderRadius: BorderRadius.circular(Tokens.rFull),
                  labelColor: dark ? Colors.white : Colors.black,
                  unselectedLabelColor: t.colorScheme.onSurfaceVariant,
                  labelStyle:
                      const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  unselectedLabelStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                  indicatorColor: Tokens.brand,
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerColor: Colors.transparent,
                  tabs: [for (final s in _kTabs) Tab(text: s)],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _SingersTab(st: st),
                    _PlaylistsTab(st: st),
                    _ToplistsTab(st: st),
                    _NewSongsTab(st: st),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: dark ? Tokens.surface2Dark : Tokens.surface,
          borderRadius: BorderRadius.circular(Tokens.rFull),
          border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 19, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 9),
            Text(
              '搜索歌曲、歌手、专辑',
              style: TextStyle(
                fontSize: 13.5,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShuffleCard extends StatelessWidget {
  final VoidCallback onPlay;
  const _ShuffleCard({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 17, 16, 17),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Tokens.rLg),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE5484D), Color(0xFFF2708C)],
        ),
        boxShadow: [
          BoxShadow(
            color: Tokens.brand.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shuffle_rounded, size: 17, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      '随便听一下',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '从你的收藏、常听和最近添加里智能混选',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.white.withValues(alpha: 0.88),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: Colors.white.withValues(alpha: 0.22),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPlay,
              child: const SizedBox(
                width: 46,
                height: 46,
                child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 目录视图的公共骨架：远端 Future 的三态（加载 / 错误重试 / 内容）
// ═══════════════════════════════════════════════════════════════

/// 远端目录视图的三态骨架。
///
/// 目录数据来自 QQ音乐，没有 mock 兜底：加载中就是转圈，
/// 失败给原因 + 重试按钮。retriable 用 key 重挂 FutureBuilder。
class _RemoteView<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data) builder;
  const _RemoteView({super.key, required this.load, required this.builder});

  @override
  State<_RemoteView<T>> createState() => _RemoteViewState<T>();
}

class _RemoteViewState<T> extends State<_RemoteView<T>> {
  late Future<T> _future;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _retry() {
    setState(() {
      _epoch++;
      _future = widget.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      key: ValueKey(_epoch),
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 48),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          return Center(
            child: EmptyState(
              icon: Icons.cloud_off_outlined,
              title: '加载失败',
              message: '${snap.error}\n请检查网络后重试。',
              actionLabel: '重试',
              onAction: _retry,
            ),
          );
        }
        return widget.builder(context, snap.data as T);
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Tab 1：歌手库（按热度分页 + 无限滚动）
// ═══════════════════════════════════════════════════════════════

class _SingersTab extends StatefulWidget {
  final AppState st;
  const _SingersTab({required this.st});

  @override
  State<_SingersTab> createState() => _SingersTabState();
}

class _SingersTabState extends State<_SingersTab> {
  final _scroll = ScrollController();
  final _singers = <SingerBrief>[];
  int _page = 1;
  int _totalPage = 1;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_loadingMore || _page >= _totalPage) return;
    if (_scroll.position.extentAfter < 600) _loadMore();
  }

  Future<void> _loadMore() async {
    final qq = widget.st.qq;
    if (qq == null) return;
    _loadingMore = true;
    try {
      final next = await qq.fetchSingers(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page = next.page;
        _totalPage = next.totalPage;
        _singers.addAll(next.singers);
      });
    } catch (_) {
      // 静默失败：翻页失败不打断浏览，滚回顶部或重进可重试。
      // 不做 toast——翻页是增强，报错反而打扰。
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    return _RemoteView<List<SingerBrief>>(
      load: () async {
        final qq = st.qq;
        if (qq == null) throw StateError('数据层未接入');
        final first = await qq.fetchSingers(page: 1);
        // 首屏数据直接进本地缓存列表，翻页往里追加
        _singers
          ..clear()
          ..addAll(first.singers);
        _page = first.page;
        _totalPage = first.totalPage;
        return _singers;
      },
      builder: (context, singers) {
        return ListView.builder(
          controller: _scroll,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          itemCount: singers.length + (_page < _totalPage ? 1 : 0),
          itemBuilder: (c, i) {
            if (i >= singers.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final s = singers[i];
            return _SingerRow(
              singer: s,
              onTap: () => _openSinger(st, s),
            );
          },
        );
      },
    );
  }

  void _openSinger(AppState st, SingerBrief s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowseScreen.singer(st, s),
    ));
  }
}

class _SingerRow extends StatelessWidget {
  final SingerBrief singer;
  final VoidCallback onTap;

  const _SingerRow({required this.singer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final letter = singer.letter.isEmpty ? '#' : singer.letter;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            // 首字母头像（歌手没有封面可用——接口不提供头像 URL）
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: dark ? Tokens.surface2Dark : Tokens.surface,
                shape: BoxShape.circle,
                border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
              ),
              child: Text(
                letter.toUpperCase(),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Tokens.brand,
                ),
              ),
            ),
            const SizedBox(width: 11),
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
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  if (singer.otherName.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      singer.otherName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 地区标签。真实信息（接口的 Farea），不是筛选按钮——
            // 实测接口不支持按地区过滤，摆个筛选项就是骗人。
            if (kSingerAreaLabels[singer.area]?.isNotEmpty ?? false)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: dark ? Tokens.surface2Dark : Tokens.surface,
                  borderRadius: BorderRadius.circular(Tokens.rFull),
                  border:
                      Border.all(color: dark ? Tokens.lineDark : Tokens.line),
                ),
                child: Text(
                  kSingerAreaLabels[singer.area]!,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Tab 2：歌单推荐（双列封面网格 + 推荐/最新切换）
// ═══════════════════════════════════════════════════════════════

class _PlaylistsTab extends StatefulWidget {
  final AppState st;
  const _PlaylistsTab({required this.st});

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  int _sortId = 5; // kPlaylistSorts 里的「推荐」

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
                    setState(() => _sortId = id);
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
          child: _RemoteView<List<PlaylistBrief>>(
            key: ValueKey(_sortId),
            load: () async {
              final qq = st.qq;
              if (qq == null) throw StateError('数据层未接入');
              return qq.fetchPlaylists(sortId: _sortId);
            },
            builder: (context, playlists) {
              return GridView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                        : Image.network(
                            brief.cover,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => CoverArt(
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

// ═══════════════════════════════════════════════════════════════
// Tab 3：榜单（分组展示 + 卡片带预览）
// ═══════════════════════════════════════════════════════════════

class _ToplistsTab extends StatelessWidget {
  final AppState st;
  const _ToplistsTab({required this.st});

  @override
  Widget build(BuildContext context) {
    return _RemoteView<List<ToplistGroup>>(
      load: () async {
        final qq = st.qq;
        if (qq == null) throw StateError('数据层未接入');
        return qq.fetchToplistGroups();
      },
      builder: (context, groups) {
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          itemCount: groups.length,
          itemBuilder: (c, gi) {
            final g = groups[gi];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: gi == 0 ? 6 : 18, bottom: 10),
                  child: Text(
                    g.name,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w800),
                  ),
                ),
                for (final tl in g.toplists)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ToplistCard(
                      brief: tl,
                      onTap: () {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => BrowseScreen.toplist(st, tl),
                        ));
                      },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ToplistCard extends StatelessWidget {
  final ToplistBrief brief;
  final VoidCallback onTap;

  const _ToplistCard({required this.brief, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rLg),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        decoration: BoxDecoration(
          color: dark ? Tokens.surfaceDark : Tokens.surface,
          borderRadius: BorderRadius.circular(Tokens.rLg),
          border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Tokens.brand,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        brief.title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                      if (brief.updateTime.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${brief.subtitle} · ${brief.totalNum} 首',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            if (brief.preview.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final p in brief.preview.take(3))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text(
                          '${p.rank}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: p.rank <= 3
                                ? Tokens.brand
                                : t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          p.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        p.singer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: t.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Tab 4：新歌推荐（巅峰榜·新歌，直接铺歌单行）
// ═══════════════════════════════════════════════════════════════

class _NewSongsTab extends StatelessWidget {
  final AppState st;
  const _NewSongsTab({required this.st});

  @override
  Widget build(BuildContext context) {
    return _RemoteView<ToplistDetail>(
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
                  return BrowseSongRow(
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
