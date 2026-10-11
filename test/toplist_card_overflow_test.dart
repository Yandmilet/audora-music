/// 榜单卡片布局回归：**长歌手名不得越出卡片**。
///
/// ## 缺陷原状（2026-09-30，真机截图定位）
/// `ToplistCard` 的预览行原本是：
///
/// ```
/// Row[ SizedBox(22) 名次, Expanded 歌名, SizedBox(8), Text 歌手名 ]
/// ```
///
/// 最后那个 `Text` **没有** Expanded / Flexible 约束。Row 布局时非 flex
/// 子元素先按 intrinsic（不受 Row 可用宽度限制）排布，所以它拿到的是
/// 自身完整宽度，整行右侧溢出 143 px。
///
/// 真机上的表现就是用户看到的那一幕：卡片右缘出现黄黑相间的 overflow
/// 条纹，叠加竖排红字「RIGHT OVERFLOWED BY 143 PIXELS」，把榜单内容盖住。
/// 之所以只在**欧美榜**明显，是因为榜单列表接口
/// （`musicToplist.ToplistInfoServer/GetAll`）给的歌手名是**全量拼接**的，
/// 欧美榜第 2 名长达 70+ 字符；韩国榜那一批都很短，所以看不出来。
///
/// 本文件里的歌手串是从该接口实抓的原值（2026 年第 39 周），不是编的。
library;

import 'package:audora_music/screens/home_screen.dart';
import 'package:audora_music/services/qqmusic/qqmusic_catalog_dto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 欧美榜（topId = 3）2026 年第 39 周的真实前三行。
const List<ToplistPreviewRow> _euroTop3 = [
  ToplistPreviewRow(
    rank: 1,
    title: 'If The Sun Burns Out Tonight (feat. Oli Sykes & Courtney '
        'LaPlante) (炽日将烬)',
    singer: '无畏契约/Grabbitz/Oli Sykes/Courtney Laplante',
  ),
  ToplistPreviewRow(
    rank: 2,
    title: 'Live My Life (我行我路)',
    // 就是这一条把卡片撑破的：70 个字符、三组分隔符
    singer: 'HEARTSTEEL (心之钢)/英雄联盟/伯贤 (백현)/Connor Price/'
        'Anderson .Paak/Nic D',
  ),
  ToplistPreviewRow(
    rank: 3,
    title: 'Training Season (London Sessions)',
    singer: 'Dua Lipa',
  ),
];

const ToplistBrief _euroBrief = ToplistBrief(
  topId: 3,
  title: '欧美榜',
  subtitle: '欧美榜 第39周',
  updateTime: '2026-09-24',
  totalNum: 100,
  preview: _euroTop3,
);

/// 卡片可用宽度。真机 360 dp 屏减去页面左右 20+20 与卡片内边距 14+12，
/// 大约是 294 —— 这里直接用 294 并再窄一点做余量，覆盖更小的机型。
Future<void> _pumpCard(WidgetTester tester, {double width = 294}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: ToplistCard(brief: _euroBrief, onTap: () {}),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('欧美榜长歌手名：不产生 RenderFlex overflow', (tester) async {
    await _pumpCard(tester);

    // RenderFlex 溢出在 debug 下走 FlutterError.reportError，widget test
    // 会把它记为异常。这一行等价于「卡片上没有黄黑条纹」。
    expect(tester.takeException(), isNull);

    // 复现条件成立性自检：第 2 行的歌手名确实比一行能放下的更长。
    // 若哪天接口改成只给首位歌手，这条会失败并提醒删除本回归。
    expect(_euroTop3[1].singer.length, greaterThan(60));
  });

  testWidgets('欧美榜长歌手名：每段文字都在卡片矩形内', (tester) async {
    await _pumpCard(tester);

    final card = tester.getRect(find.byType(ToplistCard));
    final texts = find.descendant(
      of: find.byType(ToplistCard),
      matching: find.byType(Text),
    );
    final elements = texts.evaluate().toList();
    // 标题 + 副标题 + 3 行 ×（名次、歌名、歌手）= 11
    expect(elements.length, greaterThanOrEqualTo(11));

    for (final el in elements) {
      final r = tester.getRect(find.byElementPredicate((e) => identical(e, el)));
      final label = (el.widget as Text).data ?? '';
      expect(
        r.right,
        lessThanOrEqualTo(card.right + 0.5),
        reason: '「$label」越出卡片右缘（应被 Flexible + ellipsis 约束住）',
      );
    }
  });

  testWidgets('超长歌手名不会把歌名挤成 0 宽（两侧都要看得见）', (tester) async {
    await _pumpCard(tester);

    // 修复前：歌手名按 intrinsic 宽度吃掉整行，歌名被压到 0 宽 ——
    // 0 宽的 Text 会把每个字符排成一行，正是截图里那列竖排红字的成因。
    final title = tester.getRect(find.text(_euroTop3[1].title));
    final singer = tester.getRect(find.text(_euroTop3[1].singer));

    expect(title.width, greaterThan(60), reason: '歌名被挤没了');
    expect(singer.width, greaterThan(40), reason: '歌手名被挤没了');
    // flex 3:2 —— 歌名拿到的份额应多于歌手名
    expect(title.width, greaterThan(singer.width));
  });

  testWidgets('窄屏（280）下同样不溢出', (tester) async {
    await _pumpCard(tester, width: 280);
    expect(tester.takeException(), isNull);
  });
}
