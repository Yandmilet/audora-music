/// 诊断日志内核的行为测试（不联网）。
///
/// ## 重点钉住的两件事
/// 1. **摘要级 / 详细级的过滤边界**——这是用户明确的默认行为：
///    摘要级必须能抓到「匹配 + 崩溃 + 任何 warn/error」，
///    同时又不能把每条成功的网络请求都写下来（否则日志量翻倍）。
/// 2. **统计数据口径**——请求数、-412 次数、匹配成功率是判断
///    「配额够不够」的依据，口径错了会把人带偏。
library;

import 'dart:io';

import 'package:audora_music/screens/diag_log_page.dart';
import 'package:audora_music/services/diag/diag_log.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    DiagLog.instance.resetForTest();
    tmp = await Directory.systemTemp.createTemp('audora_diag_');
    await DiagLog.instance.init(dir: tmp.path);
  });

  tearDown(() async {
    await DiagLog.instance.flush();
    DiagLog.instance.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('摘要级：只记匹配、崩溃与 warn/error', () async {
    final log = DiagLog.instance;
    expect(log.verbose, isFalse);

    log.i(DiagCategory.match, '匹配过程');
    log.i(DiagCategory.net, '请求成功（详细级才该出现）');
    log.d(DiagCategory.match, '调试细节');
    log.w(DiagCategory.net, '触发风控 -412');
    log.e(DiagCategory.playback, '拉流失败');
    log.crash('闪退了', kind: 'async');

    final ring = log.ring;
    final msgs = ring.map((e) => e.message).toList();

    expect(msgs, contains('匹配过程'));
    expect(msgs, contains('触发风控 -412'));
    expect(msgs, contains('拉流失败'));
    expect(msgs, contains('闪退了'));
    // 详细级关着时，net 的普通 info 与 debug 一律不记
    expect(msgs, isNot(contains('请求成功（详细级才该出现）')));
    expect(msgs, isNot(contains('调试细节')));
  });

  test('详细级：网络请求也要记', () async {
    final log = DiagLog.instance;
    log.setVerbose(true);
    log.i(DiagCategory.net, 'GET /x/web-interface/wbi/search/type');

    expect(log.ring.map((e) => e.message),
        contains('GET /x/web-interface/wbi/search/type'));
  });

  test('环形缓冲上限 500，超出丢最旧的', () {
    final log = DiagLog.instance;
    for (var i = 0; i < DiagLog.ringCap + 50; i++) {
      log.i(DiagCategory.match, '第 $i 条');
    }
    final ring = log.ring;
    expect(ring.length, DiagLog.ringCap);
    // 最新的还在、最旧的已被挤掉。
    //
    // ⚠️ 这里刻意不写 `ring.last.message == '第 N 条'`：本套件的其它用例会
    // 留下**异步**的日志写入（flush / 定时器里的 log），它们可能落在这个
    // 同步测试之后、本文件下一个 setUp 之前的缝隙里，把 last 顶掉。
    // 全量并发跑时实测会因此假失败。「上限生效 + 新的在 + 旧的被挤掉」
    // 这三条才是这个测试要钉的东西。
    expect(
      ring.any((e) => e.message == '第 ${DiagLog.ringCap + 49} 条'),
      isTrue,
      reason: '最后写入的那条必须还在',
    );
    expect(ring.any((e) => e.message == '第 0 条'), isFalse);
  });

  test('落盘：flush 后文件里有对应 JSONL 行', () async {
    final log = DiagLog.instance;
    log.i(DiagCategory.match, '写盘测试', {'bvid': 'BV1xx411c7mD'});
    await log.flush();

    final entries = await log.readAll();
    final hit = entries.where((e) => e.message == '写盘测试');
    expect(hit, isNotEmpty);
    expect(hit.single.fields['bvid'], 'BV1xx411c7mD');
    expect(hit.single.category, DiagCategory.match);
  });

  test('字段含不可 JSON 编码的对象时，条目仍应保留并可落盘', () async {
    final log = DiagLog.instance;
    log.i(DiagCategory.match, '带对象字段', {
      'at': DateTime.now(), // 无 toJson：旧实现 jsonEncode 抛异常 → 整条被兜底 catch 吞掉
      'err': Object(),
    });

    final hit = log.ring.where((e) => e.message == '带对象字段').toList();
    expect(hit, hasLength(1), reason: '坏字段不该让整条日志无声消失');
    expect(hit.single.fields['at'], isA<String>());
    expect(hit.single.fields['err'], contains('Object'));

    await log.flush();
    final fromDisk = (await log.readAll()).where((e) => e.message == '带对象字段');
    expect(fromDisk, isNotEmpty);
  });

  test('统计：请求数 / -412 / 匹配成功率 / 崩溃', () async {
    final log = DiagLog.instance;
    // 网络请求属于详细级，先打开（否则成功请求不落盘，计数会漏）
    log.setVerbose(true);
    // 两条请求，其中一条撞风控
    log.i(DiagCategory.net, '请求A', {'event': 'request', 'endpoint': '/a', 'code': 0});
    log.w(DiagCategory.net, '请求B', {'event': 'request', 'endpoint': '/b', 'code': -412});
    // 三次匹配，两次成功
    log.i(DiagCategory.match, 'done1', {'event': 'done', 'ok': true});
    log.i(DiagCategory.match, 'done2', {'event': 'done', 'ok': true});
    log.i(DiagCategory.match, 'done3', {'event': 'done', 'ok': false});
    log.crash('崩一次', kind: 'flutter');

    final s = await log.stats();
    expect(s.requests, 2);
    expect(s.rateLimited, 1);
    expect(s.matchTotal, 3);
    expect(s.matchOk, 2);
    expect(s.matchRate, closeTo(2 / 3, 0.001));
    expect(s.crashes, 1);
  });

  test('统计：一次都没匹配过时成功率为 null（不显示 0%）', () async {
    final s = await DiagLog.instance.stats();
    expect(s.matchRate, isNull);
  });

  test('导出生成 jsonl 文件，清空后文件消失', () async {
    final log = DiagLog.instance;
    log.i(DiagCategory.match, '要被导出的条目');
    await log.flush();

    final path = await log.export();
    expect(path, isNotNull);
    final f = File(path!);
    expect(await f.exists(), isTrue);
    final raw = await f.readAsString();
    expect(raw, contains('要被导出的条目'));

    await log.clear();
    expect(await f.exists(), isFalse);
    expect(await log.readAll(), isEmpty);
  });

  testWidgets('日志页可渲染：统计条 + 详细级开关 + 空态占位', (tester) async {
    DiagLog.instance.resetForTest();
    final st = AppState();

    await tester.pumpWidget(MaterialApp(home: DiagLogPage(st: st)));
    await tester.pumpAndSettle();

    // 统计条四格：这是判断配额与匹配质量的入口，缺一格就不完整
    expect(find.text('今日请求'), findsOneWidget);
    expect(find.text('风控 -412'), findsOneWidget);
    expect(find.text('匹配成功'), findsOneWidget);
    // 「崩溃」在统计条与筛选 chip 里各出现一次，只断言存在
    expect(find.text('崩溃'), findsWidgets);
    // 详细级开关（摘要级没有开关，永远开着）
    expect(find.text('详细级（记录全部网络请求）'), findsOneWidget);
    // 没日志时给占位而不是白屏
    expect(find.text('还没有日志'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
    DiagLog.instance.resetForTest();
  });

  test('目录不可用时降级为纯内存，不抛异常', () async {
    DiagLog.instance.resetForTest();
    // 不调 init，或 init 失败：都不该让调用方崩
    final log = DiagLog.instance;
    expect(log.persistent, isFalse);
    expect(() => log.i(DiagCategory.match, '内存模式'), returnsNormally);
    expect(await log.readAll(), hasLength(1));
    await log.flush(); // 没有目录也要安静地过去
  });
}
