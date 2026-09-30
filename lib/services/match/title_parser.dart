/// v0.4 标题结构解析（设计文档 §4）。
///
/// ## ⚠️ 当前状态：备用件，未接入评分链路
/// 设计意图是从 B 站标题提取 `artist / title / tags` 三段结构。
/// 经与 V0.3 实现逐条对照，暂不接入的理由：
///   1. **标题维度**：V0.3 的 `contains` 子串匹配天然不受前缀标签
///      （【4K修复】官方MV）影响，清理标签无增益；
///   2. **歌手维度**：`split('-')` 取首段做 artist 有真实误拆风险
///      （歌名含连字符「A-Train」、「歌手 - 歌名」拆反变体），
///      且 V0.3 的 `_artistScore` 已用 contains 对称覆盖
///      「歌手出现在标题任意位置」，增益无标定数据支撑；
///   3. **tags 用途**：VersionDetector 直接在原始标题上 contains 判定
///      （tags 本就是标题子集），无需预提取。
/// 待人工标注样本证明「歌手独立评分」有真实收益后，再启用
/// （启用点：`MatchScorer._artistScore` 增加解析 artist 精确比对路径）。
class ParsedTitle {
  final String title;
  final String artist;
  final List<String> tags;

  const ParsedTitle({
    required this.title,
    required this.artist,
    required this.tags,
  });
}

class TitleParser {
  TitleParser._();

  static ParsedTitle parse(String input) {
    var text = input;
    final tags = <String>[];

    final tagReg = RegExp(r'[\[【(（].*?[\]】)）]');
    for (final match in tagReg.allMatches(text)) {
      tags.add(match.group(0)!);
    }

    text = text.replaceAll(tagReg, ' ');
    text = text.replaceAll(
      RegExp(
        r'官方MV|Official|HD|4K|完整版|高清|Live|Audio',
        caseSensitive: false,
      ),
      ' ',
    );

    String title = text.trim();
    String artist = '';

    if (title.contains('-')) {
      final parts = title.split('-');
      artist = parts.first.trim();
      title = parts.sublist(1).join('-').trim();
    }

    return ParsedTitle(
      title: title,
      artist: artist,
      tags: tags,
    );
  }
}
