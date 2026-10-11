/// 逐字歌词的时间模型与算法。
///
/// ## 为什么 `LyricWord` 存的是「字符数」而不是「文本」
/// 逐字轴有两种存法：
///
/// 1. 每个字带自己的文本片段：`[LyricWord(text: '故'), LyricWord(text: '事')...]`
/// 2. 每个字只带**字符数**，整行文本仍是唯一真相源（本项目采用）
///
/// 第 2 种的好处是不存在「拼接后和原文对不上」这类 bug：TTML/增强 LRC 的字轴
/// 与显示文本天然分开，译文、注音、空格、代理对（emoji）都不参与时间计算。
/// 渲染时按 charCount 依次切片即可，[charCount] 之和恒等于行长度。
///
/// ## 精度说明
/// 所有时间都是 **LRC 时间空间的绝对毫秒**（不是相对行首的偏移），
/// 这样 `mappedLyricMs`（见 AppState 的 slope/offset 校准）可以直接比较，
/// 逐行与逐字走同一套坐标系，不需要二次换算。
library;

/// 一个「字 / 词」的时间区间。
class LyricWord {
  /// 起始绝对毫秒
  final int startMs;

  /// 结束绝对毫秒。保证 `>= startMs`。
  final int endMs;

  /// 该字在整行文本里占多少个 **UTF-16 code unit**。
  ///
  /// 用 code unit 而不是「字符个数」：切片用的是 `String.substring`，
  /// 两边必须是同一套下标，否则中英混排会错位。非 BMP 字符（emoji）
  /// 在这里就是 2，切分时也不会把一个代理对拆成两个字。
  final int charCount;

  const LyricWord({
    required this.startMs,
    required this.endMs,
    required this.charCount,
  });

  int get durationMs => endMs - startMs;

  @override
  String toString() => '[$startMs,$endMs] x$charCount';
}

/// 某一时刻，一行歌词「唱到哪里了」。
///
/// 拆成两个量而不是直接给百分比，是因为渲染端要的是**字符边界**：
/// 已唱完的整字数 + 当前这个字内部的推进比例，两者相加才是要填充的宽度。
class WordFill {
  /// 已完整唱完的字符数（UTF-16 code unit）
  final int filledChars;

  /// 当前字符内部已推进的比例，0..1
  final double partial;

  const WordFill({required this.filledChars, required this.partial});

  static const WordFill none = WordFill(filledChars: 0, partial: 0);

  /// 已唱完的字符数（含当前字的小数部分），用于算填充宽度
  double get charsDone => filledChars + partial.clamp(0.0, 1.0);

  @override
  String toString() => 'WordFill($filledChars + $partial)';
}

/// 判断 code point 是否「按字计」的文字（中日韩汉字、假名、韩文）。
///
/// 这些文字没有空格分隔，只能一个字一个字地给时间轴；
/// 拉丁文/西里尔/天城文等有词间空格的，按**单词**切更符合阅读直觉——
/// 逐字母填充会让英文看起来像在抽搐。
bool _isPerCharScript(int cp) =>
    // CJK 统一汉字 + 扩展 A + 兼容表意文字
    (cp >= 0x4E00 && cp <= 0x9FFF) ||
    (cp >= 0x3400 && cp <= 0x4DBF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    // 假名
    (cp >= 0x3040 && cp <= 0x30FF) ||
    (cp >= 0x31F0 && cp <= 0x31FF) ||
    // 韩文音节 / 字母区
    (cp >= 0xAC00 && cp <= 0xD7AF) ||
    (cp >= 0x1100 && cp <= 0x11FF);

/// 读 `i` 处的完整 code point（自动吃掉代理对的高位）。
int _codePointAt(String s, int i) {
  final c = s.codeUnitAt(i);
  if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
    final lo = s.codeUnitAt(i + 1);
    if (lo >= 0xDC00 && lo <= 0xDFFF) {
      return 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
    }
  }
  return c;
}

/// `i` 处这个 code point 占几个 UTF-16 code unit（代理对 = 2）。
int _unitsOfCp(String s, int i) {
  final c = s.codeUnitAt(i);
  if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
    final lo = s.codeUnitAt(i + 1);
    if (lo >= 0xDC00 && lo <= 0xDFFF) return 2;
  }
  return 1;
}

bool _isSpaceCp(int cp) =>
    cp == 0x20 ||
    cp == 0x09 ||
    cp == 0x0A ||
    cp == 0x0D ||
    cp == 0x3000 || // 全角空格
    cp == 0xA0 ||
    cp == 0x200B; // 零宽空格（歌词里真见过）

bool _isPunctuationCp(int cp) =>
    (cp >= 0x20 && cp <= 0x2F) ||
    (cp >= 0x3A && cp <= 0x40) ||
    (cp >= 0x5B && cp <= 0x60) ||
    (cp >= 0x7B && cp <= 0x7E) ||
    (cp >= 0x3001 && cp <= 0x303F) || // 、。〃〈〉《》「」『』【】〔〕
    (cp >= 0xFF01 && cp <= 0xFF0F) || // 全角 ！＂＃ … ＠ ［＼］＾＿｀
    (cp >= 0xFF1A && cp <= 0xFF20) ||
    (cp >= 0xFF3B && cp <= 0xFF40) ||
    (cp >= 0xFF5B && cp <= 0xFF65) ||
    cp == 0x2018 ||
    cp == 0x2019 ||
    cp == 0x201C ||
    cp == 0x201D ||
    cp == 0x2013 ||
    cp == 0x2014 ||
    cp == 0x2026;

/// 把一行文本切成「字 / 词」，返回每段的 code unit 数。
///
/// 规则（按优先级）：
///   1. 汉字 / 假名 / 韩文 —— 每字一段
///   2. 拉丁字母、数字等 —— 连续算一段（英文按单词）
///   3. 标点 —— 挂到**前一段**上（「花了。」里的「。」跟着「了」，不单独占一拍）
///   4. 空白 —— 挂到前一段上，并结束该段
///
/// 不变式：返回值之和 **恒等于** `text.length`。有单元测试兜着。
List<int> tokenizeCharCounts(String text) {
  if (text.isEmpty) return const [];

  final tokens = <int>[];
  var cur = 0; // 正在累积的这一段
  var i = 0;

  void flush() {
    if (cur > 0) {
      tokens.add(cur);
      cur = 0;
    }
  }

  while (i < text.length) {
    final cp = _codePointAt(text, i);
    final n = _unitsOfCp(text, i);

    if (_isSpaceCp(cp)) {
      // 空格跟在词尾，然后断段：'Cruel Angel' -> [6, 6]（含尾随空格）
      cur += n;
      flush();
    } else if (_isPerCharScript(cp)) {
      // 标点刚挂上来的段可以收走了
      flush();
      cur = n;
      // 紧接着的标点（，。「」）挂给这个字
      while (i + n < text.length &&
          _isPunctuationCp(_codePointAt(text, i + n))) {
        cur += _unitsOfCp(text, i + n);
        i += _unitsOfCp(text, i + n);
      }
      flush();
    } else if (cur > 0 && _isPunctuationCp(cp)) {
      cur += n; // 标点不另起一段
    } else {
      // 普通拉丁/数字：延续当前段；若前一段是汉字则天然已 flush
      cur += n;
    }
    i += n;
  }
  flush();
  return tokens;
}

/// 均分兜底：没有真实字轴时，按「行的时长 ÷ 字数」推算每个字的时间。
///
/// ## 权重
/// 每个字的权重就是它的字符数，所以英文里 `beautiful` 比 `it` 占更久——
/// 对纯中文来说每段都是 1，退化成了严格均分。
///
/// ## 累积误差
/// 用「累计权重 × 总时长」再整除的写法，而不是逐段 `+= span ~/ n`。
/// 后者会把整除丢掉的余数留在最后一段上，导致段与段之间抖动 1ms 级别的不均。
List<LyricWord> estimateWords({
  required List<int> charCounts,
  required int startMs,
  required int endMs,
}) {
  if (charCounts.isEmpty) return const [];
  final span = endMs - startMs;
  if (span <= 0) {
    // 行尾时间早于行首（数据坏了 / 只有最后一行且没有时长）：
    // 宁可不给字轴，也别造出一堆倒着走的时间。
    return const [];
  }

  var totalWeight = 0;
  for (final c in charCounts) {
    totalWeight += c;
  }
  if (totalWeight <= 0) return const [];

  final words = <LyricWord>[];
  var accWeight = 0;
  for (final count in charCounts) {
    final from = startMs + (span * accWeight) ~/ totalWeight;
    accWeight += count;
    // 最后一段强制对齐到行尾，保证 sum 覆盖整行、且时间单调不减
    final to = accWeight == totalWeight
        ? endMs
        : startMs + (span * accWeight) ~/ totalWeight;
    words.add(LyricWord(
      startMs: from,
      endMs: to < from ? from : to,
      charCount: count,
    ));
  }
  return words;
}

/// 把字符数切片成每段的 code unit 数（[words] 与 [charCounts] 等价时的快捷路径）。
List<int> charCountsOf(List<LyricWord> words) =>
    words.map((w) => w.charCount).toList(growable: false);

/// 计算某个时刻一行歌词唱到了哪里。
///
/// [textLength] 用来兜底：字轴总字符数与行长不一致（上游数据被截断等）时，
/// 把填充量钳到行长，避免 UI 算出超过 100% 的宽度。
WordFill fillAtWord({
  required List<LyricWord> words,
  required int positionMs,
  int? textLength,
}) {
  if (words.isEmpty) return WordFill.none;

  var chars = 0;
  for (final w in words) {
    if (positionMs >= w.endMs) {
      chars += w.charCount;
      continue;
    }
    if (positionMs <= w.startMs) {
      return _clampFill(WordFill(filledChars: chars, partial: 0), textLength);
    }
    final span = w.endMs - w.startMs;
    final p = span <= 0 ? 1.0 : (positionMs - w.startMs) / span;
    return _clampFill(
        WordFill(filledChars: chars, partial: p.clamp(0.0, 1.0)), textLength);
  }
  // 走到这里说明每个字都已完整唱完：filledChars 已经是总字数，
  // partial 必须是 0。写成 1.0 会多算一个字符，UI 上表现为
  // 填充宽度超出末字右边界（长行会顶到容器边缘）。
  return _clampFill(WordFill(filledChars: chars, partial: 0), textLength);
}

WordFill _clampFill(WordFill f, int? textLength) {
  if (textLength == null) return f;
  if (f.charsDone <= textLength) return f;
  // 钳位后同样保持「partial 属于下一个字」的口径：整行唱完 = (行长, 0)
  return WordFill(filledChars: textLength, partial: 0);
}

/// 逐字歌词的合理性钳位：估算一行的**结束**时间。
///
/// ## 为什么不能直接拿下一行的开始当行尾
/// LRC 只有行首。副歌重复、间奏拉长时，两行之间能隔 30 秒——
/// 均分出来的「每字 3 秒」会让扫光慢到看不出在动，用户以为卡住了。
/// 所以给一个「正常演唱速度」的上下限，超出就钳住：
/// 唱完就停在末字，等下一行出现（这也是 Apple Music 的行为）。
///
/// 参数是按中文流行歌的常见语速定的：单字 220ms 太快、900ms 太慢。
Duration clampEstimatedLineEnd({
  required Duration start,
  required Duration? nextStart,
  required int charCount,
  Duration minSpan = const Duration(milliseconds: 1200),
  Duration maxSpanPerChar = const Duration(milliseconds: 900),
}) {
  final byChars = Duration(
      milliseconds: (charCount < 1 ? 1 : charCount) * maxSpanPerChar.inMilliseconds);
  final natural = start + (byChars < minSpan ? minSpan : byChars);
  if (nextStart == null) return natural;
  return nextStart < natural ? nextStart : natural;
}
