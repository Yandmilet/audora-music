/// 音乐页（首页）：歌手库 / 歌单推荐 / 榜单 / 新歌推荐。
///
/// ## 产品形态（2026-09 方向调整）
/// 旧版是「导入优先」：先去搜索导入歌，首页才有内容。
/// 新版是「浏览优先」：打开就是 QQ音乐 的目录内容，点任何一首歌
/// 即播（后台静默入库 + 按需匹配），**不需要用户导入任何东西**。
///
/// ## 数据纪律（与空态契约同源）
/// 目录内容来自远端（`st.qq`），加载中就是转圈、失败就是重试，
/// **没有任何 mock 兜底**。「猜你想听」与「最近听过」两张入口卡
/// （2026-10-11 取代原「随便听一下」大卡）同样遵守：前者拉不到就
/// 报一句文案，后者空着就是空列表页，不塞演示数据。
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'home/new_songs_tab.dart';
import 'home/playlists_tab.dart';
import 'home/singers_tab.dart';
import 'home/toplists_tab.dart';
import 'song_list_page.dart';

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

              // 两张入口卡（2026-10-11 取代原来那张「随便听一下」整行大卡）。
              //
              // 不再用 `st.library.isNotEmpty` 当门槛：猜你想听现在是从
              // QQ 音乐在线组歌，空库也推得出来；最近听过空着点进去是一页
              // 诚实的空态，比两行卡片凭空消失更好解释（也更好找到）。
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: EntryCard(
                        icon: Icons.auto_awesome_rounded,
                        title: '猜你想听',
                        subtitle: st.guessing
                            ? '正在按口味挑歌…'
                            : '按你常听的歌手在线组一批',
                        color: Tokens.brand,
                        busy: st.guessing,
                        onTap: () => _guessForYou(context, st),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: EntryCard(
                        // 沿用「最近听」在个人页时的青色，换入口不换识别色
                        icon: Icons.history_rounded,
                        title: '最近听过',
                        subtitle: '${st.recentlyPlayed.length} 首',
                        color: const Color(0xFF0EA5A4),
                        // 卡片只负责进列表，不在首页直接起播——
                        // 「看一眼上次听到哪」和「开始放」是两件事。
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SongListPage(
                              title: '最近听过',
                              songs: st.recentlyPlayed,
                              st: st,
                              emptyText: '还没有播放记录，先挑一首听听',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
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

/// 点「猜你想听」：让 AppState 去组歌起播，失败就如实报一句。
///
/// 成功时什么都不弹——歌已经开始放了自己就是最强的反馈，再叠一条
/// 「已为你找到 30 首歌」只会盖在迷你播放条上。
///
/// ⚠️ `await` 之后必须判 `context.mounted`：拉推荐要两三秒，
/// 这期间用户完全可能已经切走 tab 甚至退掉了这页。
Future<void> _guessForYou(BuildContext context, AppState st) async {
  final err = await st.guessForYou();
  if (err == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(err)));
}
