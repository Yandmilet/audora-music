/// 应用外壳与常驻路由基建：Shell（底部 tab + 迷你条 + 搜索页叠加层）、
/// 播放页路由同步器（状态 ↔ 路由的唯一桥梁）、匹配状态条、次级路由观察者。
///
/// ## 为什么从 main.dart 拆出来（P3 结构整理）
/// main.dart 里「启动流程（main / AudoraApp / boot 占位 / 主题）」与
/// 「常驻 UI 骨架」混在一个千行文件里——改启动链路要滚过整个 Shell build，
/// 改 Shell 又要滚过 boot 代码。拆分是纯代码搬运，行为零改动：
/// main.dart 通过 `export 'shell.dart'` 继续对外暴露 Shell /
/// SubRouteObserver，测试与调用方的 import 路径不变。
///
/// [_ShellState] / [_TabItem] / [_PlayerRouteSync] 保持私有——
/// 它们只被 Shell 自己使用，跨文件反而不该可见。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'screens/mine_screen.dart';
import 'screens/player_screen.dart';
import 'screens/search_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 应用外壳：底部 tab + 迷你播放条 + 全屏播放页 + 搜索页
class Shell extends StatefulWidget {
  final AppState st;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  const Shell({
    super.key,
    required this.st,
    required this.messengerKey,
  });

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  AppState get st => widget.st;

  /// 上次「再滑退出」提示的时间（系统返回路径的二次确认计时）。
  /// 与 ExitConfirm 的窗口逻辑一致，但两者各自独立计时——
  /// 系统返回与页内右滑是两条不同的触发路径，混用一个计时器
  /// 反而会出现「页内滑一下 + 系统返回一下就退出」的怪异组合。
  DateTime? _lastExitHint;

  /// 「再次右滑退出」的二次确认提示。
  ///
  /// 用 SnackBar 而不是 Toast：
  ///   - SnackBar 自带滑动关闭、与 Material 风格一致
  ///   - 通过全局 messengerKey 弹出，能盖在所有叠加层之上
  /// 时长 1.4 秒——比 [ExitConfirm.window] 短一点点，给用户预留提前量。
  void _onExitHint() {
    final m = widget.messengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      const SnackBar(
        content: Text('再次右滑退出 Audora'),
        duration: Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _confirmExit() => SystemNavigator.pop();

  /// 系统返回手势/返回键（PopScope 拦截）。
  ///
  /// ## 为什么必须有这个
  /// 屏幕左缘的右滑是 Android 系统返回手势，不经过我们的 SwipeBack，
  /// 直接走 Navigator.maybePop。根路由（本 Shell）没有可弹的页面时，
  /// Flutter 默认调 [SystemNavigator.pop] —— App 整个退到桌面。所以必须在
  /// 根路由拦下返回事件，按层级分发：先关搜索页，最后才是两段式退出。
  ///
  /// 播放页已改为根 Navigator 上的路由（_PlayerRouteSync）：它是栈顶时，
  /// 系统返回先命中它自己的 PopScope（→ closePlayer），轮不到这里。
  /// playerOpen 分支仅作竞态兜底保留。
  /// 次级页面（榜单详情等）在栈顶时可正常 pop，同样不会到这里。
  Future<void> _onSystemBack(bool didPop) async {
    if (didPop) return;
    if (st.playerOpen) {
      st.closePlayer();
      return;
    }
    if (st.searchOpen) {
      st.closeSearch();
      return;
    }
    final now = DateTime.now();
    final last = _lastExitHint;
    if (last != null && now.difference(last) <= const Duration(seconds: 2)) {
      _lastExitHint = null;
      _confirmExit();
    } else {
      _lastExitHint = now;
      _onExitHint();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final song = st.current;

    // ExitConfirm（页内右滑的退出确认）只在主内容层武装：
    // 播放页 / 搜索页打开时必须禁用，那两层的右滑归各自的 SwipeBack 管。
    // —— enabled=false 时它完全不注册手势识别器，竞技场里没有它。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _onSystemBack(didPop),
      child: _PlayerRouteSync(
        st: st,
        child: Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      body: ExitConfirm(
        onFirstTrigger: _onExitHint,
        onConfirmExit: _confirmExit,
        enabled: !st.playerOpen && !st.searchOpen,
        child: Stack(
          children: [
            // 主内容
            Column(
              children: [
                Expanded(
                  child: SafeArea(
                    bottom: false,
                    child: IndexedStack(
                      index: st.tabIndex,
                      children: [
                        // 音乐页 = 目录浏览（歌手库/歌单/榜单/新歌）。
                        // 点歌即播（后台静默入库 + 按需匹配），没有导入入口。
                        HomeScreen(st: st),
                        MineScreen(st: st),
                      ],
                    ),
                  ),
                ),

                // 按需匹配的全局进度条（批量匹配已移除，匹配统一走播放页按需路径）。
                //
                // ## 为什么不能只放在「我的」页里
                // 匹配一首约 20 秒，用户点了播放往往就切到别的 tab 去干别的。
                // 进度只在一个页面里可见的话，切走就完全不知道还在不在跑
                // —— 这正是「感觉卡死」的来源。放在外壳层，任何 tab 都能看到。
                if (st.matchingOnDemand) MatchBanner(st: st),

                // 全局轻提示（播放失败 / 自动选源提示等）。
                // 必须放外壳层：用户在浏览列表点歌，不一定打开播放页，
                // 失败只写 playbackError 的话用户看到的是「点了没反应」。
                if (st.toast != null)
                  Material(
                    color: dark ? Tokens.surface2Dark : Tokens.surface2,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 15,
                              color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              st.toast!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: t.colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 迷你播放条（同样只订阅秒级进度，见 [AppState.posTick]）
                if (song != null)
                  ValueListenableBuilder<int>(
                    valueListenable: st.posTick,
                    builder: (_, __, ___) => MiniPlayer(
                      song: song,
                      playing: st.playing,
                      progress: st.progress,
                      onToggle: st.togglePlay,
                      onNext: st.next,
                      onTap: st.openPlayer,
                    ),
                  ),

                // 底部 tab
                SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    color: dark ? Tokens.surfaceDark : Tokens.surface,
                    child: Row(
                      children: [
                        _TabItem(
                          icon: Icons.library_music_outlined,
                          activeIcon: Icons.library_music_rounded,
                          label: '音乐',
                          active: st.tabIndex == 0,
                          onTap: () => st.setTab(0),
                        ),
                        _TabItem(
                          icon: Icons.person_outline_rounded,
                          activeIcon: Icons.person_rounded,
                          label: '我的',
                          active: st.tabIndex == 1,
                          onTap: () => st.setTab(1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // 搜索页（右滑入）。右滑关闭。
            // 播放页**不在**这一层——它已改为根 Navigator 上的路由（见
            // _PlayerRouteSync），压在搜索页/次级页面之上，关闭即逐级返回，
            // 不会像旧实现那样需要清空路由栈导致「返回回不到榜单详情」。
            AnimatedSlide(
              offset: st.searchOpen ? Offset.zero : const Offset(1, 0),
              duration: Tokens.dur,
              curve: Curves.easeOutCubic,
              child: st.searchOpen
                  ? SwipeBack(onBack: st.closeSearch, child: SearchScreen(st: st))
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// 播放页路由同步器：把 [AppState.playerOpen] 状态翻译成根 Navigator 的
/// push / pop。这是「状态 → 路由」的唯一桥梁。
///
/// ## 为什么播放页必须是路由而不是 Shell 里的 AnimatedSlide
/// 旧实现把播放页画在 Shell 内部，而榜单/歌单/歌手详情是压在根 Navigator
/// 上的路由——播放页永远被次级页面盖住，次级页面里打开播放页只能
/// `popUntil(isFirst)` 清空路由栈，**榜单详情页因此被销毁**：关闭播放页
/// 后回到的是音乐首页一级视图，而不是之前浏览的列表（真机实测的
/// 「返回固定在歌手库」）。改为路由后，播放页压在当前页面之上，
/// 关闭即逐级返回，路由栈与页面滚动位置原样保留。
///
/// ## 为什么仍保留 playerOpen 状态
/// 会话恢复（lastPlayerOpen，冷启动直接落在播放页）需要它；
/// 悬浮迷你条 / ExitConfirm / _onSystemBack 的门控也读它。
/// 两个方向的转换都在这里：
///   - openPlayer()（playerOpen true）→ push [_PlayerRoute]
///   - closePlayer()（playerOpen false）→ pop 该路由
/// 路由内部的返回路径（SwipeBack 右滑 / 系统返回 / 播放页关闭按钮）
/// 统一调 st.closePlayer()，由本同步器执行 pop，保证状态与路由永不脱节。
class _PlayerRouteSync extends StatefulWidget {
  final AppState st;
  final Widget child;

  const _PlayerRouteSync({required this.st, required this.child});

  @override
  State<_PlayerRouteSync> createState() => _PlayerRouteSyncState();
}

class _PlayerRouteSyncState extends State<_PlayerRouteSync> {
  Route<void>? _playerRoute;

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_sync);
    // 冷启动恢复：restoreSession 可能在首帧前已置 playerOpen=true，
    // 此时 Navigator 还没挂载，必须等首帧后再 push。
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    widget.st.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (widget.st.playerOpen && _playerRoute == null) {
      // push 前先登记，防止 notifyListeners 密集期间重复 push（连点迷你条）。
      _playerRoute = _PlayerRoute(widget.st);
      nav.push(_playerRoute!);
    } else if (!widget.st.playerOpen && _playerRoute != null) {
      final r = _playerRoute!;
      _playerRoute = null;
      // 播放页上面还压着弹层（音源面板 / 音质偏好等）时 isCurrent 为
      // false，pop 不到它——只能 removeRoute（无动画）。正常路径都是 pop。
      if (r.isCurrent) {
        nav.pop();
      } else {
        nav.removeRoute(r);
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 全屏播放页的路由形态：上滑入场 / 下滑退场，与旧 AnimatedSlide 手感一致。
///
/// PopScope 拦截系统返回但不直接 pop：统一走 st.closePlayer()，
/// 由 _PlayerRouteSync 执行 pop——否则路由弹了、状态还停在 playerOpen=true，
/// 迷你条 / 悬浮条的门控会全部错乱。
class _PlayerRoute extends PageRouteBuilder {
  _PlayerRoute(AppState st)
      : super(
          opaque: true,
          transitionDuration: Tokens.durSlow,
          reverseTransitionDuration: Tokens.durSlow,
          pageBuilder: (_, __, ___) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) st.closePlayer();
            },
            child: SwipeBack(
              onBack: st.closePlayer,
              child: PlayerScreen(st: st),
            ),
          ),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          ),
        );
}

/// 全局匹配状态条（所有 tab 都可见）。
///
/// 只服务**按需匹配**（首播一首还没匹配的歌）：一首、约 20 秒。
/// 必须全局可见——用户点了播放往往就切到别的 tab 了，没有反馈
/// 就只能看到「点了没反应」。
/// （原批量匹配状态已随「批量匹配音源」功能一起移除，匹配统一走播放页按需路径。）
class MatchBanner extends StatelessWidget {
  final AppState st;
  const MatchBanner({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Material(
      color: dark ? Tokens.surfaceDark : Tokens.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: null,
            minHeight: 2,
            backgroundColor: dark ? Tokens.lineDark : Tokens.line,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 6, 5),
            child: Row(
              children: [
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在匹配音源：${st.onDemandMatchTitle ?? ''}'
                        '（首次播放约需 20 秒）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = active ? Tokens.brand : t.colorScheme.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(active ? activeIcon : icon, size: 23, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
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

/// 次级路由观察者：判断「是否有**整页**压在 Shell 之上」。
///
/// ## 为什么不能直接用 canPop()
/// `showModalBottomSheet`（音源详情、手动搜索、音质偏好等弹层）也会往
/// Navigator 压入 `ModalBottomSheetRoute`。若只看 canPop()，用户在一级页
/// 打开一个弹层就会被误判成「在次级页面」，悬浮迷你条会盖在弹层上——
/// 这正是真机反馈的两个问题（播放页弹层、音质偏好弹层被迷你条干扰）。
///
/// ## 修正：只数 PageRoute 深度
/// 只有 `PageRoute`（MaterialPageRoute 等整页跳转）才计入深度；
/// `PopupRoute` 家族（ModalBottomSheetRoute / DialogRoute）不算。
/// 这样：一级页上的弹层 → 深度 0，无迷你条；次级页上的弹层 → 深度仍 1，
/// 迷你条保留（整页上下文没变）。
/// 公开而非私有：`test/player_route_return_test.dart` 必须挂上**同一个**
/// 观察者来锁死 [AppState.subPageOpen] 的语义（悬浮迷你条显隐的唯一依据）。
/// 测试里照抄一份实现等于没测真实逻辑——副本与产品代码分叉时测试照样绿。
class SubRouteObserver extends NavigatorObserver {
  SubRouteObserver(this._onChange);

  final void Function(bool subPageOpen) _onChange;

  int _pageDepth = 0;

  void _pushIfPage(Route? route) {
    if (route is PageRoute) _pageDepth++;
  }

  void _popIfPage(Route? route) {
    if (route is PageRoute && _pageDepth > 0) _pageDepth--;
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    // 初始路由（Shell）isFirst == true，不算「次级页面」；
    // 其余 PageRoute（含次级页再 push 的嵌套页）逐层计数。
    if (route is PageRoute && !route.isFirst) _pageDepth++;
    _report();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is PageRoute && !route.isFirst && _pageDepth > 0) _pageDepth--;
    _report();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (route is PageRoute && !route.isFirst && _pageDepth > 0) _pageDepth--;
    _report();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _popIfPage(oldRoute);
    _pushIfPage(newRoute);
    _report();
  }

  void _report() => _onChange(_pageDepth > 0);
}