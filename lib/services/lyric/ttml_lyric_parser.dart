/// AMLL TTML（Apple Music 逐字歌词）解析。
///
/// ## 为什么需要它
/// QQ音乐的公开歌词接口只给逐行 LRC：实测 `GetPlayLyricInfo` 返回体里的
/// `qrc` 标志位对热门歌恒为 0，逐字正文要登录态才下发；网易的 `klyric`
/// 字段匿名请求下也是空串（`version: 0`）。也就是说**逐字轴拿不到**。
///
/// AMLL 社区把 Apple Music 的逐字歌词转成了 TTML 并公开，形如：
/// ```xml
/// <tt itunes:timing="Word"><body>
///   <p begin="00:29.231" end="00:32.723">
///     <span begin="00:29.231" end="00:29.692">故</span>
///     <span begin="00:29.692" end="00:30.057">事</span>
///     <span ttm:role="x-translation">故事的小黄花</span>
///   </p>
/// </body></tt>
/// ```
/// 一个 `<span>` 就是一个字的真实起止时间——这正是逐字歌词需要的东西。
///
/// ## 为什么用正则而不是 XML 解析器
/// TTML 严格说是 XML，要处理命名空间、嵌套、实体、`<br/>`。但歌词这一份子集
/// 结构异常规整（`body > div? > p > span`，无嵌套元素），而 pubspec 里没有
/// XML 依赖；为装饰性数据引入一个解析器依赖不划算。
/// 代价是：**畸形输入会被逐条跳过而不是报错**，这与 [parseLrc] 的策略一致。
library;

import 'lyric_word.dart';
import 'lrc_parser.dart';

/// `<p ...>...</p>`（含 div 里的、body 直接下的）
final _pTag = RegExp(r'<p\b([^>]*)>(.*?)</p\s*>', dotAll: true);

/// `<p>` 内的 `<span ...>text</span>`；也容忍 `<word>` 这种变体写法
final _spanTag =
    RegExp(r'<(span|word)\b([^>]*)>(.*?)</\s*(span|word)\s*>', dotAll: true);

/// 属性抓取：`begin="..."` / `end="..."` / `ttm:role="..."`
final _beginAttr = RegExp(r'\b(?:ttm:)?begin\s*=\s*"([^"]*)"');
final _endAttr = RegExp(r'\b(?:ttm:)?end\s*=\s*"([^"]*)"');
final _roleAttr = RegExp(r'\bttm:role\s*=\s*"([^"]*)"');

/// TTML 时间表达式。按优先级排列，先匹配长的：
///   `00:04:04.513` 全时钟      → h:m:s.f
///   `4:04.513` / `00:29.231`   → m:s.f（**最常见**）
///   `29.231`                   → 纯秒
/// 小数点允许用 `.` 或 `:`（TTML 里 `00:29:231` 是 29.231 秒的合法写法）。
final _clockHMS = RegExp(r'^(\d{1,3}):(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?$');
final _clockMS = RegExp(r'^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$');
final _plainSeconds = RegExp(r'^(\d+)(?:[.:](\d{1,3}))?$');

/// 布局换行：TTML 常被格式化输出成多行，`</span>\n  <span` 之间的空白
/// 是排版用的，不是歌词内容。
final _layoutWs = RegExp(r'[\r\n]\s*');

/// 残余标签（span 里偶发的 `<br/>` 等）
final _anyTag = RegExp(r'<[^>]*>');

/// 解析 TTML 歌词。失败/不认的结构直接跳过，不抛异常。
///
/// 返回的 [ParsedLyric.raw] 是原始 TTML，便于「重新解析」时不必再联网。
ParsedLyric parseTtmlLyric(String raw) {
  if (raw.trim().isEmpty) return ParsedLyric.empty;

  final lines = <LyricLine>[];
  for (final p in _pTag.allMatches(raw)) {
    final attrs = p.group(1) ?? '';
    final body = p.group(2) ?? '';

    final startMs = _parseTtmlTime(_beginAttr.firstMatch(attrs)?.group(1));
    if (startMs == null) continue; // 没有行首时间就没有定位锚点，整行丢弃
    final endMs = _parseTtmlTime(_endAttr.firstMatch(attrs)?.group(1));

    final words = <LyricWord>[];
    final timed = StringBuffer();
    final plain = StringBuffer();
    String? translation;

    for (final s in _spanTag.allMatches(body)) {
      final sAttrs = s.group(2) ?? '';
      final text = _clean(s.group(3) ?? '');
      if (text.isEmpty) continue;

      final role = _roleAttr.firstMatch(sAttrs)?.group(1);
      if (role != null) {
        // x-translation 是译文；x-roman 是注音，本项目暂不展示注音。
        // 同角色出现多段时拼接（有些行译文被拆成几段）。
        if (role == 'x-translation') {
          translation = (translation ?? '') + text;
        }
        continue;
      }

      final wStart = _parseTtmlTime(_beginAttr.firstMatch(sAttrs)?.group(1));
      final wEnd = _parseTtmlTime(_endAttr.firstMatch(sAttrs)?.group(1));
      if (wStart == null || wEnd == null) {
        // 没有时间属性的正文 span：属于「整行一条」的写法，累进 plain
        plain.write(text);
        continue;
      }
      timed.write(text);
      words.add(LyricWord(
        startMs: wStart,
        endMs: wEnd < wStart ? wStart : wEnd,
        charCount: text.length,
      ));
    }

    final text = words.isNotEmpty
        ? timed.toString()
        : _clean(plain.toString().isEmpty
            ? body.replaceAll(_anyTag, '')
            : plain.toString());
    if (text.trim().isEmpty) continue;

    lines.add(LyricLine(
      time: Duration(milliseconds: startMs),
      text: text,
      translation: (translation ?? '').trim().isEmpty ? null : translation!.trim(),
      words: words,
      wordsEstimated: false,
      end: endMs == null ? null : Duration(milliseconds: endMs),
    ));
  }

  if (lines.isEmpty) return ParsedLyric(lines: const [], raw: raw);
  lines.sort((a, b) => a.time.compareTo(b.time));
  return ParsedLyric(lines: lines, raw: raw);
}

/// 是不是 TTML 文本。只看 `<tt` 开头标签，和 NeriPlayer 的判定同构。
bool looksLikeTtml(String raw) =>
    RegExp(r'<\s*tt(?:\s|>|/)', caseSensitive: false).hasMatch(raw);

/// 解析 TTML 时间表达式 → 毫秒。认不出来返回 null。
///
/// 注意 `00:29.231` 与 `4:04.513` 都是 **分:秒**，不是 时:分。
/// 三段式才是 时:分:秒。把两段式误读成 时:分 会让整首歌的歌词挤进前 6 分钟。
int? _parseTtmlTime(String? expr) {
  final s = expr?.trim();
  if (s == null || s.isEmpty) return null;
  // 带 `t`（帧）或 `ms` 后缀的写法极少见，剥掉再解析
  final body = s.endsWith('ms')
      ? s.substring(0, s.length - 2)
      : (s.contains('t') ? s.split('t').first : s);

  if (body.startsWith('h[') || body.contains('[')) return null; // 非标准计数式

  final hms = _clockHMS.firstMatch(body);
  if (hms != null) {
    return _ms(h1: hms.group(1), m: hms.group(2), s: hms.group(3), f: hms.group(4));
  }
  final ms = _clockMS.firstMatch(body);
  if (ms != null) {
    return _ms(m: ms.group(1), s: ms.group(2), f: ms.group(3));
  }
  final sec = _plainSeconds.firstMatch(body);
  if (sec != null) {
    return _ms(s: sec.group(1), f: sec.group(2));
  }
  return null;
}

int _ms({String? h1, String? m, String? s, String? f}) {
  int p(String? v, [int d = 0]) => v == null ? d : int.parse(v);
  // 小数位按位数换算：`.5`→500ms、`.23`→230ms、`.231`→231ms
  final frac = switch (f?.length) {
    1 => p(f) * 100,
    2 => p(f) * 10,
    3 => p(f),
    _ => 0,
  };
  return ((p(h1) * 60 + p(m)) * 60 + p(s)) * 1000 + frac;
}

/// 清掉排版空白、解开 HTML 实体、去掉残余标签。
String _clean(String raw) {
  var t = raw.replaceAll(_layoutWs, '');
  t = t.replaceAll(_anyTag, '');
  return _decodeEntities(t).trim();
}

final _numericEntity = RegExp(r'&#x([0-9a-fA-F]+);|&#(\d+);');

String _decodeEntities(String s) {
  var out = s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
  // `&amp;` 必须最后解，否则 `&amp;lt;` 会被解两次变成 `<`
  out = out.replaceAll('&amp;', '&');
  return out.replaceAllMapped(_numericEntity, (m) {
    final cp = m.group(1) != null
        ? int.tryParse(m.group(1)!, radix: 16)
        : int.tryParse(m.group(2)!);
    if (cp == null || cp <= 0 || cp > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(cp);
  });
}
