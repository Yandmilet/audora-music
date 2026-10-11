/// 「本地」入口页与两份清单页的形态测试（不碰数据库）。
///
/// ## 钉住的是「隔开」这件事在 UI 上的形状
/// 产品要求（2026-10-11）：打开「本地」看到的是**两个并列功能**，
/// 本地 = 扫描手机自带歌曲，下载 = app 落盘的歌，两个目录互不混排。
/// 数据层的隔离由 `test/local_audio_test.dart` 钉，这里钉的是：
///   1. 入口页确实同时给出两块卡，且各自说得清是干什么的；
///   2. 点进去是两个不同标题的清单页，不是一页混合列表；
///   3. 空态各有各的话（没扫过 ≠ 没下载过）；
///   4. 扫描失败如实给文案，不静默、不装成「手机里没有歌」。
///
/// 全程用 mock 数据层（`AppState()`，repo == null）：清单恒空，
/// 正好验证空态文案；数据层的真实读写在存储层测试里覆盖。
library;

import 'package:audora_music/data/db/dao/local_audio_dao.dart';
import 'package:audora_music/screens/local_screens.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpHub(WidgetTester tester, AppState st) async {
  await tester.pumpWidget(MaterialApp(home: LocalHubPage(st: st)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('入口页两块卡并列，各自说清来源', (tester) async {
    final st = AppState();
    await _pumpHub(tester, st);

    // 「本地」出现两次是刻意的：页面标题 + 左边那张卡的标题（卡通向的
    // 就是那份清单，名字理应一样）。断言写成 findsOneWidget 会把这个
    // 正确形状判成失败。
    expect(find.text('本地'), findsNWidgets(2));
    expect(find.text('扫描手机自带歌曲'), findsOneWidget);
    expect(find.text('本 app 下载的歌曲'), findsOneWidget);
    expect(find.text('0 首'), findsNWidgets(2), reason: '两份清单各自计数');
    // 「为什么不合并」要写在页面上，否则用户会来问下载的歌去哪了
    expect(find.textContaining('互不混排'), findsOneWidget);

    st.dispose();
  });

  testWidgets('点「本地」进的是本地清单，扫描按钮在页上', (tester) async {
    final st = AppState();
    await _pumpHub(tester, st);

    await tester.tap(find.text('扫描手机自带歌曲'));
    await tester.pumpAndSettle();

    final page = tester.widget<LocalAudioPage>(
      find.byType(LocalAudioPage, skipOffstage: false).last,
    );
    expect(find.text('还没有扫描过手机里的歌曲'), findsOneWidget);
    expect(find.text('扫描手机音乐'), findsWidgets);
    expect(page.kind, LocalAudioKind.local);

    st.dispose();
  });

  testWidgets('点「下载」进的是下载清单，空态说的是下载', (tester) async {
    final st = AppState();
    await _pumpHub(tester, st);

    await tester.tap(find.text('本 app 下载的歌曲'));
    await tester.pumpAndSettle();

    expect(find.text('还没有下载的歌曲'), findsOneWidget);
    // 下载页没有扫描按钮——扫描是本地那一侧的动作
    expect(find.byTooltip('扫描手机音乐'), findsNothing);

    st.dispose();
  });

  testWidgets('数据层未接入时点扫描给一句原因，不静默', (tester) async {
    final st = AppState();
    await _pumpHub(tester, st);
    await tester.tap(find.text('扫描手机自带歌曲'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('扫描手机音乐').last);
    await tester.pumpAndSettle();

    expect(find.text('数据层未接入'), findsOneWidget);
    st.dispose();
  });
}
