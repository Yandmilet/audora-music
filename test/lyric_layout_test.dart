/// 歌词页布局回归：初始位置 + 当前行强调 + 逐字层居中补偿。
///
/// ## 钉住的三条真机反馈（2026-10-11）
/// 1. **首行贴在「自动对齐」校准条下面**，不再被 0.3 屏高的上留白顶到
///    视口中线以下（用户反馈「歌词初始位置太靠下」）。
/// 2. **当前行 22pt、其余 13pt** —— 反差从 18/15（1.2 倍）拉到 1.7 倍。
/// 3. **逐字（扫光）行必须水平居中**。这条是真正的 bug：`TextPainter` 对
///    单行段落的 `textAlign: center` 根本不生效（tp.width 会缩成文字宽度，
///    字形也不按 maxWidth 右移），而普通行走的是 `Text`/RenderParagraph，
///    它自己会居中。结果就是「只有正在唱的这行偏左，其它行是好的」。
///    用例「单行 TextPainter 即使设了 center 也贴左」直接量一次真实排版，
///    把根因钉住——防止将来有人把补偿代码当成冗余删掉。
///
/// ## 为什么靠 [AppState] 内置的 1 秒模拟计时器推进时间
/// 定位由 `_onState` 完成，它读的是 `st.lyricLine`；而 `debugPositionMs`
/// 只写位置、**不**重算行号（真实链路里这两步在计时器回调内成对发生）。
/// 手动分两步设会让滚动和高亮各算各的，测出来的居中位置是假的。
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/screens/player/player_lyric_tab.dart';
import 'package:audora_music/services/lyric/lrc_parser.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song({int id = 1, String title = '晴天'}) => Song(
      id: id,
      title: title,
      artist: '周杰伦',
      duration: 269,
      coverSeed: 0,
    );

/// 八行整行歌词（**不**补字轴）—— 走普通高亮分支，方便断言样式。
ParsedLyric _plainLyric() => parseLrc([
      '[00:00.00]第一句',
      '[00:08.00]第二句',
      '[00:16.00]第三句',
      '[00:24.00]第四句',
      '[00:32.00]第五句',
      '[00:40.00]第六句',
      '[00:48.00]第七句',
      '[00:56.00]第八句',
    ].join('\n'));

/// 播放页歌词 tab 的真实可视高度量级（整屏减掉顶栏/进度条/控制区）。
const _tabHeight = 420.0;

/// 建一个只带歌词页的 AppState 并挂上 widget 树。
///
/// 返回的 state 必须在测试体结束前显式 dispose（playQueue 在无播放器时会起
/// 1 秒周期计时器，`testWidgets` 的残留 Timer 检查发生在 addTearDown 之前）。
Future<AppState> _pumpLyric(
  WidgetTester tester,
  ParsedLyric lyric, {
  int positionMs = 0,
}) async {
  final st = AppState();
  addTearDown(() {
    try {
      st.dispose();
    } catch (_) {
      // 已经 dispose 过
    }
  });
  st.playQueue([_song()], 0);
  st.debugLyric = lyric;
  if (positionMs > 0) st.debugPositionMs = positionMs;

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: 390, height: _tabHeight, child: LyricTab(st: st)),
      ),
    ),
  ));
  await tester.pump();
  return st;
}

/// 走 n 个「一秒」：驱动内置计时器 → 位置 + 行号 + posTick 一起动。
Future<void> _advance(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  // 让 420ms 的 animateTo 收尾
  await tester.pump(const Duration(milliseconds: 500));
}

/// 歌词列表自己的 ScrollPosition（校准条里另有可滚动部件，
/// 所以从 ListView 往下找，不直接 byType）。
ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable))
        .first)
    .position;

/// 取渲染某句歌词的那个 [AnimatedDefaultTextStyle]。
///
/// 返回 widget 而不是 style：`textAlign` 挂在 widget 上（TextStyle 没有这个
/// 字段），字号/字重挂在 style 上，两边都要能拿到。
AnimatedDefaultTextStyle? _lineOf(WidgetTester tester, String text) {
  for (final e in tester.widgetList<AnimatedDefaultTextStyle>(
      find.byType(AnimatedDefaultTextStyle))) {
    final child = e.child;
    if (child is Text && child.data == text) return e;
  }
  return null;
}

void main() {
  const phoneSize = Size(390, 844);

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  group('逐字居中补偿（纯函数）', () {
    test('盒子比文字宽时补一半差值', () {
      expect(karaokeCenterDx(300, 54), 123);
    });

    test('文字不比盒子窄时不补（相等与更宽都收成 0）', () {
      expect(karaokeCenterDx(300, 300), 0);
      expect(karaokeCenterDx(300, 480), 0);
    });

    test('量不出居中时返回 0，而不是 Infinity / NaN', () {
      expect(karaokeCenterDx(double.infinity, 54), 0);
      expect(karaokeCenterDx(300, double.nan), 0);
    });
  });

  testWidgets('单行 TextPainter 即使设了 center 也贴左 —— 补偿不可省',
      (tester) async {
    tester.view.physicalSize = phoneSize * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 与 _KaraokeLine._layoutText 同样的参数：单行 + textAlign.center。
    final tp = TextPainter(
      text: const TextSpan(
        text: '故事的小黄花',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout(maxWidth: 322);
    addTearDown(tp.dispose);

    // 段落宽度缩成了文字本身的宽度，而不是布局宽度 322。
    expect(tp.width, lessThan(322));
    // 首字符的 x 仍是 0 —— 这就是「只有当前行偏左」的全部原因。
    final caret0 = tp.getOffsetForCaret(
      const TextPosition(offset: 0),
      Rect.fromLTRB(0, 0, tp.width, tp.height),
    );
    expect(caret0.dx, 0);
    // 补偿量为正，且补完左右余量相等。
    final dx = karaokeCenterDx(322, tp.width);
    expect(dx, greaterThan(0));
    expect(dx * 2 + tp.width, closeTo(322, 0.001));
  });

  group('初始位置', () {
    testWidgets('唱第一句时列表不滚动，首行贴着校准条下面', (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final st = await _pumpLyric(tester, _plainLyric());
      // 让 _onState 至少跑一次（首次定位走 jumpTo，无动画）
      await _advance(tester, 1);

      // active = 0：定位公式算出负数，被 clamp 成 0 —— 一点都不滚。
      expect(_listPosition(tester).pixels, 0);

      final dy = tester.getTopLeft(find.text('第一句')).dy -
          tester.getTopLeft(find.byType(ListView)).dy;
      // 旧实现（上下各留 0.3 屏高）这里约 180px；现在不能超过约一个行高。
      expect(dy, lessThan(72));
      expect(tester.takeException(), isNull);
      st.dispose();
    });

    testWidgets('置顶没有牺牲居中：唱到中间行时当前行仍在视口中线',
        (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final st = await _pumpLyric(tester, _plainLyric());
      await _advance(tester, 35); // 35s → 第五句（32s 起）

      final pos = _listPosition(tester);
      expect(pos.pixels, greaterThan(0)); // 确实在滚动，不是卡在顶部
      final lineCenter = tester.getCenter(find.text('第五句')).dy;
      final viewportCenter =
          tester.getTopLeft(find.byType(ListView)).dy + pos.viewportDimension / 2;
      expect((lineCenter - viewportCenter).abs(), lessThan(8.0));
      expect(tester.takeException(), isNull);
      st.dispose();
    });
  });

  group('当前行强调', () {
    testWidgets('当前行 22 / 其余 13，两层都居中', (tester) async {
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final st = await _pumpLyric(tester, _plainLyric());
      // 滚动到第五句居中，相邻行才会进 ListView 的可视区（懒加载，
      // 不滚的话第 6 行根本没被 build 出来，取到的是 null）。
      await _advance(tester, 35);
      expect(st.lyricLine, 4);

      final active = _lineOf(tester, '第五句');
      final other = _lineOf(tester, '第六句');
      expect(active?.style.fontSize, 22);
      expect(other?.style.fontSize, 13);
      expect(active?.style.fontWeight, FontWeight.w800);
      expect(other?.style.fontWeight, FontWeight.w500);
      expect(active?.textAlign, TextAlign.center);
      expect(other?.textAlign, TextAlign.center);
      expect(tester.takeException(), isNull);
      st.dispose();
    });
  });
}
