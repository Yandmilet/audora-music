/// 「我的」页底部关于文案的回归测试（不联网）。
///
/// ## 为什么钉住这两样（2026-10-11 用户反馈）
/// 1. **版本号**：底部原来写死「Audora 2.0」——那是原型设计稿的年代号，
///    和 pubspec 的真实发版号（0.1.0）对不上，用户要求换成实际版本号。
///    现在文案从 `kAppVersion` 取，本测试逐字校验它 == pubspec.yaml 的
///    `version`，改版号忘了同步会直接红。
/// 2. **协议**：仓库 LICENSE 已从 MIT 换成 GPL-3.0，底部文案必须同步
///    声明；LICENSE 文件本身也一并校验——防止只改一处，造成界面文案
///    与法律文本不一致。
library;

import 'dart:io';

import 'package:audora_music/main.dart';
import 'package:audora_music/screens/mine_screen.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('底部展示的版本号与 pubspec.yaml 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml 应有 version 字段');
    final version = match!.group(1)!.split('+').first;
    expect(
      kAppVersion,
      version,
      reason: 'pubspec 的 version 变了，记得同步 mine_screen.dart 的 kAppVersion',
    );
  });

  test('LICENSE 是 GPL-3.0 全文，不再是 MIT', () {
    final license = File('LICENSE').readAsStringSync();
    expect(license, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(license, contains('Version 3, 29 June 2007'));
    expect(license, isNot(contains('MIT License')));
    expect(
      license,
      isNot(contains('Permission is hereby granted, free of charge')),
      reason: 'MIT 授权正文不该再残留',
    );
  });

  testWidgets('「我的」页底部展示：实际版本号 + 基于 Flutter 开发 + GPL-3.0',
      (tester) async {
    // 底部文案在列表末端：默认 600 高的测试画布下可能还没被懒构建，
    // 临时把画布拉高保证它在树里，测试结束还原。
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final st = AppState(); // repo = null，mock 模式；本断言与数据无关

    // 按 main.dart 的真实结构包装 Shell（与 mine_settings_test 同款）
    await tester.pumpWidget(AnimatedBuilder(
      animation: st,
      builder: (context, _) => MaterialApp(
        home:
            Shell(st: st, messengerKey: GlobalKey<ScaffoldMessengerState>()),
      ),
    ));
    await tester.pumpAndSettle();
    st.setTab(1);
    await tester.pumpAndSettle();

    expect(
      find.text('Audora v$kAppVersion · 基于 Flutter 开发 · 开源协议 GPL-3.0'),
      findsOneWidget,
    );
    // 旧的营销版文案与旧协议说法都不允许残留在页面上
    expect(find.textContaining('Audora 2.0'), findsNothing);
    expect(find.textContaining('个人自用'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });
}
