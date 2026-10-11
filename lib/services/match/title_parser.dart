/// v0.4 标题结构解析（设计文档 §4）+ P1-3 接入评分链路。
///
/// P1-3 起正式接入：在 MatchScorer._titleArtistScore 里调用 parse()
/// 提取去标签后的干净标题 + `-` 分隔符拆分的 artist 段，作为两条辅助
/// 信号：titleParserBoost（标题主体确认）+ titleParserArtistBonus
/// （artist 精确拆分验证）。
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

  // P1-3: 改 static final，避免每次 parse() 调用都重新编译 regex。
  // parse() 现在在 score() 热路径上——每个候选、每次匹配都会调用。
  static final _tagReg = RegExp(r'[\[【(（].*?[\]】)）]');
  static final _kwReg = RegExp(
    r'官方MV|Official|HD|4K|完整版|高清|Live|Audio',
    caseSensitive: false,
  );

  static ParsedTitle parse(String input) {
    var text = input;
    final tags = <String>[];

    for (final match in _tagReg.allMatches(text)) {
      tags.add(match.group(0)!);
    }

    text = text.replaceAll(_tagReg, ' ');
    text = text.replaceAll(_kwReg, ' ');

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
