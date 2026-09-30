/// 匹配算法用到的文本处理：归一化、模糊匹配、格式判定。
///
/// 独立成文件的原因：设计文档 4.6.2 的归一化规则相当细（去括号、去分隔符、
/// 去质量词后缀），且被六个维度中的三个直接依赖。混在打分代码里既难读
/// 也难单独验证——这里可以脱离网络、脱离 Flutter 直接跑单测。
library;

import 'dart:collection';

class TextNormalizer {
  TextNormalizer._();

  // 归一化会在一次匹配中被多个维度重复调用。
  // 使用小型 FIFO 缓存，避免反复 lowerCase / replaceAll / RegExp 扫描。
  static const int _normalizeCacheCap = 2048;
  static final Map<String, String> _normalizeCache = HashMap<String, String>();
  static final Queue<String> _normalizeOrder = Queue<String>();

  /// 括号类符号的字符类。
  ///
  /// ## 踩坑记录（务必保留 `]` 的转义）
  /// 第一版写成 `[【】\[\]（）...]`，跑起来**所有括号都匹配不上**。
  /// 原因是 Dart 里 `'\\[\\]'` → 正则看到 `\[\]`，但更早的一版误写成
  /// `[【】[]...]`——正则解析器遇到字符类里的 `[]` 会认为**空字符类**，
  /// 于是字符类在第一个 `]` 处提前闭合，后面的内容退化成字面量。
  /// 修法：字符类的第一个字符就是 `]`（此时 `]` 被当作普通字符），
  /// 或统一用 `\]` 转义。这里用转义，意图更直观。
  static final _brackets = RegExp(
    '[\u3010\u3011\\[\\]\uff08\uff09()\u300a\u300b<>'
    '\u300c\u300d\u300e\u300f\x22\x27\u201c\u201d\u2018\u2019]',
  );

  /// 归一化：小写 → 去括号类符号 → 去分隔符与空格 → 去质量词后缀。
  ///
  /// 对应设计文档 4.6.2 Step 1。注意顺序：必须先去括号符号再去分隔符，
  /// 否则 `【官方MV】` 会留下 `官方mv` 污染后续匹配。
  static String normalize(String s) {
    if (s.isEmpty) return '';
    final cached = _normalizeCache[s];
    if (cached != null) return cached;

    var r = s.toLowerCase();
    r = r.replaceAll(_brackets, '');
    // 去分隔符、空格、破折号类
    r = r.replaceAll(RegExp('[\\s_\\-\u2014\u2013\u00b7\u30fb|/\u3001]+'), '');
    // 去常见质量词 / 版本词后缀。
    //
    // ⚠ 语言差异：设计文档给的是 Kotlin 的 `Regex("(?i)(official|...)")`，
    // 但 **Dart 的 RegExp 不支持内联标志 `(?i)`**，照抄会抛
    // `FormatException: Invalid group`。Dart 里必须用 `caseSensitive: false`。
    // 好在这里前面已统一 lowercase，理论上不加也等价——但保留该参数
    // 是为了防止将来有人在 normalize 之前插入了大写内容。
    r = r.replaceAll(
      RegExp(
        '(official|hd|hq|mv|pv|audio|lyrics?|\u9ad8\u6e05|\u5b8c\u6574\u7248|\u65e0\u635f)',
        caseSensitive: false,
      ),
      '',
    );
    r = r.trim();

    if (_normalizeCache.length >= _normalizeCacheCap) {
      final oldest = _normalizeOrder.removeFirst();
      _normalizeCache.remove(oldest);
    }
    _normalizeCache[s] = r;
    _normalizeOrder.addLast(s);
    return r;
  }

  /// 是否为「A - B」标准格式。
  ///
  /// 分隔符**两侧都要求有空格**——这是关键：`A-Lin` 是歌手名，
  /// 不能被误判成「A 减 Lin」的标准格式。
  static final _standardFormat = RegExp('.+\\s+[-\u2013\u2014]\\s+.+');

  static bool hasStandardFormat(String title) =>
      _standardFormat.hasMatch(title);

  /// 模糊匹配（编辑距离）。
  ///
  /// 两道前置守卫避免短串误判：
  ///   1. 长度差 > 3 直接否定
  ///   2. 较短串 < 3 字直接否定（两个字以内的相似度没有统计意义）
  static bool isFuzzyMatch(String a, String b, double threshold) {
    if ((a.length - b.length).abs() > 3) return false;
    final minLen = a.length < b.length ? a.length : b.length;
    if (minLen < 3) return false;
    final dist = levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen == 0) return false;
    return 1.0 - dist / maxLen >= threshold;
  }

  /// 模糊包含：b 的某个等长子串与 a 相似度达标
  static bool fuzzyContains(String haystack, String needle, double threshold) {
    if (needle.isEmpty || haystack.isEmpty) return false;
    if (haystack.contains(needle)) return true;
    if (haystack.length < needle.length) {
      return isFuzzyMatch(haystack, needle, threshold);
    }
    // 滑动窗口：只在长度 ±2 的范围内试，控制复杂度
    for (var len = needle.length - 2; len <= needle.length + 2; len++) {
      if (len <= 0 || len > haystack.length) continue;
      for (var i = 0; i + len <= haystack.length; i++) {
        final sub = haystack.substring(i, i + len);
        if (isFuzzyMatch(sub, needle, threshold)) return true;
      }
    }
    return false;
  }

  /// 编辑距离（滚轮法，空间 O(min(m,n))）
  static int levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    // 让 b 为较短串，降低空间占用
    if (a.length < b.length) {
      final t = a;
      a = b;
      b = t;
    }

    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      var rowMin = curr[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = curr[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        var min = del < ins ? del : ins;
        if (sub < min) min = sub;
        curr[j] = min;
        if (min < rowMin) rowMin = min;
      }
      // 这里不知道调用方的阈值，因此不能直接返回；仅保留完整语义。
      // rowMin 的计算给后续 profiler 留下单一热点，避免额外分支改变结果。
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
  }

  /// 判断标题里是否含某个词（大小写不敏感）
  static bool containsIgnoreCase(String haystack, String needle) {
    if (needle.isEmpty) return false;
    return haystack.toLowerCase().contains(needle.toLowerCase());
  }
}
