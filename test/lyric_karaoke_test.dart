/// 逐字扫光的渲染层测试。
///
/// ## 防什么缺陷
/// 字轴/解析逻辑由 `lyric_word_test.dart` 覆盖，这里只管**画出来会不会出事**：
/// 1. 扫光是自绘 + clipRect，长行折行、字体兜底都可能裁出错位或溢出；
///    `itemExtent` 是固定值，一旦排到第三行就会压到下一句（历史上真出过）。
/// 2. 当前行自带一个 60fps 的 Ticker。测试里如果误用 `pumpAndSettle`，
///    它会永远等不到"静帧"而超时——这条也在用例里钉住：只能用 `pump`。
/// 3. `karaokeLyricMs()` 的外推不能反向（进度倒退会让扫光来回抖动）。
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/screens/player/player_lyric_tab.dart';
import 'package:audora_music/services/lyric/lrc_parser.dart';
import 'package:audora_music/services/lyric/ttml_lyric_parser.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实结构的 TTML（取自《晴天》原文，截 4 行）
const _ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word"><body>
<div begin="00:29.231" end="04:25.541">
<p begin="00:29.231" end="00:32.723"><span begin="00:29.231" end="00:29.692">故</span><span begin="00:29.692" end="00:30.057">事</span><span begin="00:30.057" end="00:30.472">的</span><span begin="00:30.472" end="00:31.329">小</span><span begin="00:31.329" end="00:31.799">黄</span><span begin="00:31.799" end="00:32.723">花</span></p>
<p begin="00:32.723" end="00:36.238"><span begin="00:32.723" end="00:33.132">从</span><span begin="00:33.132" end="00:33.571">出</span><span begin="00:33.571" end="00:34.012">生</span><span begin="00:34.012" end="00:34.446">那</span><span begin="00:34.446" end="00:34.671">年</span><span begin="00:34.671" end="00:34.904">就</span><span begin="00:34.904" end="00:35.338">飘</span><span begin="00:35.338" end="00:36.238">着</span></p>
<p begin="00:36.238" end="00:39.723"><span begin="00:36.238" end="00:36.687">童</span><span begin="00:36.687" end="00:37.094">年</span><span begin="00:37.094" end="00:37.589">的</span><span begin="00:37.589" end="00:38.409">荡</span><span begin="00:38.409" end="00:38.843">秋</span><span begin="00:38.843" end="00:39.723">千</span></p>
<p begin="00:39.723" end="00:43.000"><span begin="00:39.723" end="00:40.100">随</span><span begin="00:40.100" end="00:43.000">着</span></p>
</div></body></tt>''';

Song _song({int id = 1, String title = '晴天'}) => Song(
      id: id,
      title: title,
      artist: '周杰伦',
      duration: 269,
      coverSeed: 0,
    );

/// 建一个只带歌词页的 AppState 并挂上 widget 树。
///
/// 返回的 state **必须在测试体结束前显式 dispose**：[AppState.playQueue] 在
/// 无播放器时会起一个 1 秒周期的模拟播放 Timer，而 `testWidgets` 的
/// "不允许残留 Timer" 检查发生在 addTearDown **之前**，只靠 tearDown 释放
/// 会直接报 "A Timer is still pending"（仓库里其它 widget 测试也是这个约定）。
/// 下面的 addTearDown 只是失败路径的兜底，避免断言挂掉时泄漏成第二个错误。
Future<AppState> _pumpLyric(
  WidgetTester tester,
  ParsedLyric lyric, {
  int positionMs = 30000,
}) async {
  final st = AppState();
  addTearDown(() {
    try {
      st.dispose();
    } catch (_) {
      // 已经 dispose 过，正常
    }
  });
  st.playQueue([_song()], 0);
  st.debugPositionMs = positionMs;
  st.debugLyric = lyric;

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox.expand(child: LyricTab(st: st)),
    ),
  ));
  await tester.pump();
  return st;
}

bool _isKaraokeLine(Widget w) => w.runtimeType.toString() == '_KaraokeLine';

void main() {
  const phoneSize = Size(390, 844);

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  group('逐字行渲染', () {
    testWidgets('有字轴的当前行走逐字组件，且不抛异常', (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final lyric = applyWordTiming(parseTtmlLyric(_ttml), totalDurationMs: 269000);
      // 位置落在第 1 行内部（29.231 ~ 32.723）
      final st = await _pumpLyric(tester, lyric, positionMs: 30000);

      expect(find.byWidgetPredicate(_isKaraokeLine), findsOneWidget);
      expect(tester.takeException(), isNull);
      st.dispose();
    });

    testWidgets('连续推进若干帧：无异常、无溢出', (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final lyric = applyWordTiming(parseTtmlLyric(_ttml), totalDurationMs: 269000);
      final st = await _pumpLyric(tester, lyric, positionMs: 29300);

      // 逐字扫光每帧重绘，这里手动走约 1.5 秒
      for (var ms = 29300; ms < 33000; ms += 100) {
        st.debugPositionMs = ms;
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      st.dispose();
    });

    testWidgets('超长单行折成 2 行时不压破固定行高', (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 一行宽到必然折成 2 视觉行（Dart 没有 String * int，只能拼）
      final long = List.filled(12, 'substring ').join().trim();
      final lyric = applyWordTiming(
        parseLrc('[00:30.00]$long\n[00:40.00]第二句'),
        totalDurationMs: 200000,
      );
      final st = await _pumpLyric(tester, lyric, positionMs: 34000);

      expect(find.byWidgetPredicate(_isKaraokeLine), findsOneWidget);
      // RenderFlex / clip 越界都会以异常形式暴露
      expect(tester.takeException(), isNull);
      st.dispose();
    });

    testWidgets('没有字轴时退回普通整行高亮（不因新链路而丢歌词）', (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 直接给未补字轴的歌词：模拟 applyWordTiming 之前的老数据
      const plain = ParsedLyric(lines: [
        LyricLine(time: Duration(seconds: 30), text: '只有整行'),
      ]);
      final st = await _pumpLyric(tester, plain, positionMs: 31000);

      expect(find.byWidgetPredicate(_isKaraokeLine), findsNothing);
      expect(find.text('只有整行'), findsOneWidget);
      expect(tester.takeException(), isNull);
      st.dispose();
    });
  });

  group('karaokeLyricMs 外推时钟', () {
    test('暂停时不外推，与整行高亮取完全相同的映射值', () async {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = applyWordTiming(
          parseLrc('[00:30.00]第一句\n[00:40.00]第二句'),
          totalDurationMs: 200000);
      await st.togglePlay(); // playQueue 会把 playing 置真，先暂停
      expect(st.playing, isFalse);

      for (final ms in [0, 1234, 30000, 199999]) {
        st.debugPositionMs = ms;
        expect(st.karaokeLyricMs(), st.mappedLyricMs);
      }
    });

    test('播放中外推只前进不倒退，且被钳在 1 秒内', () async {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugPositionMs = 30000;
      expect(st.playing, isTrue);

      int prev = -1;
      for (var i = 0; i < 30; i++) {
        final v = st.karaokeLyricMs();
        expect(v, greaterThanOrEqualTo(prev), reason: '扫光来回抖动的根源');
        // 最后一次采样是 30000，外推不得越过 1 秒上限
        expect(v, lessThanOrEqualTo(31000));
        prev = v;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });

    test('slope/offset 校准时外推与整行共用同一映射，不会错位', () async {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugPositionMs = 30000;
      st.adjustLyricOffset(500);
      expect(st.mappedLyricMsAt(30000), 30500);

      await st.togglePlay(); // 暂停 → 外推停止，可做严格比对
      expect(st.karaokeLyricMs(), st.mappedLyricMs);
      expect(st.karaokeLyricMs(), 30500);
    });
  });
}
