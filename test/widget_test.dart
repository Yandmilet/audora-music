// Audora 2.0 UI 冒烟测试：验证应用外壳能正常渲染。
//
// ## 为什么不直接 pumpWidget(AudoraApp)
// `AudoraApp` 现在会在 initState 里异步开 SQLite（走平台通道），
// 在 widget test 环境下平台通道不存在，会导致启动失败。
// 所以这里改为**直接测 Shell**（UI 外壳），把 AppState 用 mock 数据构造
// （AppState(repo: null) 就是「数据层未接入」模式，全部走 mock）。
//
// 真正的启动链路（开库 → 装配 → 加载曲库）由 db_test 覆盖数据库部分，
// 端到端则靠真机验证。

import 'package:audora_music/main.dart';
import 'package:audora_music/screens/player_screen.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('应用外壳渲染并可在底部 tab 间切换', (WidgetTester tester) async {
    final st = AppState(); // repo 为 null → 走 mock 兜底

    await tester.pumpWidget(MaterialApp(home: Shell(st: st, messengerKey: GlobalKey<ScaffoldMessengerState>())));

    // 1. 默认停在「音乐」tab
    expect(find.text('音乐'), findsWidgets);
    expect(find.text('我的'), findsWidgets);

    // 2. 主页关键入口
    expect(find.byIcon(Icons.search_rounded), findsWidgets);

    // 3. 切到「我的」
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    // 未触发异常即为通过
    expect(tester.takeException(), isNull);

    st.dispose();
  });

  testWidgets('未接入数据层时首页不崩，目录 tab 显示「数据层未接入」', (WidgetTester tester) async {
    final st = AppState();
    await tester.pumpWidget(MaterialApp(home: Shell(st: st, messengerKey: GlobalKey<ScaffoldMessengerState>())));
    await tester.pumpAndSettle();

    // 浏览优先形态下首页不再展示 mock 曲库，而是目录 tabs。
    // repo == null 时 qq 为 null，目录视图如实显示加载失败（含原因），
    // 而不是塞假数据——这正是空态契约在 UI 层的延伸。
    expect(st.usingMock, isTrue);
    expect(st.qq, isNull);
    expect(find.text('歌手库'), findsOneWidget);
    expect(find.text('歌单推荐'), findsOneWidget);
    expect(find.text('榜单'), findsOneWidget);
    expect(find.text('新歌推荐'), findsOneWidget);
    expect(find.text('加载失败'), findsWidgets);
    expect(tester.takeException(), isNull);

    st.dispose();
  });

  testWidgets('搜索页可打开并且输入不崩', (WidgetTester tester) async {
    final st = AppState();
    await tester.pumpWidget(MaterialApp(home: Shell(st: st, messengerKey: GlobalKey<ScaffoldMessengerState>())));

    st.openSearch();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // 输入关键词（走 mock 过滤路径，因为未接入 repo）
    st.setQuery('周杰伦');
    // setQuery 在 mock 路径下是同步过滤，pump 一次即可
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    st.dispose();
  });

  testWidgets('播放页开关为路由 push/pop，不销毁次级页面栈（回归：返回回不到榜单详情）',
      (WidgetTester tester) async {
    final st = AppState();
    await tester.pumpWidget(MaterialApp(
      home: Shell(st: st, messengerKey: GlobalKey<ScaffoldMessengerState>()),
    ));
    await tester.pumpAndSettle();

    // 模拟榜单/歌单详情这类压在根 Navigator 上的次级页面
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute(
      builder: (_) => const Scaffold(body: Text('次级页面')),
    ));
    await tester.pumpAndSettle();

    // 次级页面里点悬浮迷你条打开播放页。
    // 旧实现这里先 popUntil(isFirst) 清栈 → 次级页销毁，关闭播放页后
    // 只能回到根页面（真机实测「返回固定在歌手库」）。
    st.openPlayer();
    await tester.pumpAndSettle();
    // mock 模式下队列有预置歌，播放页是完整界面；只验证播放页已在栈顶
    expect(find.byType(PlayerScreen), findsOneWidget);

    // 关闭播放页 → 应逐级返回到之前的次级页面，而不是根页面
    st.closePlayer();
    await tester.pumpAndSettle();
    expect(find.text('次级页面'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);

    st.dispose();
  });
}
