/// 首页两张入口卡（猜你想听 / 最近听过）的形态测试。
///
/// ## 钉住的三件事
/// 1. 两张卡都在，旧的整行「随便听一下」大卡不再出现；
/// 2. 卡片**不因为「本地没有数据」而消失**——旧的 `_ShuffleCard` 外面包着
///    `if (st.library.isNotEmpty)`，没歌就没有入口。「最近听过」在没有播放
///    记录时也必须照样渲染（副标题 0 首），这条用 mock 模式（统计恒空）验证；
/// 3. 点「最近听过」只进列表页，**不在首页直接起播**（看一眼和开始放是两件事）；
///    点「猜你想听」拉不到时给一句 SnackBar，不装成功。
///
/// 走 `Shell` 而不是裸 `HomeScreen`：后者是 `Container`，需要 `MaterialApp`
/// + `Navigator` + `Overlay` 齐备才能渲染完整并跳转。
///
/// ## ⚠️ 本文件刻意不碰 sqflite
/// `testWidgets` 跑在 fake-async 区里，只要有一条活的 sqflite 连接（ffi
/// 后台 isolate）在场，测试体就算跑完也**永远不会 complete**——表现是
/// 「did not complete」而不是断言失败（实测见 git 历史 2026-10-11）。
/// 所以这里全部用 `AppState()`（mock 数据层，qq == null）：卡片形态与
/// 跳转契约不需要真库就能验证；「入库 → 统计 → 最近听过」那条链路由
/// test/play_stats_test.dart 与 test/online_play_test.dart 在纯 test()
/// 里覆盖。
library;

import 'package:audora_music/main.dart';
import 'package:audora_music/screens/song_list_page.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:audora_music/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpShell(WidgetTester tester, AppState st) async {
  await tester.pumpWidget(AnimatedBuilder(
    animation: st,
    builder: (context, _) => MaterialApp(
      home: Shell(
        st: st,
        messengerKey: GlobalKey<ScaffoldMessengerState>(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 收尾两件事：先把树拆掉，再 dispose 状态。
///
/// AppState 会起 1 秒周期的播放 ticker，tearDown 跑在「无悬挂 Timer」不变量
/// 检查**之后**，所以必须在这里、测试体内部把它关掉。
Future<void> _teardown(WidgetTester tester, AppState st) async {
  await tester.pumpWidget(const SizedBox.shrink());
  st.dispose();
}

void main() {
  testWidgets('首页两张卡都在，旧的「随便听一下」大卡已删除', (tester) async {
    final st = AppState();
    await _pumpShell(tester, st);

    expect(find.text('猜你想听'), findsOneWidget);
    expect(find.text('最近听过'), findsOneWidget);
    expect(find.text('随便听一下'), findsNothing);
    expect(find.byIcon(Icons.shuffle_rounded), findsNothing);

    await _teardown(tester, st);
  });

  testWidgets('没有播放记录时两张卡照样渲染，副标题诚实写 0 首',
      (tester) async {
    final st = AppState();
    // 前置条件：mock 模式下没有任何播放统计
    expect(st.recentlyPlayed, isEmpty);

    await _pumpShell(tester, st);

    // 旧逻辑「没内容就不给入口」不能复活在这里：卡片必须在，
    // 用户才知道这个功能存在、点进去能看到空态说明。
    expect(find.text('猜你想听'), findsOneWidget);
    expect(find.text('最近听过'), findsOneWidget);

    // 读卡片字段而不是 find.text('0 首')——Shell 用 IndexedStack，
    // 「我的」页的收藏副标题是同一批文案，按文案找会撞。
    final recent =
        tester.widget<EntryCard>(find.widgetWithText(EntryCard, '最近听过'));
    expect(recent.subtitle, '0 首');
    expect(recent.onTap, isNotNull, reason: '空记录也要可点，进去看空态');

    await _teardown(tester, st);
  });

  testWidgets('点「最近听过」只进列表页，不在首页起播', (tester) async {
    final st = AppState();
    // ⚠️ mock 模式在构造时就预填了队列（_index = 4），所以这里不能断言
    // 「没有在播的歌」，只能断言「点完以后队列**没被动过**」——这才是
    // 「卡片不是快捷播放」的准确说法。
    final before = st.current?.key;
    final queueLen = st.queue.length;
    await _pumpShell(tester, st);

    await tester.tap(find.text('最近听过'));
    await tester.pumpAndSettle();

    expect(find.byType(SongListPage), findsOneWidget,
        reason: '卡片是入口，不是快捷播放');
    // mock 模式没有统计 → 列表页给出空态文案，而不是空白或报错
    expect(find.text('还没有播放记录，先挑一首听听'), findsOneWidget);
    expect(st.current?.key, before);
    expect(st.queue, hasLength(queueLen));

    await _teardown(tester, st);
  });

  testWidgets('点「猜你想听」拉不到时给一句 SnackBar，且不起播、转圈收掉',
      (tester) async {
    // qqCatalog 未注入 = 数据层没接上，推荐一条也拉不到
    final st = AppState();
    final before = st.current?.key;
    final queueLen = st.queue.length;
    await _pumpShell(tester, st);

    await tester.tap(find.text('猜你想听'));
    await tester.pumpAndSettle();

    expect(find.text('数据层未接入'), findsOneWidget);
    // 失败就是失败：不许把用户原来的队列换掉
    expect(st.current?.key, before);
    expect(st.queue, hasLength(queueLen));
    expect(st.guessing, isFalse, reason: '失败后转圈必须收掉，不能永远转着');

    await _teardown(tester, st);
  });
}
