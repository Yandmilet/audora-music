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

import '../state/app_state.dart';
import '../theme.dart';
import 'home/new_songs_tab.dart';
import 'home/playlists_tab.dart';
import 'home/singers_tab.dart';
import 'home/toplists_tab.dart';

// 四个目录 tab 与远端视图骨架拆在 home/ 子目录（P3 结构整理，纯代码搬运）。
// 这里转出测试依赖的公开符号，保证 test/ 里 import home_screen 的路径不变。
export 'home/singers_tab.dart' show singerIndexBarHit;
export 'home/toplists_tab.dart' show ToplistCard;

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
                    SingersTab(st: st),
                    PlaylistsTab(st: st),
                    ToplistsTab(st: st),
                    NewSongsTab(st: st),
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
