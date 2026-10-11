/// LRC 歌词解析器单测。
///
/// 覆盖的都是**真实歌词文件里见过的写法**，不是凭空造的边界：
///   - 一行多时间标签（副歌复用）
///   - 1/2/3 位小数的毫秒
///   - `[ti:]` `[ar:]` 等元信息标签
///   - 创作者标注行（`词：` `曲：`）应当被当作普通歌词行保留
///   - 纯音乐占位文案
library;

import 'package:audora_music/services/lyric/lrc_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLrc 基本解析', () {
    test('标准两行 + 毫秒', () {
      const raw = '[00:15.30]这一路上走走停停\n[00:18.50]顺着少年漂流的痕迹';
      final r = parseLrc(raw);
      expect(r.lines.length, 2);
      expect(r.lines[0].text, '这一路上走走停停');
      expect(r.lines[0].time, const Duration(seconds: 15, milliseconds: 300));
      expect(r.lines[1].time, const Duration(seconds: 18, milliseconds: 500));
    });

    test('小时位与 1~3 位小数都要能解析', () {
      const raw = '[0:05]整数秒\n[00:06.5]一位小数\n[00:07.50]两位小数\n'
          '[00:08.125]三位小数\n[01:02:03.00]带小时';
      final r = parseLrc(raw);
      expect(r.lines.length, 5);
      expect(r.lines[0].time, const Duration(seconds: 5));
      expect(r.lines[1].time, const Duration(seconds: 6, milliseconds: 500));
      expect(r.lines[2].time, const Duration(seconds: 7, milliseconds: 500));
      expect(r.lines[3].time, const Duration(seconds: 8, milliseconds: 125));
      // [01:02:03.00] 是「1 小时 02 分 03 秒」，不能退化成 1 分 02 秒
      expect(
        r.lines[4].time,
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
    });

    test('一行多个时间标签展开成多条', () {
      const raw = '[00:12.00][01:30.00]同样的副歌词';
      final r = parseLrc(raw);
      expect(r.lines.length, 2);
      expect(r.lines[0].text, '同样的副歌词');
      expect(r.lines[1].text, '同样的副歌词');
      expect(r.lines[0].time, const Duration(seconds: 12));
      expect(r.lines[1].time, const Duration(seconds: 90));
    });
  });

  group('parseLrc 噪声过滤', () {
    test('元信息标签被排除', () {
      const raw = '[ti:起风了]\n[ar:买辣椒也用券]\n[al:起风了]\n[by:someone]\n'
          '[00:15.30]真正的歌词';
      final r = parseLrc(raw);
      expect(r.lines.length, 1);
      expect(r.lines.first.text, '真正的歌词');
    });

    test('纯音乐占位文案被识别', () {
      final r = parseLrc('此歌曲为没有填词的音乐，请您欣赏');
      expect(r.lines, isEmpty);
      expect(r.instrumental, isTrue);
    });

    test('空文本返回空结果且不抛异常', () {
      expect(parseLrc('').lines, isEmpty);
      expect(parseLrc('   \n\n  ').lines, isEmpty);
      expect(parseLrc('完全没有时间标签的文本').lines, isEmpty);
    });

    test('创作者标注行被保留为歌词（它们是真实可见的行）', () {
      const raw = '[00:06.42]词：米果\n[00:07.92]曲：高桥优\n[00:10.07]编曲：池洼浩一';
      final r = parseLrc(raw);
      expect(r.lines.length, 3);
      expect(r.lines[0].text, '词：米果');
      expect(r.lines[1].text, '曲：高桥优');
    });

    test('同一时间戳重复行只保留第一条（应对翻译歌词重影）', () {
      const raw = '[00:12.00]原文\n[00:12.00]译文';
      final r = parseLrc(raw);
      expect(r.lines.length, 1);
      expect(r.lines.first.text, '原文');
    });
  });

  group('parseLrc 排序与查找', () {
    test('乱序输入按时间排序', () {
      const raw = '[00:30.00]第三句\n[00:10.00]第一句\n[00:20.00]第二句';
      final r = parseLrc(raw);
      expect(r.lines.map((e) => e.text).toList(), ['第一句', '第二句', '第三句']);
    });

    test('indexAt：前奏期间返回 -1 而不是 0', () {
      const raw = '[00:10.00]第一句\n[00:20.00]第二句';
      final r = parseLrc(raw);
      // 前奏 5 秒时，还没到第一句，应返回 -1（界面表现为无高亮）
      expect(r.indexAt(const Duration(seconds: 5)), -1);
    });

    test('indexAt：精确命中和夹在中间都对', () {
      const raw = '[00:10.00]第一句\n[00:20.00]第二句\n[00:30.00]第三句';
      final r = parseLrc(raw);
      expect(r.indexAt(const Duration(seconds: 10)), 0);
      expect(r.indexAt(const Duration(seconds: 15)), 0);
      expect(r.indexAt(const Duration(seconds: 20)), 1);
      expect(r.indexAt(const Duration(seconds: 25)), 1);
      expect(r.indexAt(const Duration(seconds: 35)), 2);
      expect(r.indexAt(const Duration(minutes: 5)), 2);
    });

    test('indexAt：空歌词返回 -1', () {
      expect(ParsedLyric.empty.indexAt(const Duration(seconds: 5)), -1);
    });
  });

  group('CRLF 与空白', () {
    test('Windows 换行正常解析', () {
      const raw = '[00:10.00]第一句\r\n[00:20.00]第二句\r\n';
      final r = parseLrc(raw);
      expect(r.lines.length, 2);
      expect(r.lines[0].text, '第一句');
    });

    test('行首尾空白被清理', () {
      const raw = '  [00:10.00]  第一句  \n\t[00:20.00]第二句\n';
      final r = parseLrc(raw);
      expect(r.lines[0].text, '第一句');
      expect(r.lines[1].text, '第二句');
    });

    test('只有时间标签没有正文的行被跳过', () {
      const raw = '[00:10.00]\n[00:20.00]有内容';
      final r = parseLrc(raw);
      expect(r.lines.length, 1);
      expect(r.lines.first.text, '有内容');
    });
  });
}
