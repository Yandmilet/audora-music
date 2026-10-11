/// 播放页底部功能条上「下载」那颗按钮的位置与点击行为。
///
/// ## 为什么单独钉位置
/// 需求写得很具体：下载要放在「定时」和「音效」中间。这种顺序约束不会因为
/// 少一个按钮而报错，也不会因为哪天有人插到末尾而崩——只会在真机上看起来
/// 不对。所以这里用**水平坐标**断言顺序，而不是只断言按钮存在。
///
/// ## 为什么这里不打真实音频后端
/// FootActions 只读 AppState 的展示字段；下载状态由 DownloadBox 管，
/// 它的完整状态机在 test/download_box_test.dart 里测。这里只验形态：
/// 五颗按钮、顺序对、点不动的时候要说得出原因（mock 模式没数据层）。
library;

import 'package:audora_music/screens/player/player_controls.dart';
import 'package:audora_music/services/diag/diag_log.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, AppState st) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const Expanded(child: SizedBox.shrink()),
            FootActions(st: st),
          ],
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

double _x(WidgetTester tester, String label) =>
    tester.getCenter(find.text(label)).dx;

void main() {
  // DiagLog 是单例：点「下载」被拒（mock 模式没数据层）会走 DiagLog.w，
  // 留下一个 2 秒的 flush 计时器，testWidgets 的「不许残留 Timer」不变量
  // 就把整条用例判红。前后各复位一次，与 diag_log_test.dart 同一写法。
  setUp(() => DiagLog.instance.resetForTest());
  tearDown(() => DiagLog.instance.resetForTest());

  testWidgets('底部功能条五颗按钮，下载在定时与音效之间', (tester) async {
    final st = AppState();
    await _pump(tester, st);

    expect(find.text('播放队列'), findsOneWidget);
    expect(find.text('定时关闭'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('音源'), findsOneWidget);

    // 从左到右：定时 < 下载 < 音效 —— 用户点名的那一段顺序
    expect(_x(tester, '定时关闭'), lessThan(_x(tester, '下载')));
    expect(_x(tester, '下载'), lessThan(_x(tester, '音效')));

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('点下载但数据层没接 → 一句原因，不静默不装成功', (tester) async {
    final st = AppState();
    await _pump(tester, st);

    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();

    expect(find.text('数据层未接入'), findsOneWidget);
    // 没有下载在进行 → 按钮仍应是「下载」而不是卡在百分比
    expect(find.text('下载'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    // 清计时器必须发生在**测试体内**：testWidgets 的「不许残留 Timer」检查
    // 跑在 tearDown 之前，只在 tearDown 里复位等于没做。
    DiagLog.instance.resetForTest();
    st.dispose();
  });
}
