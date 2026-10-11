/// LRC 歌词解析与歌词模型。
///
/// ## LRC 格式的实际坑
/// 标准 LRC 长这样：
/// ```
/// [00:00.00]起风了 (原版) - 买辣椒也用券
/// [00:06.42]词：米果
/// [00:07.92]曲：高桥优
/// [00:15.30]这一路上走走停停
/// ```
/// 但真实歌词文件里还有这些变体，全部要处理：
///
/// 1. **一行多个时间标签**：`[00:12.00][01:30.00]同样的词`
///    —— 副歌复用同一行文本时会出现，展开成两条。
/// 2. **时间戳精度不一**：`[00:12]` / `[00:12.5]` / `[00:12.50]` / `[00:12.500]`
///    都存在。用正则统一捕获 1~3 位小数。
/// 3. **元信息标签**：`[ti:歌名]` `[ar:歌手]` `[al:专辑]` `[by:xxx]`
///    —— 冒号后不是时间，必须排除，否则会被当成 0 分 0 秒的歌词行。
/// 4. **翻译歌词**：QQ音乐有时把中译和原文用同一时间轴给两遍。
///    这里按时间戳去重（后者丢弃），先保证不重影。
library;

import 'lyric_word.dart';

/// 一行歌词
class LyricLine {
  /// 该行开始显示的时间
  final Duration time;

  final String text;

  /// 译文（非华语歌才有，null 表示这行没有译文）。
  ///
  /// 单独挂在主行上、而不是做成第二份 `List<LyricLine>`：
  /// UI 的滚动定位依赖「一行一个固定高度」，两份列表就得在渲染时
  /// 再合并一次，反而多出错的机会。
  final String? translation;

  /// 逐字时间轴。空列表 = 这一行没有字级信息，只能整行高亮。
  ///
  /// 只存 `charCount`，不存每字文本，见 `lyric_word.dart` 的说明。
  final List<LyricWord> words;

  /// [words] 是不是「按行时长均分」推算出来的，而不是上游给的真实轴。
  ///
  /// UI 用它决定要不要在角落标「近似」。真实轴与均分轴的观感差别很大
  /// （均分跟不上演唱速度），不能让用户以为是准的。
  final bool wordsEstimated;

  /// 该行的结束时间，仅上游确实给了才有（TTML 的 `<p end="...">`）。
  ///
  /// null 表示未知——LRC 天生只有行首。调用方用「下一行行首」兜底，
  /// 见 [ParsedLyric.endMsAt]。
  final Duration? end;

  const LyricLine({
    required this.time,
    required this.text,
    this.translation,
    this.words = const [],
    this.wordsEstimated = false,
    this.end,
  });

  bool get hasWords => words.isNotEmpty;

  /// 返回挂上译文的副本（原对象不可变）。
  ///
  /// ⚠️ 必须把 words/end 一起带过去：挂译文发生在解析**之后**，
  /// 这里漏一个字段，逐字轴就会被译文流程静默抹掉。
  LyricLine withTranslation(String t) => LyricLine(
        time: time,
        text: text,
        translation: t,
        words: words,
        wordsEstimated: wordsEstimated,
        end: end,
      );

  /// 换一份字轴（用于补真实轴 / 均分兜底）。
  LyricLine withWords(List<LyricWord> newWords, {bool estimated = false}) =>
      LyricLine(
        time: time,
        text: text,
        translation: translation,
        words: newWords,
        wordsEstimated: estimated,
        end: end,
      );

  @override
  String toString() => '[${time.inMilliseconds}] $text';
}

/// 解析结果
class ParsedLyric {
  final List<LyricLine> lines;

  /// 原始 LRC 文本
  final String raw;

  /// 是否为纯音乐（QQ音乐用「此歌曲为没有填词的纯音乐」占位）
  final bool instrumental;

  const ParsedLyric({
    required this.lines,
    this.raw = '',
    this.instrumental = false,
  });

  static const empty = ParsedLyric(lines: []);

  bool get isEmpty => lines.isEmpty;

  /// 是否至少有一行带译文。
  ///
  /// UI 用它决定行高（双行 vs 单行）——必须**整份歌词统一**取值：
  /// 逐行变高会让「第 i 行的偏移 = i × 行高」这个定位公式失效。
  bool get hasTranslation =>
      lines.any((l) => l.translation != null && l.translation!.isNotEmpty);

  /// 按时间查找当前应高亮的行下标。
  ///
  /// 返回 -1 表示「还没到第一行的时间」（前奏期间），
  /// UI 应表现为"无高亮"而不是硬高亮第一行——
  /// 后者会让用户觉得歌词整体提前了。
  int indexAt(Duration position) {
    if (lines.isEmpty) return -1;
    final ms = position.inMilliseconds;
    if (ms < lines.first.time.inMilliseconds) return -1;
    // 线性扫描足够：歌词通常 50~120 行，且每秒只调一次。
    // 用二分反而增加出错面。
    var lo = 0, hi = lines.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time.inMilliseconds <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 是否有任何一行带逐字轴。决定 UI 走扫光还是老的整行高亮。
  bool get hasWords => lines.any((l) => l.hasWords);

  /// 逐字轴是不是**全部**推算出来的（没有一条真实轴）。
  ///
  /// 三态里只要有一行是真实轴就标 false：真实轴来自整份 TTML，
  /// 混合只可能出现在人工编辑过的歌词上，那种情况不该整体标「近似」。
  bool get wordsAllEstimated =>
      hasWords && lines.every((l) => !l.hasWords || l.wordsEstimated);

  /// 第 [index] 行的结束时间（LRC 时间空间的毫秒）。
  ///
  /// 优先用上游给的 [LyricLine.end]；没有就用下一行行首。
  /// 最后一行没有下一个锚点，[fallbackEndMs] 传音频总时长，
  /// 拿不到（0）时按演唱速度上限钳一个自然收尾时间，
  /// 否则末行的扫光会一路跑到歌.end 之外。
  int endMsAt(int index, {int fallbackEndMs = 0}) {
    if (index < 0 || index >= lines.length) return fallbackEndMs;
    final explicit = lines[index].end?.inMilliseconds;
    final next = index + 1 < lines.length
        ? lines[index + 1].time.inMilliseconds
        : null;
    if (explicit != null) {
      // 上游 end 可能是脏的（比下一行还晚、或早于行首），钳一下
      final start = lines[index].time.inMilliseconds;
      final upper = next ?? (fallbackEndMs > 0 ? fallbackEndMs : explicit);
      return explicit.clamp(start, upper > start ? upper : start);
    }
    if (next != null) return next;
    if (fallbackEndMs > 0) return fallbackEndMs;
    return clampEstimatedLineEnd(
      start: lines[index].time,
      nextStart: null,
      charCount: lines[index].text.length,
    ).inMilliseconds;
  }

  /// 某时刻这一行唱到哪了。无字轴时返回 [WordFill.none]。
  WordFill fillAt(int index, Duration position) {
    if (index < 0 || index >= lines.length) return WordFill.none;
    final line = lines[index];
    if (!line.hasWords) return WordFill.none;
    return fillAtWord(
      words: line.words,
      positionMs: position.inMilliseconds,
      textLength: line.text.length,
    );
  }
}

/// 时间标签。
///
/// 支持两种真实存在的写法：
///   - `[mm:ss.xx]`   —— 最常见
///   - `[hh:mm:ss.xx]` —— 长音频 / 电台节目里会出现
///
/// ⚠️ 必须把「带小时」的分支写在前面。否则 `[01:02:03]` 会被前面的
/// 短格式匹配成「1 分 02 秒」并把 `:03]` 当成未知尾部丢掉——
/// 结果是一条本该在 1 小时 02 分处的歌词被放到了 1 分 02 秒。
final _timeTag = RegExp(
  r'\[(?:(\d{1,3}):)?(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
);

/// 元信息标签：`[ti:xxx]` `[ar:xxx]` 等。
/// 只要 `[字母:...]` 且字母段不含数字，就不是时间标签。
final _metaTag = RegExp(r'^\[[a-zA-Z]+:.*\]$');

/// 纯音乐占位文案
const _instrumentalHints = [
  '纯音乐',
  '没有填词',
  '暂无歌词',
  '此歌曲为没有填词',
];

/// 解析 LRC 文本。
///
/// 不抛异常：任何解析不出来的行直接跳过。
/// 歌词是**装饰性数据**，为了它让播放失败不值得。
ParsedLyric parseLrc(String raw) {
  if (raw.trim().isEmpty) return ParsedLyric.empty;

  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  // 纯音乐占位：QQ音乐返回的是「此歌曲为没有填词的音乐，请您欣赏」这类
  if (_instrumentalHints.any((h) => text.contains(h)) && !_timeTag.hasMatch(text)) {
    return ParsedLyric(lines: const [], raw: raw, instrumental: true);
  }

  final collected = <LyricLine>[];
  final seen = <String>{};

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    // 排除元信息标签：整行就是 [ti:...] 这种
    if (_metaTag.hasMatch(line)) continue;

    final matches = _timeTag.allMatches(line).toList();
    if (matches.isEmpty) continue;

    // 去掉所有时间标签后剩下的才是歌词正文
    final content = line.replaceAll(_timeTag, '').trim();
    if (content.isEmpty) continue;

    for (final m in matches) {
      // 组 1=小时（可空） 组 2=分 组 3=秒 组 4=小数
      final hour = m.group(1) == null ? 0 : int.parse(m.group(1)!);
      final min = int.parse(m.group(2)!);
      final sec = int.parse(m.group(3)!);
      final frac = m.group(4);
      // 小数位按位数换算：".5" → 500ms，".50" → 500ms，".500" → 500ms
      final ms = switch (frac?.length) {
        1 => int.parse(frac!) * 100,
        2 => int.parse(frac!) * 10,
        3 => int.parse(frac!),
        _ => 0,
      };
      final time = Duration(
        hours: hour,
        minutes: min,
        seconds: sec,
        milliseconds: ms,
      );

      // 去重：同一时间戳只保留第一条（应对翻译歌词重复行）
      final dedupKey = '${time.inMilliseconds}';
      if (!seen.add(dedupKey)) continue;

      collected.add(LyricLine(time: time, text: content));
    }
  }

  if (collected.isEmpty) {
    return ParsedLyric(lines: const [], raw: raw);
  }

  collected.sort((a, b) => a.time.compareTo(b.time));
  return ParsedLyric(lines: collected, raw: raw);
}

/// 把 LRC 压成一行行纯文本（处理「同一时间多个标签」的展开后结果）
///
/// 用于「无时间轴的歌词」降级展示——有些平台的歌词没有时间戳，
/// 此时只能顺序展示，无法跟随滚动。
ParsedLyric parsePlainLyric(String raw) {
  final lines = <LyricLine>[];
  var i = 0;
  for (final l in raw.split('\n')) {
    final t = l.trim();
    if (t.isEmpty) continue;
    // 每行给 4 秒，纯粹为了「有个顺序」而不是真有时间
    lines.add(LyricLine(time: Duration(seconds: i * 4), text: t));
    i++;
  }
  return ParsedLyric(lines: lines, raw: raw);
}

/// 给没有字轴的行**按字数均分**补一份近似字轴。
///
/// ## 定位：真实轴之外的兜底，不是真实轴的替代
/// AMLL TTML 命中时用上游给的真实逐字轴（[LyricLine.words] 已填好，
/// 本函数对它们不做任何改动）；剩下约一半的歌只有逐行 LRC，
/// 这里按「行时长 ÷ 字数」给每个字分配时间，让扫光至少能跟着走。
///
/// ## 幂等
/// 重复调用结果一致（已有 words 的行直接跳过），所以可以放心地
/// 在解析链末尾无条件调一次。
///
/// ## 行尾时间
/// 用 [ParsedLyric.endMsAt] 取，其中「没有下一行」的末行按 [totalDurationMs]
/// 收口；总时长也不知道时按演唱速度钳一个自然收尾，
/// 避免末行扫光一路跑到歌外。
ParsedLyric applyWordTiming(ParsedLyric lyric, {int totalDurationMs = 0}) {
  if (lyric.isEmpty) return lyric;

  final out = <LyricLine>[];
  for (var i = 0; i < lyric.lines.length; i++) {
    final line = lyric.lines[i];
    if (line.hasWords) {
      out.add(line);
      continue;
    }
    if (line.text.trim().isEmpty) {
      out.add(line);
      continue;
    }
    final counts = tokenizeCharCounts(line.text);
    if (counts.isEmpty) {
      out.add(line);
      continue;
    }
    final startMs = line.time.inMilliseconds;
    final rawEndMs = lyric.endMsAt(i, fallbackEndMs: totalDurationMs);
    // 近似轴的行尾还要受「自然演唱速度」钳制：两行之间隔 30 秒时，
    // 直接按下一行均分会让每个字拖 3 秒，扫光慢得像卡住。
    final naturalEndMs = clampEstimatedLineEnd(
      start: line.time,
      nextStart: Duration(milliseconds: rawEndMs),
      charCount: counts.fold<int>(0, (a, b) => a + b),
    ).inMilliseconds;
    final endMs =
        naturalEndMs < rawEndMs ? naturalEndMs : rawEndMs;
    if (endMs <= startMs) {
      out.add(line);
      continue;
    }
    out.add(line.withWords(
      estimateWords(charCounts: counts, startMs: startMs, endMs: endMs),
      estimated: true,
    ));
  }
  return ParsedLyric(lines: out, raw: lyric.raw, instrumental: lyric.instrumental);
}
