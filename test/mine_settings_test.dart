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

import 'package:audora_music/main.dart';
import 'package:audora_music/screens/settings_sheets.dart';
import 'package:audora_music/services/settings/settings_store.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:audora_music/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  testWidgets('设置区收成 5 行：音质偏好 / 歌曲目录 / B站账号 / 诊断日志 / 清除播放记录',
      (tester) async {
    final st = AppState(); // repo = null，走 mock；设置区内容与 repo 无关

    await _pumpShell(tester, st);
    st.setTab(1);
    await tester.pumpAndSettle();

    // 已下线的三项：曲库是「点歌即播」的自动产物，没有可手动维护的状态；
    // 导入入口已被音乐页目录点歌取代。
    expect(find.text('曲库状态'), findsNothing);
    expect(find.text('重新加载曲库'), findsNothing);
    expect(find.text('导入歌曲（QQ音乐）'), findsNothing);

    // 2026-10-11 用户反馈「设置太多」：四项各自一行的确太挤。
    // 现在两两收进一个入口，**入口变少但偏好一个没少**（下面两个用例分别钉住）。
    expect(find.text('在线音质'), findsNothing, reason: '收进「音质偏好」弹窗里了');
    expect(find.text('下载音质'), findsNothing);
    expect(find.text('本地目录'), findsNothing, reason: '收进「歌曲目录」子页面里了');
    expect(find.text('下载目录'), findsNothing);

    await _findSettingRow(tester, st, '音质偏好');
    await _findSettingRow(tester, st, '歌曲目录');
    await _findSettingRow(tester, st, '清除播放记录');
    // C1：扫码登录入口（登录态解锁 192K / Hi-Res 与更宽配额）
    await _findSettingRow(tester, st, 'B站账号');
    // 诊断日志：匹配链路与崩溃的回看入口
    await _findSettingRow(tester, st, '诊断日志');

    // 合并行右侧必须展示**两个真实生效**的档位（写成硬编码就是假开关）。
    expect(
      find.text('在线 ${st.onlineQuality.chip} · 下载 ${st.downloadQuality.chip}'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('音质偏好弹窗里两条上限都在，改下载不动在线', (tester) async {
    final st = AppState();
    await _pumpShell(tester, st);
    st.setTab(1);
    await tester.pumpAndSettle();

    await tester.tap(find.text('音质偏好'));
    await tester.pumpAndSettle();

    // 「合并入口」不等于「合并偏好」：两档必须还能各选各的，
    // 否则「在线省流量、下载留最好」这个需求就没了（当初拆开的理由）。
    expect(find.text('在线音质'), findsOneWidget);
    expect(find.text('下载音质'), findsOneWidget);

    final onlineBefore = st.onlineQuality;
    // 下载那一节排在下面，小屏测试画布上要先滚进视口
    final downloadOption = find.text('标准 132Kbps').last;
    await tester.ensureVisible(downloadOption);
    await tester.pumpAndSettle();
    await tester.tap(downloadOption);
    await tester.pumpAndSettle();

    expect(st.downloadQuality, QualityPreference.medium);
    expect(st.onlineQuality, onlineBefore,
        reason: '下载档改了不该把在线档一起拖下去');
    // 弹窗不关：还要接着改另一条
    expect(find.byType(QualityPrefsSheet), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('歌曲目录子页面给出两个目录与扫描入口，未设置时不出现「清除」',
      (tester) async {
    final st = AppState();
    await _pumpShell(tester, st);
    st.setTab(1);
    await tester.pumpAndSettle();

    await _findSettingRow(tester, st, '歌曲目录');
    await tester.tap(find.text('歌曲目录'));
    await tester.pumpAndSettle();

    expect(find.text('本地目录'), findsOneWidget);
    expect(find.text('下载目录'), findsOneWidget);
    expect(find.text('扫描手机音乐'), findsOneWidget);
    // 没设过的目录没有可清的东西，露一个「清除」只会让人以为设过了
    expect(find.text('清除'), findsNothing);
    expect(find.text('未设置（全盘）'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('点目录一行必须有反馈：不支持的平台上如实说明，不能没反应', (tester) async {
    // 带 SettingsStore 构造：否则 pick 第一步就停在「设置存储未接入」，
    // 测不到真正要测的那条平台判断。
    SharedPreferences.setMockInitialValues(const {});
    final st = AppState(settings: await SettingsStore.open());
    await _pumpShell(tester, st);
    await _findSettingRow(tester, st, '歌曲目录');
    await tester.tap(find.text('歌曲目录'));
    await tester.pumpAndSettle();
    // 非 Android（测试环境）上点这一行 = 一句解释，而不是没反应
    await tester.tap(find.text('本地目录'));
    await tester.pumpAndSettle();

    // 真机缺陷（2026-10-11）：Android 上 chooser 被系统秒关，Dart 只收到
    // 「用户取消」→ 全程零反馈，用户报的就是「点击无反应」。所以这一条
    // 断言的是**必须有可见反馈**，而不特指哪一种。
    expect(find.textContaining('不支持选择系统目录'), findsOneWidget);
    expect(find.text('未设置（全盘）'), findsOneWidget,
        reason: '没成功就不该偷偷改掉状态');

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('收藏卡片点进去必须看到歌（真机：写着 1 首却是「暂无内容」）',
      (tester) async {
    final st = AppState(); // mock 模式预置了几个红心
    await _pumpShell(tester, st);
    st.setTab(1);
    await tester.pumpAndSettle();

    expect(st.likedCount, greaterThan(0));
    await tester.tap(find.widgetWithText(InkWell, '收藏'));
    await tester.pumpAndSettle();

    // 列表页自己现查一批歌（loader），不吃「点卡片那一刻的内存快照」——
    // 快照正是旧实现丢歌的地方（曲库只装最近 500 行）。
    expect(find.text('暂无内容'), findsNothing);
    expect(find.text('收藏'), findsWidgets); // 标题 + 卡片
    expect(find.byType(SongRow), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('「我的」页不再有「最近听」入口（已移到首页卡片）', (tester) async {
    final st = AppState();
    await _pumpShell(tester, st);
    st.setTab(1);
    await tester.pumpAndSettle();

    // 入口与统计数字一起挪走：留一个点不动的数字，比不留更让人找半天。
    // ⚠️ 只断言 '最近听' 这个旧标签——Shell 用 IndexedStack，首页的
    // 「最近听过」卡片也在树里，断言它 findsNothing 是假失败。
    expect(find.text('最近听'), findsNothing);
    expect(find.widgetWithText(InkWell, '最近听'), findsNothing);
    // 收藏仍是入口
    expect(find.widgetWithText(InkWell, '收藏'), findsOneWidget);
    // 第二期的「本地」回到了这一行右边：进去是本地 / 下载两个并列功能
    expect(find.widgetWithText(InkWell, '本地'), findsOneWidget);
    expect(find.text('下载'), findsNothing,
        reason: '下载不在这一层，它在「本地」里面');

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  testWidgets('改下载音质不会动在线音质（两条偏好各自独立）', (tester) async {
    final st = AppState();
    await _pumpShell(tester, st);

    final before = st.onlineQuality;
    await st.setDownloadQuality(QualityPreference.medium);
    await tester.pumpAndSettle();

    expect(st.downloadQuality, QualityPreference.medium);
    expect(st.onlineQuality, before, reason: '下载档改了不该把在线档一起拖下去');
    // 下载档只管「以后落盘用什么码率」，不碰正在播放的这一次拉流
    expect(st.downloadQualityCeilingId, QualityPreference.medium.id);

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
