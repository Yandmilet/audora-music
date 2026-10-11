/// 播放页「返回落点」契约测试。
///
/// ## 回归对象
/// 真机实测的「返回固定在歌手库」。它有**两个互相独立的成因**，本文件都锁：
///
/// 1. **路由层**：旧实现用 `popUntil(isFirst)` 清路由栈，把次级页一起销毁，
///    关闭播放页后落到一级视图。（本文件前四条用例覆盖）
/// 2. **主内容层**（2026-09-30 真机逐帧定位）：`ExitConfirm` → `SwipeBack`
///    在 `enabled` 翻转时改变了返回的 widget **类型**（`GestureDetector` ↔
///    `Stack`），Flutter 无法原地更新 element，只能卸载重建整棵子树。
///    Shell 整个 body 都在里面，于是 `HomeScreen` 的 `DefaultTabController`
///    被重建为 `initialIndex: 0`：从「歌单推荐」进歌单、点歌、进播放页、
///    再逐级右滑返回后，落到的是「歌手库」而不是歌单推荐。
///    修法：`SwipeBack` 无论 `enabled` 取值都返回同一形状的树，只用
///    「回调置空」来代替提前 return。（本文件后两条用例覆盖）
///
/// ## 为什么在 widget_test.dart 之外再写一份
/// `test/widget_test.dart` 里已有一条同名回归，但它只覆盖
/// **`st.closePlayer()` 直调**这一条入口，且用
/// `const Scaffold(body: Text('次级页面'))` 假页面充当次级页。
/// 真实链路上有三个它抓不到的盲区，本文件逐个补上：
///
/// 1. **系统返回键**：真机上关播放页主要靠返回键 / 系统手势，走的是
///    `Navigator.maybePop` → `_PlayerRoute` 的 `PopScope(canPop: false)`
///    → `closePlayer()`，与直调 `closePlayer()` 是两条不同入口。
/// 2. **页内右滑**：`SwipeBack.onBack` → `closePlayer()` 是第三条入口。
/// 3. **次级页换真实 `BrowseScreen`**：它是 StatefulWidget，
///    `initState` 里建 Future、列表带滚动位置。「落点对了，但列表重新
///    加载过、滚动归零」这类失败模式，用假 Scaffold 测不出来。
///
/// 另外接上**真实的 [SubRouteObserver]**（而不是在此复制一份实现）来锁
/// [AppState.subPageOpen] 的语义：它是悬浮迷你条显隐的唯一依据，计数一旦
/// 错位，用户看到的就是「次级页上没有迷你条」或「一级页上多出一条悬浮条」。
///
/// 不直接 pump `AudoraApp`：它在 `initState` 里异步开 SQLite（走平台通道），
/// widget test 环境下平台通道不存在——这与 `widget_test.dart` 的取舍一致。
library;

import 'package:audora_music/main.dart';
import 'package:audora_music/screens/browse_screen.dart';
import 'package:audora_music/screens/home_screen.dart';
import 'package:audora_music/screens/player_screen.dart';
import 'package:audora_music/services/qqmusic/qqmusic_dto.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:audora_music/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 目录页标题（同时充当「次级页可见」的锚点）。
///
/// 断言可见性靠它而不是 `find.byType(BrowseScreen)`：finder 默认
/// `skipOffstage: true`，播放页（`opaque: true`）压栈时列表页会被置为
/// offstage —— 标题找不到，正说明它「被盖住」而不是「被销毁」。
const _kTitle = '测试榜单';

/// 造 n 首目录假歌。字段齐到 `BrowseSongRow` 渲染所需（标题 / 歌手 / 时长）。
List<QQSongMeta> _fakeCatalog(int n) => List.generate(
      n,
      (i) => QQSongMeta(
        songMid: 'test_mid_$i',
        title: '第${i + 1}首测试歌曲',
        artists: const ['测试歌手'],
        album: '测试专辑',
        albumMid: 'test_amid_$i',
        interval: 200 + i,
      ),
    );

/// pump 出「Shell + 根 Navigator」的最小真实外壳，并挂上真实的次级路由观察者。
///
/// ⚠️ 必须照 `AudoraApp` 那样把整棵 `MaterialApp` 放进 [AnimatedBuilder] 里监听
/// `st`：Shell 的 `ExitConfirm.enabled` 读的正是 `st.playerOpen / searchOpen`，
/// 而 `ScaffoldMessengerKey` 与观察者实例在真实 App 里都是**稳定**字段
/// （`late final` / `final`），这里同样只能在 builder 外建一次。
///
/// 三者缺一，测试就与真机不同构——实测过：不监听 `st` 时 `openPlayer()`
/// 不会让 `enabled` 翻转，主内容层被重建那个 bug 在本文件里根本复现不出来，
/// 「开关播放页不重建主内容层」就成了一条永远绿的假测试。
Future<AppState> _pumpShell(WidgetTester tester) async {
  final st = AppState(); // repo == null → mock 兜底，队列有预置歌，播放页可完整渲染
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  final observer = SubRouteObserver(st.setSubPageOpen);
  await tester.pumpWidget(AnimatedBuilder(
    animation: st,
    builder: (context, _) => MaterialApp(
      home: Shell(st: st, messengerKey: messengerKey),
      navigatorObservers: [observer],
    ),
  ));
  await tester.pumpAndSettle();
  return st;
}

/// push 一个真实的 `BrowseScreen`（50 首，可滚动）当作次级页。
Future<void> _pushCatalog(WidgetTester tester, AppState st) async {
  tester.state<NavigatorState>(find.byType(Navigator)).push(
        MaterialPageRoute<void>(
          builder: (_) => BrowseScreen(
            st: st,
            title: _kTitle,
            showRank: true,
            loader: () async => _fakeCatalog(50),
          ),
        ),
      );
  await tester.pumpAndSettle();
}

/// 当前目录列表的滚动偏移（`BrowseScreen` 内部只有 ListView 一个 Scrollable）。
double _listOffset(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(BrowseScreen),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position.pixels;
}

void main() {
  testWidgets('系统返回关闭播放页后，落回列表页且滚动位置原样保留',
      (WidgetTester tester) async {
    final st = await _pumpShell(tester);
    await _pushCatalog(tester, st);

    // 次级页已打开 → 悬浮迷你条的依据为真
    expect(st.subPageOpen, isTrue);

    // 把列表滚到中段，制造一个非零滚动位置
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final offsetBefore = _listOffset(tester);
    expect(offsetBefore, greaterThan(0));

    // 次级页里打开播放页（真机路径：点底部迷你条 / 悬浮迷你条）
    st.openPlayer();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    // 播放页不透明全屏 → 列表页被 offstage（盖住），而非销毁
    expect(find.text(_kTitle), findsNothing);

    // 系统返回键。WidgetsApp.didPopRoute 的内核就是 Navigator.maybePop，
    // 栈顶是 _PlayerRoute 时先命中它自己的 PopScope → closePlayer()。
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    // ★ 落点是刚才那个列表页，不是一级首页
    expect(find.text(_kTitle), findsOneWidget);
    expect(find.byType(BrowseScreen), findsOneWidget);
    // 滚动位置原样保留 —— 证明返回的是同一个 State，不是重新 load 的列表
    expect(_listOffset(tester), moreOrLessEquals(offsetBefore, epsilon: 0.5));
    // 仍在次级路由之上，迷你条依据不变
    expect(st.subPageOpen, isTrue);
    expect(tester.takeException(), isNull);

    st.dispose();
  });

  testWidgets('页内右滑关闭播放页同样逐级返回，不销毁次级页',
      (WidgetTester tester) async {
    final st = await _pumpShell(tester);
    await _pushCatalog(tester, st);

    st.openPlayer();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    // 从顶栏区域起手：PageView（歌曲 / 歌词）自己吃水平手势，
    // 落在它上面会先被 PageView 抢走，测不到 SwipeBack 的真实行为。
    await tester.dragFrom(const Offset(220, 40), const Offset(260, 0));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text(_kTitle), findsOneWidget);
    expect(tester.takeException(), isNull);

    st.dispose();
  });

  testWidgets('播放页压栈会占用 subPageOpen，悬浮条靠 playerOpen 门控兜住',
      (WidgetTester tester) async {
    final st = await _pumpShell(tester);

    st.openPlayer();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    // ⚠️ 真实语义：subPageOpen = 「有任意整页压在 Shell 上」。播放页是
    // PageRouteBuilder（PageRoute，且非 isFirst），同样被计入深度，
    // 所以这里是 true。
    // 它当前**不影响可见行为**——悬浮迷你条的显示条件是
    // `!playerOpen && (subPageOpen || searchOpen)`（main.dart:366-368），
    // 播放页打开时已被 playerOpen 挡住。
    // 这条断言把这个耦合显式化：哪天有人去掉那个门控、或改成播放页不计数，
    // 它会立刻失败，而不是让悬浮条悄悄盖到播放页上。
    expect(st.subPageOpen, isTrue);

    st.closePlayer();
    await tester.pumpAndSettle();
    // 关闭后深度归零 → 回到「一级页」分支，用 Shell 内嵌迷你条
    expect(st.subPageOpen, isFalse);

    st.dispose();
  });

  testWidgets('播放页上压弹层时关闭，走 removeRoute 分支也不丢次级页',
      (WidgetTester tester) async {
    final st = await _pumpShell(tester);
    await _pushCatalog(tester, st);

    st.openPlayer();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    // 在播放页上叠一个弹层（真实路径：音源详情 / 手动搜索 / 音质偏好）。
    // 此后播放页不再是栈顶 —— 正是 _PlayerRouteSync 走 removeRoute 的前提。
    showModalBottomSheet<void>(
      context: tester.element(find.byType(PlayerScreen)),
      builder: (_) => const SizedBox(height: 120),
    );
    await tester.pumpAndSettle();

    st.closePlayer();
    await tester.pumpAndSettle();

    // 关键：removeRoute 必须把播放页（及其上方弹层）一并摘掉，
    // 且不能连带把下面的次级页一起吃掉。
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text(_kTitle), findsOneWidget);
    expect(find.byType(BrowseScreen), findsOneWidget);
    // 深度计数不能错位：用户仍在次级页上，迷你条依据必须保持为真
    expect(st.subPageOpen, isTrue);
    expect(tester.takeException(), isNull);

    st.dispose();
  });

  testWidgets('开关播放页不重建主内容层（音乐页 tab 不会被重置回歌手库）',
      (WidgetTester tester) async {
    final st = await _pumpShell(tester);

    // 探针：HomeScreen 里 TabBarView 的 State 实例。
    // 主内容层一旦被卸载重建，实例必然换新——同一时刻
    // DefaultTabController 也会退回 initialIndex 0（= 歌手库）。
    final tabView = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byType(TabBarView),
    );
    expect(tabView, findsOneWidget);
    final before = tester.state<State>(tabView);

    // 真机路径：点底部迷你条进播放页 → ExitConfirm.enabled 由 true 翻 false
    st.openPlayer();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);

    st.closePlayer();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);

    // ★ 同一个 State 实例 = 主内容层没被重建 = tab / 滚动位置 / 已加载的
    //   远端目录数据都还在。（修复前这里会失败：实例换新，tab 退回歌手库）
    final after = tester.state<State>(tabView);
    expect(identical(before, after), isTrue);

    st.dispose();
  });

  testWidgets('SwipeBack 切换 enabled 只改手势回调，不重建子树',
      (WidgetTester tester) async {
    // 机制级锁定：这是上一条的根因。只要 SwipeBack 在 enabled=false 时
    // 提前 `return widget.child`（改变 widget 类型），子树就会被重建。
    Future<void> pump(bool enabled) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SwipeBack(
          enabled: enabled,
          onBack: () {},
          child: const _Probe(),
        ),
      ));
    }

    await pump(true);
    final s1 = tester.state<State>(find.byType(_Probe));

    // enabled 翻 false（真机路径：播放页 / 搜索页打开）
    await pump(false);
    final s2 = tester.state<State>(find.byType(_Probe));
    expect(identical(s1, s2), isTrue,
        reason: 'enabled=false 时不能改变返回的 widget 类型');

    // 再翻回 true（关闭播放页）
    await pump(true);
    final s3 = tester.state<State>(find.byType(_Probe));
    expect(identical(s1, s3), isTrue,
        reason: 'enabled=true 时同样不能重建子树');

    expect(tester.takeException(), isNull);
  });
}

/// 子树是否被重建的探针：只用来比 State 实例的同一性。
class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
