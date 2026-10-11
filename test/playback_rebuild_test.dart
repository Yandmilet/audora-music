/// 秒级进度通道（[AppState.posTick]）的语义回归。
///
/// ## 缺陷原状（2026-09-30 定位）
/// `positionStream` 的回调里原本直接调 `notifyListeners()`。而
/// `notifyListeners()` 最主要的订阅方是 `main.dart` 根部那个**包住整个
/// `MaterialApp` 的 `AnimatedBuilder`** —— 于是只要在放歌，整棵树每秒
/// 就要重建好几次：
///
/// ```
/// MaterialApp → Shell → IndexedStack → HomeScreen → TabBarView → 4 个目录 tab
/// ```
///
/// 叠加刚改完的歌手库（100 行列表 + 每行一张网络头像）之后，真机表现就是
/// 用户反馈的「UI 切换卡顿迟滞」——切 tab、滑列表都在跟进度重建抢帧。
///
/// 修复口径：
///   * **秒级**推进 → 只发 [AppState.posTick]（由 `_position` 的 setter
///     随写随发），由播放页进度条 / 播放页歌词 / 迷你条各自
///     `ValueListenableBuilder` 订阅；
///   * **低频**事件（切歌 / 播放暂停 / 歌词文本替换）→ 照旧 `notifyListeners()`。
///
/// 下面第一个用例是本缺陷的**主回归**：它统计「AppState 的监听者被叫了几次」，
/// 这个数字就是整棵树的重建次数（根部 AnimatedBuilder 是它的订阅方）。
library;

import 'package:audora_music/main.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('播放推进不重建整棵树（只发秒级进度通道）', (WidgetTester tester) async {
    // repo == null：mock 曲库 + 无真实播放器 → 走 1 秒一跳的模拟计时器，
    // 这正好是测试里唯一能驱动「时间前进」的路径。
    final st = AppState();

    await tester.pumpWidget(MaterialApp(
      home: Shell(
        st: st,
        messengerKey: GlobalKey<ScaffoldMessengerState>(),
      ),
    ));
    await tester.pumpAndSettle();

    st.playQueue(st.library, 0);
    await tester.pump();
    expect(st.current, isNotNull, reason: 'mock 曲库应能起播');
    expect(st.duration, greaterThan(0), reason: '时长必须为正，否则计时器不推进');

    // 探针：`st` 的监听者 == main.dart 根部 `AnimatedBuilder(animation: st)`
    // 以及其他全局订阅者。这里用它的调用次数代表「整棵树重建」。
    var wholeTreeRebuilds = 0;
    var progressTicks = 0;
    st.addListener(() => wholeTreeRebuilds++);
    st.posTick.addListener(() => progressTicks++);

    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(st.position, greaterThan(0), reason: '时间应在推进（模拟计时器）');
    expect(progressTicks, greaterThan(0), reason: '秒级通道应随进度推送');
    expect(wholeTreeRebuilds, 0,
        reason: '播放推进不得触发全局通知——那会让整棵树每秒重建数次，'
            '正是「切换 tab / 滑动列表卡顿迟滞」的来源');

    st.dispose();
  });

  test('切歌等低频事件仍然通知全局（口径没有被改窄）', () {
    final st = AppState();
    addTearDown(st.dispose);

    st.playQueue(st.library, 0);

    var wholeTreeRebuilds = 0;
    st.addListener(() => wholeTreeRebuilds++);

    // 切歌是低频事件，语义未变：必须走全局通知，
    // 否则播放页标题、迷你条歌名都不会更新。
    st.playQueue(st.library, 1);

    expect(wholeTreeRebuilds, greaterThan(0));
  });

  test('进度通道与 position 始终一致：seek 不会漏发', () {
    final st = AppState();
    addTearDown(st.dispose);

    st.playQueue(st.library, 0);
    expect(st.duration, greaterThan(0));

    st.seekTo(0.5);

    expect(st.position, greaterThan(0));
    expect(st.posTick.value, st.position,
        reason: '进度条与歌词都订阅 posTick；落后于 position 就是「拖了不动」');
  });
}
