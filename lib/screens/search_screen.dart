import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/qqmusic/qqmusic_catalog_dto.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'browse_screen.dart';

class SearchScreen extends StatefulWidget {
  final AppState st;
  const SearchScreen({super.key, required this.st});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _c =
      TextEditingController(text: widget.st.query);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 打字只重建搜索页自身（清除按钮 / 结果区切换）。
    // st.setQuery 不再发全局通知（见其注释），这台 listener 是它的
    // 局部替代：重建范围从「MaterialApp 整树」缩到「搜索层」。
    _c.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _onQueryChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_onQueryChanged);
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final hasQuery = st.query.trim().isNotEmpty;

    return Container(
      color: dark ? Tokens.bgDark : Tokens.bg,
      child: SafeArea(
        child: Column(
          children: [
            // 搜索头
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: st.closeSearch,
                    icon: const Icon(Icons.arrow_back_rounded, size: 22),
                  ),
                  Expanded(
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: dark ? Tokens.surface2Dark : Tokens.surface,
                        borderRadius: BorderRadius.circular(Tokens.rFull),
                        border: Border.all(
                            color: dark ? Tokens.lineDark : Tokens.line),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded,
                              size: 18, color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _c,
                              focusNode: _focus,
                              onChanged: st.setQuery,
                              onSubmitted: st.commitSearch,
                              textInputAction: TextInputAction.search,
                              style: const TextStyle(fontSize: 13.5),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '搜索歌曲、歌手、专辑',
                                hintStyle: TextStyle(fontSize: 13.5),
                              ),
                            ),
                          ),
                          if (hasQuery)
                            GestureDetector(
                              onTap: () {
                                _c.clear();
                                st.setQuery('');
                                st.clearOnlineResults();
                              },
                              child: Icon(Icons.cancel_rounded,
                                  size: 17,
                                  color: t.colorScheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: hasQuery
                  ? _Results(st: st)
                  : _History(st: st, onPick: (q) {
                      _c.text = q;
                      st.commitSearch(q);
                    }),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索页的初始态：搜索历史。
class _History extends StatelessWidget {
  final AppState st;
  final ValueChanged<String> onPick;

  const _History({required this.st, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    if (st.history.isEmpty) {
      return const EmptyState(
        icon: Icons.search_rounded,
        title: '搜索 QQ 音乐',
        message: '输入歌名 / 歌手 / 专辑，按回车在线搜索 QQ 音乐。\n'
            '搜过的关键词会保留在这里。',
      );
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Row(
          children: [
            const Text('搜索历史',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
            const Spacer(),
            GestureDetector(
              onTap: st.clearHistory,
              child: Icon(Icons.delete_outline_rounded,
                  size: 18, color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final h in st.history)
              GestureDetector(
                onTap: () => onPick(h),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: dark ? Tokens.surface2Dark : Tokens.surface,
                    borderRadius: BorderRadius.circular(Tokens.rFull),
                    border: Border.all(
                        color: dark ? Tokens.lineDark : Tokens.line),
                  ),
                  child: Text(h, style: const TextStyle(fontSize: 12.5)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 四分类搜索结果（单曲 / 歌手 / 歌单 / 专辑）
// ═══════════════════════════════════════════════════════════════

class _Results extends StatefulWidget {
  final AppState st;
  const _Results({required this.st});

  @override
  State<_Results> createState() => _ResultsState();
}

class _ResultsState extends State<_Results> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

    @override
    void initState() {
      super.initState();
      _tabController = TabController(length: 3, vsync: this);
    }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final t = Theme.of(context);
    final results = st.searchResults;

    // 搜索中 / 出错 / 未接入
    if (st.onlineSearching && results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = st.onlineError;
    if (err != null) {
      return _ErrorView(st: st, err: err);
    }
    if (!st.canSearchOnline) {
      return _note(t, '当前环境未接入网络数据层，无法在线搜索。');
    }
    if (st.onlineSearched && results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '没找到「${st.query}」',
        message: 'QQ 音乐里也没有相关结果，换个关键词试试。',
      );
    }

    return Column(
      children: [
        // Tab 栏（显示各分类数量）
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(
            children: [
              _tabItem('单曲', results.songTotal, 0),
              const SizedBox(width: 20),
              _tabItem('歌手', results.singerTotal, 1),
              const SizedBox(width: 20),
              _tabItem('专辑', results.albumTotal, 2),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            physics: const BouncingScrollPhysics(),
            children: [
              _SongsTab(st: st),
              _SingersTab(st: st),
              _AlbumsTab(st: st),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tabItem(String label, int count, int index) => SegmentTabItem(
        label: label,
        count: count,
        active: _tabController.index == index,
        onTap: () {
          if (_tabController.index != index) {
            _tabController.animateTo(index);
            setState(() {});
          }
        },
      );

  Widget _note(ThemeData t, String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
        ),
      );
}

/// 搜索失败视图
class _ErrorView extends StatelessWidget {
  final AppState st;
  final String err;
  const _ErrorView({required this.st, required this.err});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 48),
        EmptyState(
          icon: Icons.cloud_off_rounded,
          title: '搜索失败',
          message: err,
          actionLabel: '重试',
          onAction: st.searchOnline,
        ),
      ],
    );
  }
}

// ── Tab 1: 单曲 ────────────────────────────────────────────

class _SongsTab extends StatelessWidget {
  final AppState st;
  const _SongsTab({required this.st});

  @override
  Widget build(BuildContext context) {
    final results = st.searchResults;
    if (results.songs.isEmpty) {
      return const EmptyState(
        icon: Icons.music_off_rounded,
        title: '暂无单曲',
        message: '换个关键词试试。',
      );
    }

    final songs = st.onlineResults; // List<OnlineSong>

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            itemCount: songs.length,
            itemBuilder: (c, i) {
              final s = songs[i].song;
              return SongRow(
                song: s,
                leading: SongCover(song: s, size: 46, radius: Tokens.rSm),
                subtitle: [
                  s.artist,
                  s.album,
                  if (s.duration > 0) s.durationText,
                ].where((x) => x.isNotEmpty).join(' · '),
                trailing: Icon(
                  Icons.play_arrow_rounded,
                  size: 20,
                  color: Theme.of(c).colorScheme.onSurfaceVariant,
                ),
                onTap: () => st.playOnline(songs, i),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => st.playOnline(songs, 0),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(
                '全部播放（${songs.length} 首）',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Tab 2: 歌手 ────────────────────────────────────────────

class _SingersTab extends StatelessWidget {
  final AppState st;
  const _SingersTab({required this.st});

  @override
  Widget build(BuildContext context) {
    final singers = st.searchResults.singers;
    if (singers.isEmpty) {
      return const EmptyState(
        icon: Icons.person_outline_rounded,
        title: '暂无歌手',
        message: '换个关键词试试。',
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: singers.length,
      itemBuilder: (c, i) => _SingerTile(
        singer: singers[i],
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BrowseScreen.singer(st, singers[i]),
          ));
        },
      ),
    );
  }
}

/// 歌手条目：圆形头像 + 名字
class _SingerTile extends StatelessWidget {
  final SingerBrief singer;
  final VoidCallback onTap;

  const _SingerTile({required this.singer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    const size = 46.0;

    Widget avatar;
    final initial = singer.name.isEmpty
        ? '#'
        : String.fromCharCode(singer.name.runes.first);

    Widget letter() => Center(
          child: Text(
            initial.toUpperCase(),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        );

    final hasPic = singer.pic.isNotEmpty;
    avatar = Container(
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
      child: hasPic
          ? CachedNetworkImage(
              imageUrl: singer.pic,
              fit: BoxFit.cover,
              memCacheWidth:
                  (size * MediaQuery.devicePixelRatioOf(context)).round(),
              fadeInDuration: Duration.zero,
              errorWidget: (_, __, ___) => letter(),
            )
          : letter(),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tokens.rMd),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 14),
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
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  if (singer.otherName.isNotEmpty)
                    Text(
                      singer.otherName,
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
            Icon(
              Icons.chevron_right_rounded,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tab 3: 专辑 ────────────────────────────────────────────

class _AlbumsTab extends StatelessWidget {
  final AppState st;
  const _AlbumsTab({required this.st});

  @override
  Widget build(BuildContext context) {
    final albums = st.searchResults.albums;
    if (albums.isEmpty) {
      return const EmptyState(
        icon: Icons.album_outlined,
        title: '暂无专辑',
        message: '换个关键词试试。',
      );
    }

    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.75,
      ),
      itemCount: albums.length,
      itemBuilder: (c, i) {
        final album = albums[i];
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
  }
}
