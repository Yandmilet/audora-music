/// 歌词翻译：语种判定 + 译文轨对齐。
///
/// ## 为什么单独一个文件
/// 这两件事都属于「翻译」这一条**新增**的支线，与 LRC 语法解析
/// （`lrc_parser.dart`）无关。混进去会让解析器承担两种职责，
/// 而且翻译这块后面大概率还要加源（酷狗 / 罗马音），独立放好扩展。
///
/// ## 数据来源现状（2026-09-29 实测）
/// QQ音乐的歌词接口 `GetPlayLyricInfo` **确实有** `trans` 字段，
/// 但匿名请求下 15 首热门外语歌（Lemon / See You Again / Dynamite …）
/// 的 `trans` **全部为空字符串**——翻译要登录态，客户端拿不到。
/// 网易云的 `/api/song/lyric` 匿名可返回 `tlyric`（中文译文），
/// 因此译文走网易补充，原文仍走 QQ（与 songMid 绑定，无需二次搜索）。
library;

import 'lrc_parser.dart';

/// 判定一段歌词正文是否为**非华语**。
///
/// 只在正文行上判定（传进来的应是已去掉时间标签的文本），
/// 否则 `[ti:起风了]` 这类元信息行的汉字会把中文歌判成中文倒是没问题，
/// 但会让「英文歌 + 中文歌名」的比例失真。
///
/// 判定顺序（先特殊后一般）：
///   1. 含日文假名 / 韩文谚文 → 非华语（日语、韩语歌里也有汉字，
///      只看汉字比例会把《Lemon》判成中文歌——这是最容易被坑的一处）
///   2. 汉字占比低于 [_hanRatioThreshold] → 非华语（拉丁语系等）
bool looksNonChinese(Iterable<String> lines) {
  var han = 0;
  var kanaHangul = 0;
  var total = 0;

  for (final line in lines) {
    for (final cu in line.codeUnits) {
      if (cu == 0x20 || cu == 0x09) continue; // 空白不计入
      total++;
      if (_isHan(cu)) {
        han++;
      } else if (_isKana(cu) || _isHangul(cu)) {
        kanaHangul++;
      }
    }
  }
  if (total == 0) return false;

  // 日语/韩语：只要有稳定比例的假名/谚文就足够定性
  if (kanaHangul / total > 0.05) return true;

  return han / total < _hanRatioThreshold;
}

/// 汉字占比阈值：低于它认为「这不是中文歌」。
///
/// 取 0.2 而不是 0.5，是因为外语歌的正文里也常夹汉字（日文歌名、
/// 「ah——」之类的语气词），但**成句**的中文歌词汉字比例远高于 0.2。
const double _hanRatioThreshold = 0.2;

bool _isHan(int cu) =>
    (cu >= 0x3400 && cu <= 0x4DBF) ||
    (cu >= 0x4E00 && cu <= 0x9FFF) ||
    (cu >= 0xF900 && cu <= 0xFAFF);

bool _isKana(int cu) => (cu >= 0x3040 && cu <= 0x30FF) || (cu >= 0x31F0 && cu <= 0x31FF);

bool _isHangul(int cu) =>
    (cu >= 0xAC00 && cu <= 0xD7AF) ||
    (cu >= 0x1100 && cu <= 0x11FF) ||
    (cu >= 0x3130 && cu <= 0x318F);

/// 创作者 / 制作信息行。
///
/// 网易的译文轨**头部也带** `作词 : xxx` `Produced by : xxx` 这类行，
/// 时间戳都是 0 附近。它们不是歌词，却会占掉对齐名额、把真正的译文
/// 挤到后面一行去——必须过滤。
final _creditLine = RegExp(
  r'^\s*(作词|作曲|编曲|制作人|监制|词|曲|词曲|歌词|翻译|歌词来源|'
  r'lyrics?\s*by|composed\s*by|written\s*by|arranged\s*by|produced\s*by|'
  r'music\s*by|words\s*by|op|ed)\s*[:：]',
  caseSensitive: false,
);

/// 「短标签 + 冒号」的标注行：`Charlie Puth：` / `Drums：David Stewart`。
///
/// 外语歌的 LRC 里这类行特别多（制作分工、演唱者切换提示），
/// 它们不是歌词，却是**对齐错位的头号来源**——译文轨没有对应的行，
/// 一旦让它们参与配对，后面整段译文都会往前串一格。
final _labelLine = RegExp(r'^[^：:]{1,20}[：:]');

/// 整行被括号包住的声明行：`（未经著作人许可，不得翻唱、翻录或使用）`
final _parenWholeLine =
    RegExp(r'^[（(\[【][^）)\]】]*[）)\]】]$');

/// 这一行是否是「真正的歌词正文」。
///
/// 只影响**配不配译文**，不影响这行显不显示：
/// 元信息行一直在 UI 上留着（既有行为），只是不给它挂译文。
bool isLyricBodyLine(LyricLine line) {
  final t = line.text.trim();
  if (t.isEmpty) return false;
  if (_creditLine.hasMatch(t)) return false;
  if (_labelLine.hasMatch(t)) return false;
  if (_parenWholeLine.hasMatch(t)) return false;
  // 0 秒处的「歌名 - 歌手」标题行（几乎每首歌都有）
  if (line.time.inMilliseconds == 0 && t.contains(' - ')) return false;
  return true;
}

/// 把译文轨按时间轴挂到原文歌词上。
///
/// ## 对齐策略：容差内贪心 + 一步前瞻
/// 两个源的时间戳实测只差 200~500ms（网易略早），所以用时间就近配对即可。
/// 难点在于**两个源的分句不一样**：网易常把
/// ```
/// Damn who knew / All the planes we flew / Good things we been through
/// ```
/// 三句合成两句译文。此时「差 1.2s 但也在容差内」的配对是错的——
/// 那条译文其实属于**下一行**（只差 0.38s）。所以每次配对前先看一眼
/// 下一行正文：如果它更接近当前译文，就把译文留给下一行（[前瞻]）。
/// 没有这一步，中段会整片串行（See You Again 实测）。
///
/// 一条译文只服务一行原文，绝不重复使用——否则会出现
/// 「同一句中文跟着不同的英文」这种一眼可见的错误。
///
/// [tolerance] 是允许的时间偏差。太大（>3s）会让相邻行互串，
/// 太小（<0.5s）会因两源取整差异大面积匹配不上。1.5s 是实测折中。
ParsedLyric attachTranslation(
  ParsedLyric main,
  String? transLrc, {
  Duration tolerance = const Duration(milliseconds: 1500),
}) {
  if (main.isEmpty) return main;
  if (transLrc == null || transLrc.trim().isEmpty) return main;

  final trans = parseLrc(transLrc)
      .lines
      .where((l) => !_creditLine.hasMatch(l.text))
      .toList();
  if (trans.isEmpty) return main;

  final tolMs = tolerance.inMilliseconds;
  final out = <LyricLine>[];
  var ti = 0;

  for (var i = 0; i < main.lines.length; i++) {
    final m = main.lines[i];
    final mms = m.time.inMilliseconds;

    // 丢掉已经"过期"的译文行：它比当前原文行早出容差范围，
    // 说明原文轨在这里有译文轨没有的内容（间奏、哼唱等）。
    while (ti < trans.length && trans[ti].time.inMilliseconds + tolMs < mms) {
      ti++;
    }
    if (ti >= trans.length) {
      out.add(m);
      continue;
    }

    final diff = (trans[ti].time.inMilliseconds - mms).abs();
    if (diff > tolMs || !isLyricBodyLine(m)) {
      // 元信息行不消耗译文：网易常把两句原文合成一条译文，
      // 若被标题行吃掉，第一句正文就永远配不上它。留给下一行正文。
      out.add(m);
      continue;
    }

    // 前瞻：下一条正文行是否更适合这条译文？
    final nextMs = _nextBodyTime(main.lines, i + 1);
    if (nextMs != null &&
        (trans[ti].time.inMilliseconds - nextMs).abs() < diff) {
      out.add(m);
      continue;
    }

    final t = trans[ti].text;
    ti++;
    // 译文与原文一模一样时不展示：中文歌被误判、或译文轨直接抄原文，
    // 两行重复的字比没有译文更奇怪。
    if (t != m.text) {
      out.add(m.withTranslation(t));
      continue;
    }
    out.add(m);
  }

  return ParsedLyric(
    lines: out,
    raw: main.raw,
    instrumental: main.instrumental,
  );
}

/// 从 [from] 开始找下一条正文行的时间（毫秒）；没有则返回 null。
///
/// 跳过元信息行是必要的：正文之间常夹着「Charlie Puth：」这种提示行，
/// 若把它当"下一行"来判断前瞻，就会误以为后面没有更合适的行。
int? _nextBodyTime(List<LyricLine> lines, int from) {
  for (var i = from; i < lines.length; i++) {
    if (isLyricBodyLine(lines[i])) return lines[i].time.inMilliseconds;
  }
  return null;
}
