/// 「我的」页设置区形态的回归测试（不联网）。
///
/// ## 为什么单独测这个
/// 设置项是**反复被增删**的区域（批量匹配音源 → 曲库状态 / 重新加载曲库 /
/// 导入歌曲 都曾被移除）。真机上靠肉眼确认「哪一项还在」既慢又容易漏，
/// 这里用 widget test 把「应有的」和「已下线的」都钉住。
///
/// 走 `Shell` 而不是裸 `MineScreen`：后者是 `Container`，
/// 需要 `MaterialApp` + `Navigator` + `Overlay` 齐备才能渲染完整。
library;

import 'package:audora2/main.dart';
import 'package:audora2/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 切到「我的」tab 并滚到含指定文本的设置行
///
/// ⚠️ `Shell` 是 `StatelessWidget`，**自己不监听 AppState**——
/// 真实 app 里由 `main.dart` 的 `AnimatedBuilder(animation: st)` 驱动重建。
/// 所以测试必须用同样的包装（见 [_pumpShell]），否则 `setTab` 不会生效。
Future<Finder> _findSettingRow(
  WidgetTester tester,
  AppState st,
  String label,
) async {
  st.setTab(1);
  await tester.pumpAndSettle();

  final row = find.text(label);
  expect(row, findsOneWidget, reason: '设置区应有「$label」入口');
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  return row;
}

/// 按 main.dart 的真实结构包装 Shell（含状态监听）
Future<void> _pumpShell(WidgetTester tester, AppState st) async {
  await tester.pumpWidget(AnimatedBuilder(
    animation: st,
    builder: (context, _) =>
        MaterialApp(home: Shell(st: st, messengerKey: GlobalKey<ScaffoldMessengerState>())),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('设置区含音质偏好 / B站账号 / 诊断日志 / 清除播放记录', (tester) async {
    final st = AppState(); // repo = null，走 mock；设置区内容与 repo 无关

    await _pumpShell(tester, st);
    st.setTab(1);
    await tester.pumpAndSettle();

    // 已下线的三项：曲库是「点歌即播」的自动产物，没有可手动维护的状态；
    // 导入入口已被音乐页目录点歌取代。
    expect(find.text('曲库状态'), findsNothing);
    expect(find.text('重新加载曲库'), findsNothing);
    expect(find.text('导入歌曲（QQ音乐）'), findsNothing);

    // 保留的四项仍在，且「音质偏好」要显示真实生效的档位（不是硬编码文案）
    await _findSettingRow(tester, st, '音质偏好');
    await _findSettingRow(tester, st, '清除播放记录');
    // C1：扫码登录入口（登录态解锁 192K / Hi-Res 与更宽配额）
    await _findSettingRow(tester, st, 'B站账号');
    // 诊断日志：匹配链路与崩溃的回看入口
    await _findSettingRow(tester, st, '诊断日志');
    expect(find.text(st.quality.label), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('批量匹配音源入口已移除（匹配统一走播放页按需路径）', (tester) async {
    final st = AppState();
    await _pumpShell(tester, st);

    // 功能已下线：设置区不应再有「批量匹配音源」「导入后自动匹配音源」
    // （导入入口仍在，但它位于视口外，不在本测试断言范围内）
    expect(find.text('批量匹配音源'), findsNothing);
    expect(find.text('导入后自动匹配音源'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });
}
