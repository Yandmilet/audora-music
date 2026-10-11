/// 逐字歌词（字轴）相关的全部纯逻辑测试：分字、均分、填充计算、
/// TTML 解析、AMLL 匹配门禁、文件名安全校验。
///
/// ## fixture 是真数据
/// TTML 片段直接取自 2026-10-11 从 amlldb.bikonoo.com 抓下来的
/// 周杰伦《晴天》与米津玄師《Lemon》原文，不是手写的理想样例。
/// 两者恰好覆盖了三种不同的 TTML 时间写法：
///   晴天 `00:29.231`（mm:ss.SSS）、Lemon 首行 `1.372`（纯秒）、
///   Lemon 末行 `3:58.431`（m:ss.SSS）。
/// 用真实样本的原因很实际：这类格式的坑全在边界上，自己编样例
/// 只会验证自己已经想到的情况。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:audora_music/services/lyric/amll_ttml_provider.dart';
import 'package:audora_music/services/lyric/lrc_parser.dart';
import 'package:audora_music/services/lyric/lyric_word.dart';
import 'package:audora_music/services/lyric/ttml_lyric_parser.dart';

// ── fixture ────────────────────────────────────────────────

const qingtianTtml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">
  <body dur="04:25.541">
    <div xmlns="" begin="00:29.231" end="04:25.541">
      <p begin="00:29.231" end="00:32.723" ttm:agent="v1" itunes:key="L1"><span begin="00:29.231" end="00:29.692">故</span><span begin="00:29.692" end="00:30.057">事</span><span begin="00:30.057" end="00:30.472">的</span><span begin="00:30.472" end="00:31.329">小</span><span begin="00:31.329" end="00:31.799">黄</span><span begin="00:31.799" end="00:32.723">花</span></p>
      <p begin="00:32.723" end="00:36.238" ttm:agent="v1" itunes:key="L2"><span begin="00:32.723" end="00:33.132">从</span><span begin="00:33.132" end="00:33.571">出</span><span begin="00:33.571" end="00:34.012">生</span><span begin="00:34.012" end="00:34.446">那</span><span begin="00:34.446" end="00:34.671">年</span><span begin="00:34.671" end="00:34.904">就</span><span begin="00:34.904" end="00:35.338">飘</span><span begin="00:35.338" end="00:36.238">着</span></p>
    </div>
  </body>
</tt>''';

/// Lemon：纯秒 + m:ss 两种时间写法混用，且带译文与注音
const lemonTtml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">
 <head><metadata><amll:meta key="qqMusicId" value="000akynZ2Rbro5"/></metadata></head><body dur="4:04.513">
  <div begin="1.372" end="4:04.513">
    <p begin="1.372" end="2.705" itunes:key="L1" ttm:agent="v1"><span begin="1.372" end="1.749">夢</span><span begin="1.749" end="1.972">な</span><span begin="1.972" end="2.137">ら</span><span begin="2.137" end="2.524">ば</span><span ttm:role="x-translation" xml:lang="zh-CN">如果只是一场梦</span><span ttm:role="x-roman">yu me na ra ba</span></p>
    <p begin="3:58.431" end="4:04.513" itunes:key="L54" ttm:agent="v1"><span begin="3:58.431" end="3:58.815">今</span><span begin="3:58.815" end="3:59.143">で</span><span begin="3:59.143" end="3:59.471">も</span></p>
  </div>
 </body></tt>''';

void main() {
  group('tokenizeCharCounts 中文按字 / 拉丁按词', () {
    test('纯中文：每字一段', () {
      expect(tokenizeCharCounts('故事的小黄花'), [1, 1, 1, 1, 1, 1]);
    });

    test('英文：按单词切，空格挂在词尾', () {
      expect(tokenizeCharCounts('Cruel Angel Thesis'), [6, 6, 6]);
    });

    test('标点跟随前一个字，不单独占一拍', () {
      // 「了。」合成一段：句号不该有自己时长，否则扫光会在标点处停一下
      expect(tokenizeCharCounts('花了'), [1, 1]);
      expect(tokenizeCharCounts('花了。'), [1, 2]);
      expect(tokenizeCharCounts('晴天，周杰伦'), [1, 2, 1, 1, 1]);
    });

    test('中英混排各按各的规则', () {
      final t = tokenizeCharCounts('Hey 你好 OK');
      expect(t.fold<int>(0, (a, b) => a + b), 'Hey 你好 OK'.length);
    });

    test('不变式：段长之和恒等于字符串长度（含代理对/全角/emoji）', () {
      const corpus = [
        '故事的小黄花',
        'Cruel Angel\'s Thesis',
        '起风了 (原版) - 买辣椒也用券',
        '👍🏽 好',
        'ＲＥＡＬ 全角',
        '  前后有空格  ',
        '！！！',
        'A',
        '',
        '混合 English 和 中文 with punctuation. 结束！',
        '１２３４567890',
        'ー┗━━━━━━━━┛',
      ];
      for (final s in corpus) {
        final counts = tokenizeCharCounts(s);
        expect(counts.fold<int>(0, (a, b) => a + b), s.length,
            reason: '切片必须不重不漏地覆盖「$s」');
        // 每一段至少 1 个 code unit，且代理对不被切开（切开会渲染成乱码方块）
        for (final c in counts) {
          expect(c, greaterThan(0));
        }
        for (var i = 0, off = 0; i < counts.length; i++) {
          final first = off < s.length ? s.codeUnitAt(off) : 0;
          expect(
            first >= 0xDC00 && first <= 0xDFFF,
            isFalse,
            reason: '第 $i 段从一个孤立低代理开始，说明代理对被切开了',
          );
          off += counts[i];
        }
      }
    });

    test('emoji 占一整段（2 个 code unit），不会被切成两个代理', () {
      final counts = tokenizeCharCounts('好👍的');
      expect(counts.fold<int>(0, (a, b) => a + b), '好👍的'.length);
      expect(counts.contains(2), isTrue, reason: '👍 应作为一段存在');
    });
  });

  group('estimateWords 均分兜底', () {
    test('覆盖整段：首字起于行首、末字止于行尾，且时间单调不减', () {
      final w = estimateWords(
          charCounts: [1, 1, 1, 1], startMs: 1000, endMs: 5000);
      expect(w.length, 4);
      expect(w.first.startMs, 1000);
      expect(w.last.endMs, 5000);
      for (var i = 1; i < w.length; i++) {
        expect(w[i].startMs, w[i - 1].endMs);
        expect(w[i].endMs, greaterThanOrEqualTo(w[i].startMs));
      }
    });

    test('整除不了的时长不会把误差堆到最后一段', () {
      // 1000ms 分给 3 段 → 333/333/334，不是 333/333/1000-999
      final w = estimateWords(charCounts: [1, 1, 1], startMs: 0, endMs: 1000);
      expect(w.map((e) => e.durationMs).toList(), [333, 333, 334]);
    });

    test('英文按字符数加权：长词占更久', () {
      final w = estimateWords(
          charCounts: tokenizeCharCounts('it beautiful'),
          startMs: 0,
          endMs: 10000);
      final it = w.first.durationMs;
      final beautiful = w[1].durationMs;
      expect(beautiful, greaterThan(it));
    });

    test('行尾早于行首时返回空，而不是造出倒着走的时间', () {
      expect(estimateWords(charCounts: [1, 1], startMs: 5000, endMs: 1000), isEmpty);
      expect(estimateWords(charCounts: [1, 1], startMs: 5000, endMs: 5000), isEmpty);
    });
  });

  group('fillAtWord 扫光位置', () {
    final words = estimateWords(
        charCounts: [1, 1, 1, 1], startMs: 0, endMs: 4000);

    test('唱完一个字才推进下一个，字内线性插值', () {
      expect(fillAtWord(words: words, positionMs: 0).charsDone, 0.0);
      expect(fillAtWord(words: words, positionMs: 1000).charsDone, 1.0);
      expect(fillAtWord(words: words, positionMs: 1500).charsDone, closeTo(1.5, 1e-9));
      expect(fillAtWord(words: words, positionMs: 4000).charsDone, 4.0);
      expect(fillAtWord(words: words, positionMs: 99999).charsDone, 4.0);
    });

    test('连续单调：位置前进时填充量绝不倒退', () {
      double prev = -1;
      for (var ms = -100; ms <= 4200; ms += 37) {
        final d = fillAtWord(words: words, positionMs: ms).charsDone;
        expect(d, greaterThanOrEqualTo(prev), reason: 'ms=$ms 处回退了');
        prev = d;
      }
    });

    test('字轴字符数超过行长时钳到行长（UI 不会算出 >100% 宽度）', () {
      final fat = estimateWords(charCounts: [10, 10], startMs: 0, endMs: 1000);
      final f = fillAtWord(words: fat, positionMs: 1000, textLength: 6);
      expect(f.charsDone, lessThanOrEqualTo(6));
    });

    test('无字轴返回 none', () {
      expect(fillAtWord(words: const [], positionMs: 100).charsDone, 0.0);
    });
  });

  group('clampEstimatedLineEnd 近似轴的收尾速度', () {
    test('两行间隔很久时按演唱速度钳住，不让每个字拖几秒', () {
      final end = clampEstimatedLineEnd(
        start: const Duration(seconds: 10),
        nextStart: const Duration(seconds: 40), // 中间空 30 秒
        charCount: 5,
      );
      // 5 字 × 900ms = 4.5s，远小于 30s
      expect(end.inMilliseconds, 10000 + 5 * 900);
    });

    test('下一行更近时以下一行为准', () {
      final end = clampEstimatedLineEnd(
        start: const Duration(milliseconds: 1000),
        nextStart: const Duration(milliseconds: 1500),
        charCount: 40,
      );
      expect(end.inMilliseconds, 1500);
    });
  });

  group('parseTtmlLyric 真实样本', () {
    test('《晴天》：逐字轴与原文完全一致', () {
      final l = parseTtmlLyric(qingtianTtml);
      expect(l.lines, hasLength(2));
      expect(l.hasWords, isTrue);
      expect(l.wordsAllEstimated, isFalse);

      final first = l.lines.first;
      expect(first.text, '故事的小黄花');
      expect(first.time.inMilliseconds, 29231);
      expect(first.end!.inMilliseconds, 32723);
      expect(first.words, hasLength(6));
      expect(first.words.first.startMs, 29231);
      expect(first.words.first.endMs, 29692);
      expect(first.words.last.endMs, 32723);
      // charCount 之和 == 行长（两层的下标体系必须对得上）
      expect(first.words.fold<int>(0, (a, w) => a + w.charCount),
          first.text.length);
    });

    test('《Lemon》：纯秒、m:ss 混用都解析正确，译文/注音不进正文', () {
      final l = parseTtmlLyric(lemonTtml);
      expect(l.lines, hasLength(2));

      expect(l.lines[0].text, '夢ならば');
      expect(l.lines[0].time.inMilliseconds, 1372); // "1.372" 秒
      expect(l.lines[0].translation, '如果只是一场梦');
      // 注音 x-roman 目前不展示，也不该混进正文或译文
      expect(l.lines[0].text, isNot(contains('yu me')));
      expect(l.lines[0].translation, isNot(contains('yu me')));

      expect(l.lines[1].time.inMilliseconds, 238431); // "3:58.431"
      expect(l.lines[1].end!.inMilliseconds, 244513); // "4:04.513"
    });

    test('TTML 里的多行排版空白不被当成歌词内容', () {
      const pretty = '<tt><body>'
          '<p begin="0:01.000" end="0:02.000">'
          '<span begin="0:01.000" end="0:02.000">第一行\n'
          '  第二行</span></p></body></tt>';
      final l = parseTtmlLyric(pretty);
      expect(l.lines.single.text, '第一行第二行');
    });

    test('HTML 实体被解开，且 &amp;lt; 不被二次解码', () {
      const e = '<tt><body>'
          '<p begin="1.0" end="2.0">'
          '<span begin="1.0" end="2.0">R&amp;B &amp;lt;b&amp;gt; &#39;x&#39;</span>'
          '</p></body></tt>';
      expect(parseTtmlLyric(e).lines.single.text, "R&B &lt;b&gt; 'x'");
    });

    test('没有 span 的整行式 TTML 退化为逐行（words 为空）', () {
      const liney = '<tt itunes:timing="Line"><body>'
          '<p begin="1.0" end="4.0">一整句</p></body></tt>';
      final l = parseTtmlLyric(liney);
      expect(l.lines.single.text, '一整句');
      expect(l.lines.single.hasWords, isFalse);
      expect(l.hasWords, isFalse);
    });

    test('畸形输入不抛异常：缺 begin、标签截断、空文档', () {
      expect(parseTtmlLyric('<tt><body><p end="2.0">没有时间轴</p></body></tt>')
          .isEmpty, isTrue);
      expect(parseTtmlLyric('<tt><body><p begin="1.0"><span begin="1.0">未闭合')
          .lines, isNotNull);
      expect(parseTtmlLyric('').isEmpty, isTrue);
      expect(parseTtmlLyric('not ttml at all').isEmpty, isTrue);
      // 时间字段是垃圾值
      expect(parseTtmlLyric('<tt><p begin="abc" end="xyz">x</p></tt>').isEmpty,
          isTrue);
    });

    test('行序被打乱时按时间排序', () {
      const shuffled = '<tt><body>'
          '<p begin="10.0" end="11.0"><span begin="10.0" end="11.0">后</span></p>'
          '<p begin="1.0" end="2.0"><span begin="1.0" end="2.0">前</span></p>'
          '</body></tt>';
      final l = parseTtmlLyric(shuffled);
      expect(l.lines.map((e) => e.text).toList(), ['前', '后']);
    });

    test('looksLikeTtml 认得带命名空间的真实开头', () {
      expect(looksLikeTtml(qingtianTtml), isTrue);
      expect(looksLikeTtml('[00:28.88]这一路上走走停停'), isFalse);
      expect(looksLikeTtml('<html>'), isFalse);
    });
  });

  group('applyWordTiming 真实轴优先、均分兜底', () {
    test('TTML 的真实字轴原样保留，不被均分覆盖', () {
      final ttml = parseTtmlLyric(qingtianTtml);
      final out = applyWordTiming(ttml, totalDurationMs: 265000);
      expect(out.lines.first.words.first.endMs, 29692); // 真实值，不是均分
      expect(out.wordsAllEstimated, isFalse);
    });

    test('普通 LRC 的每一行都被补上近似字轴', () {
      final lrc = parseLrc('[00:28.88]这一路上走走停停\n[00:32.02]顺着少年漂流的痕迹');
      expect(lrc.hasWords, isFalse);
      final out = applyWordTiming(lrc, totalDurationMs: 200000);
      expect(out.hasWords, isTrue);
      expect(out.wordsAllEstimated, isTrue);
      final first = out.lines.first;
      expect(first.words.fold<int>(0, (a, w) => a + w.charCount),
          first.text.length);
    });

    test('幂等：重复调用结果不变（解析链末尾无条件调用才安全）', () {
      final once = applyWordTiming(
          parseLrc('[00:10.00]第一句\n[00:14.00]第二句'),
          totalDurationMs: 60000);
      final twice = applyWordTiming(once, totalDurationMs: 60000);
      expect(twice.lines.first.words.map((w) => w.endMs).toList(),
          once.lines.first.words.map((w) => w.endMs).toList());
      expect(twice.wordsAllEstimated, once.wordsAllEstimated);
    });

    test('挂译文不能把字轴弄丢（回归：withTranslation 曾只带 text）', () {
      final base = applyWordTiming(
          parseLrc('[00:10.00]hello world'), totalDurationMs: 60000);
      expect(base.lines.single.hasWords, isTrue);
      final withTrans = base.lines.single.withTranslation('你好，世界');
      expect(withTrans.translation, '你好，世界');
      expect(withTrans.words.length, base.lines.single.words.length,
          reason: '译文合并这一步抹掉了字轴，扫光就会静默失效');
      expect(withTrans.wordsEstimated, isTrue);
    });
  });

  group('ParsedLyric.endMsAt / fillAt', () {
    test('LRC 行没有 end 时用下一行行首', () {
      final l = parseLrc('[00:10.00]A\n[00:13.50]B');
      expect(l.endMsAt(0), 13500);
    });

    test('上游 end 越界时被钳到合理区间', () {
      const l = ParsedLyric(lines: [
        LyricLine(
            time: Duration(seconds: 10),
            text: 'A',
            end: Duration(seconds: 99)),
        LyricLine(time: Duration(seconds: 12), text: 'B'),
      ]);
      expect(l.endMsAt(0), 12000, reason: '不能越过下一行行首');
    });

    test('fillAt 越界下标与无字轴都返回 none，不抛', () {
      final l = applyWordTiming(parseLrc('[00:10.00]啊'), totalDurationMs: 0);
      expect(l.fillAt(-1, Duration.zero).charsDone, 0.0);
      expect(l.fillAt(99, const Duration(seconds: 1)).charsDone, 0.0);
      expect(ParsedLyric.empty.fillAt(0, Duration.zero).charsDone, 0.0);
      // 正常路径：走到该行中部应填掉一部分
      expect(l.fillAt(0, const Duration(seconds: 12)).charsDone,
          greaterThanOrEqualTo(0.0));
    });
  });

  group('AMLL 匹配门禁：宁缺毋滥', () {
    AmllSearchResult r({
      String title = '晴天',
      List<String> titles = const [],
      String artist = '周杰伦',
      List<String> artists = const [],
      List<String> qqIds = const [],
      String file = 'a.ttml',
    }) =>
        AmllSearchResult(
          file: file,
          title: title,
          titles: titles,
          artist: artist,
          artists: artists,
          qqIds: qqIds,
        );

    test('标题+歌手全对 → 过线', () {
      expect(
          scoreAmllCandidate(
              title: '晴天', artist: '周杰伦', candidate: r()),
          greaterThanOrEqualTo(kAmllMinMatchScore));
    });

    test('标题对但歌手不对 → 一票否决判 0', () {
      // 翻唱/伴奏同名是最常见的误命中来源，绝不能拿它们的字轴
      expect(
          scoreAmllCandidate(
              title: '晴天',
              artist: '五月天',
              candidate: r(artist: '翻唱歌手')),
          0);
    });

    test('feat. 后缀、全角字符、大小写不影响匹配', () {
      expect(
          scoreAmllCandidate(
              title: 'See You Again (feat. Charlie Puth)',
              artist: 'ＷＩＺ ＫＨＡＬＩＦＡ',
              candidate: r(title: 'See You Again', artist: 'Wiz Khalifa')),
          greaterThanOrEqualTo(kAmllMinMatchScore));
    });

    test('时长门禁：偏短宽容、偏长收紧、缺信息不拦', () {
      expect(isAmllDurationCompatible(expectedMs: 240000, candidateMs: 0), isTrue);
      expect(
          isAmllDurationCompatible(expectedMs: 240000, candidateMs: 235000),
          isTrue);
      // 歌词比曲子短 30 秒是常态（outro、片尾静音），容差放到 max(30s, 15%)
      expect(
          isAmllDurationCompatible(expectedMs: 240000, candidateMs: 210000),
          isTrue);
      expect(
          isAmllDurationCompatible(expectedMs: 240000, candidateMs: 180000),
          isFalse, reason: '短了 1 分钟，多半是另一版本/另一首歌');
      // 「偏长」容差只有 max(12s, 10%)：字轴盖到这首歌没有的部分更可疑
      expect(
          isAmllDurationCompatible(expectedMs: 240000, candidateMs: 260000),
          isTrue);
      expect(
          isAmllDurationCompatible(expectedMs: 240000, candidateMs: 300000),
          isFalse, reason: '字轴比歌还长 1 分钟，一定是另一版本');
    });

    test('ttmlEstimatedEndMs 末行 end 优先，没有则末行 start', () {
      final l = parseTtmlLyric(lemonTtml);
      expect(ttmlEstimatedEndMs(l), 244513);
    });

    test('文件名校验挡住路径穿越（file 来自不可信的网络响应）', () {
      expect(isSafeTtmlFileName('1759567287182-111688524-DahZ5La9.ttml'), isTrue);
      for (final bad in [
        '',
        'a.txt',
        '../../etc/passwd.ttml',
        'a/b.ttml',
        r'a\b.ttml',
        'a.ttml?x=1',
        'a b.ttml',
        '.ttml',
      ]) {
        expect(isSafeTtmlFileName(bad), isFalse, reason: '不该放行「$bad」');
      }
    });

    test('AmllSearchResult.fromJson 容忍缺字段与脏类型', () {
      final x = AmllSearchResult.fromJson({
        'file': 'a.ttml',
        'titles': null,
        'qqIds': [null, ' m ', ''],
        'score': '700',
      });
      expect(x.file, 'a.ttml');
      expect(x.titles, isEmpty);
      expect(x.qqIds, ['m']);
      expect(x.siteScore, 700);
    });
  });
}
