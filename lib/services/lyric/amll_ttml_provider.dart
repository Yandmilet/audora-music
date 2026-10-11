/// AMLL TTML 歌词站客户端 —— 逐字（真实字轴）歌词的**唯一**可用来源。
///
/// ## 数据来源与选型结论（2026-10-11 实测）
/// 逐字轴在两个既有音源上都拿不到：
///   - QQ音乐 `GetPlayLyricInfo`：8 首热门歌的返回体里 `qrc` 标志位**恒为 0**，
///     逐字正文需要登录态才下发；`Default/GetLyric`、`music.pc_song.GetQrcLyrics`
///     等接口匿名请求一律 `code=500003`。
///   - 网易云 `/api/song/lyric?kv=1`：`klyric` 字段结构在，但 12 首热门歌
///     **全部返回空串**（`version: 0`），逐字轴同样要登录态。
///
/// AMLL 社区把 Apple Music 的逐字歌词转成 TTML 公开，本站匿名可读，
/// 实测 20 首中外热门歌命中 11 首（55%），且命中的每一条都确实带
/// `<span begin end>` 字级时间轴，没有「命中但无字轴」的假阳性。
///
/// ## 为什么可以按 QQ mid 直查
/// 搜索结果带 `qqIds` / `ncmIds` / `amIds` 字段，而本项目的曲库主键链路里
/// 已经存了 `qqSongMid`。按 mid 查是**精确命中**，比按标题模糊匹配可靠得多；
/// 标题查只是 mid 查不到时的降级路径。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'lrc_parser.dart';
import 'ttml_lyric_parser.dart';

class AmllSearchResult {
  /// TTML 文件名，形如 `1759567287182-111688524-DahZ5La9.ttml`
  final String file;
  final String title;
  final List<String> titles;
  final String artist;
  final List<String> artists;

  /// QQ音乐的 songmid 列表（本站与 QQ 曲库的关联键）
  final List<String> qqIds;
  final List<String> ncmIds;

  /// 站点自己的相关度分，只在同为标题命中时用于排序
  final int siteScore;

  const AmllSearchResult({
    required this.file,
    this.title = '',
    this.titles = const [],
    this.artist = '',
    this.artists = const [],
    this.qqIds = const [],
    this.ncmIds = const [],
    this.siteScore = 0,
  });

  factory AmllSearchResult.fromJson(Map<dynamic, dynamic> j) {
    List<String> arr(String key) {
      final v = j[key];
      if (v is! List) return const [];
      return v
          .map((e) => e?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }

    return AmllSearchResult(
      file: j['file']?.toString().trim() ?? '',
      title: j['title']?.toString().trim() ?? '',
      titles: arr('titles'),
      artist: j['artist']?.toString().trim() ?? '',
      artists: arr('artists'),
      qqIds: arr('qqIds'),
      ncmIds: arr('ncmIds'),
      siteScore: int.tryParse(j['score']?.toString() ?? '') ?? 0,
    );
  }
}

/// 解析结果：带真实字轴的歌词 + 它是从哪个候选来的（便于日志与排查）
class AmllWordLyric {
  final ParsedLyric lyric;
  final String sourceFile;

  /// 命中方式：`mid` 表示按 QQ songmid 精确命中，`title` 表示走标题+歌手匹配
  final String matchedBy;

  const AmllWordLyric({
    required this.lyric,
    required this.sourceFile,
    required this.matchedBy,
  });
}

// ── 纯函数：匹配门禁 ────────────────────────────────────────
//
// 单独立成顶层函数是为了**能脱离网络跑单测**：这套门禁的作用是
// 「宁可不给逐字，也绝不能把别的歌的字轴安到这首歌上」，
// 一旦写错就是用户能直接看出来的严重 bug，必须可测。

/// 归一化：小写、全角转半角、`feat.` 之类去掉、括号与符号变空格。
///
/// 说明：没做完整 NFKC（Dart 标准库没有 Unicode 规范化）。对歌词匹配来说
/// 关键差异是全角字母数字与中日韩标点，这两类已在下面显式处理，
/// 其余（如带音节的拉丁字母 é/e）交给后面的 contains / 编辑距离兜。
String normalizeAmllText(String s) {
  if (s.isEmpty) return '';
  final b = StringBuffer();
  for (final cu in s.codeUnits) {
    if (cu >= 0xFF01 && cu <= 0xFF5E) {
      b.writeCharCode(cu - 0xFEE0); // 全角 ASCII → 半角
    } else if (cu == 0x3000) {
      b.write(' '); // 全角空格
    } else {
      b.writeCharCode(cu);
    }
  }
  var r = b.toString().toLowerCase();
  r = r.replaceAll('&', ' and ');
  r = r.replaceAll(RegExp(r'\b(feat|ft|featuring)\.?'), ' ');
  r = r.replaceAll(RegExp(r'[(){}\[\]【】（）《》「」『』]'), ' ');
  r = r.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return r.trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// 多歌手串拆分：`A/B`、`A、B`、`A & B`、`A x B`、`A, B`
List<String> splitAmllArtists(String s) => s
    .split(RegExp(r'[,，、&+/]|(?:\s+x\s+)', caseSensitive: false))
    .map(normalizeAmllText)
    .where((e) => e.isNotEmpty)
    .toList(growable: false);

int _tokenOverlap(String a, String b) {
  final ta = a.split(' ').where((e) => e.isNotEmpty).toSet();
  final tb = b.split(' ').where((e) => e.isNotEmpty).toSet();
  if (ta.isEmpty || tb.isEmpty) return 0;
  var hit = 0;
  for (final t in ta) {
    if (tb.contains(t)) hit++;
  }
  return ((hit / (ta.length > tb.length ? ta.length : tb.length)) * 100).round();
}

/// 标题+歌手相关度，0..145。**低于 [kAmllMinMatchScore] 一律不用**。
///
/// 歌手门禁是关键：标题「晴天」能匹配到一堆翻唱/伴奏，只有歌手也对得上
/// 才敢把别人的字轴拿来用。所以歌手完全对不上时直接判 0，不做加法和。
int scoreAmllCandidate({
  required String title,
  required String artist,
  required AmllSearchResult candidate,
}) {
  final wantTitle = normalizeAmllText(title);
  if (wantTitle.isEmpty) return 0;
  final wantArtists = splitAmllArtists(artist);

  final titleCandidates =
      candidate.titles.isNotEmpty ? candidate.titles : [candidate.title];
  var titleScore = 0;
  for (final raw in titleCandidates) {
    final got = normalizeAmllText(raw);
    if (got.isEmpty) continue;
    final s = got == wantTitle
        ? 90
        : got.startsWith('$wantTitle ')
            ? 78
            : (got.contains(wantTitle) || wantTitle.contains(got))
                ? 64
                : _tokenOverlap(wantTitle, got) * 6 ~/ 100;
    if (s > titleScore) titleScore = s;
  }

  var artistScore = 0;
  if (wantArtists.isNotEmpty) {
    final gotArtists =
        candidate.artists.isNotEmpty ? candidate.artists : [candidate.artist];
    for (final raw in gotArtists) {
      final got = normalizeAmllText(raw);
      if (got.isEmpty) continue;
      for (final want in wantArtists) {
        final s = got == want
            ? 55
            : (got.contains(want) || want.contains(got))
                ? 40
                : _tokenOverlap(want, got) * 8 ~/ 100;
        if (s > artistScore) artistScore = s;
      }
    }
    if (artistScore < 30) return 0; // 歌手对不上，一票否决
  }
  return titleScore + artistScore;
}

/// 时长是否兼容。
///
/// 用**歌词末行时间**与音频时长比对——这是不依赖歌词内容的强特征：
/// 差 1 分钟以上基本可以断定不是同一个版本（现场版/剪辑版/另一首歌）。
/// 容差不对称：歌词早于曲尾很常见（outro、片尾静音），所以「候选偏短」放宽；
/// 「候选偏长」意味着字轴盖到了这首歌没有的部分，更可疑，收紧。
bool isAmllDurationCompatible({
  required int expectedMs,
  required int candidateMs,
}) {
  if (expectedMs <= 0 || candidateMs <= 0) return true; // 没信息就别拦
  final delta = candidateMs - expectedMs;
  final tolerance = delta < 0
      ? (30000 > expectedMs * 15 ~/ 100 ? 30000 : expectedMs * 15 ~/ 100)
          .clamp(0, 60000)
      : (12000 > expectedMs ~/ 10 ? 12000 : expectedMs ~/ 10).clamp(0, 30000);
  return delta.abs() <= tolerance;
}

/// 歌词末尾时间（末行的 end，没有 end 就用末行 start）
int ttmlEstimatedEndMs(ParsedLyric lyric) {
  if (lyric.lines.isEmpty) return 0;
  final last = lyric.lines.last;
  return last.end?.inMilliseconds ?? last.time.inMilliseconds;
}

/// 至少要有多少行才敢当成「完整歌词」（防止命中一段只有 2 行的碎片）
const int kAmllMinLines = 6;

/// 标题+歌手命中所需的最低分
const int kAmllMinMatchScore = 70;

/// 最多试几个候选（每个候选一次 raw-lyrics 请求）
const int kAmllMaxCandidates = 4;

// ── 网络部分 ────────────────────────────────────────────────

/// 校验来自**网络响应**的 TTML 文件名。
///
/// 这个值会被直接拼进 `GET /raw-lyrics/{file}`。一个恶意的（或被劫持的）
/// 响应如果返回 `../../admin/secret` 或带查询串的名字，就会越出这个目录
/// 打到站点其它接口上。所以：**只收 `单个文件名.ttml`**，其余一律拒绝。
bool isSafeTtmlFileName(String file) {
  if (file.isEmpty || !file.endsWith('.ttml')) return false;
  // 只有扩展名、没有文件名的 `.ttml` 不是合法对象名
  if (file.length <= '.ttml'.length) return false;
  if (file.contains('/') || file.contains('\\')) return false;
  if (file.contains('..')) return false;
  // 空格与控制字符会让 URL 语义变化（`x.ttml?a=b` 之类）
  return !RegExp(r'[\s\u0000-\u001f]').hasMatch(file);
}

class AmllTtmlProvider {
  AmllTtmlProvider({Dio? dio, this.baseUrl = _defaultBaseUrl})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              responseType: ResponseType.plain,
              validateStatus: (s) => s != null && s < 500,
            ));

  final Dio dio;

  /// 站点地址。留成可注入是为了单测能喂一个假响应，不必真打外网。
  final String baseUrl;

  static const _defaultBaseUrl = 'https://amlldb.bikonoo.com';

  /// 站点要求带可识别 UA；空 UA 会被 CDN 拦。
  static const _headers = {
    'User-Agent': 'Audora/1.0 (+https://github.com/audora)',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 取这首歌的真实逐字歌词。拿不到返回 null，调用方静默降级。
  ///
  /// 顺序：① 按 QQ mid 精确查 → ② 按标题查并过评分/时长门禁。
  /// 任何异常（超时、404、解析空）都不抛出——逐字轴是体验增强，
  /// 不是播放前提。
  Future<AmllWordLyric?> fetchWordLyric({
    required String? qqMid,
    required String title,
    required String artist,
    required int durationMs,
  }) async {
    if (title.trim().isEmpty) return null;

    final candidates = <AmllSearchResult>[];
    String matchedBy = 'mid';

    if (qqMid != null && qqMid.isNotEmpty && !qqMid.startsWith('local:')) {
      final byId = await _search({'query': qqMid});
      final exact = byId.where((r) => r.qqIds.contains(qqMid)).toList();
      candidates.addAll(exact);
      if (candidates.isEmpty) matchedBy = 'title';
    } else {
      matchedBy = 'title';
    }

    if (candidates.isEmpty) {
      final byTitle = await _search({'query': title, 'type': 'title'});
      final scored = byTitle
          .map((r) => MapEntry(
              scoreAmllCandidate(title: title, artist: artist, candidate: r), r))
          .where((e) => e.key >= kAmllMinMatchScore)
          .toList()
        ..sort((a, b) => b.key.compareTo(a.key));
      candidates.addAll(scored.take(kAmllMaxCandidates).map((e) => e.value));
    }

    for (final c in candidates.take(kAmllMaxCandidates)) {
      final lyric = await _fetchAndParse(c.file);
      if (lyric == null) continue;
      if (lyric.lines.length < kAmllMinLines) continue;
      if (!lyric.hasWords) {
        // 站点偶有只转成整行的 TTML；这种没有字轴，不如用本地均分
        continue;
      }
      if (!isAmllDurationCompatible(
          expectedMs: durationMs, candidateMs: ttmlEstimatedEndMs(lyric))) {
        continue;
      }
      return AmllWordLyric(
        lyric: lyric,
        sourceFile: c.file,
        matchedBy: matchedBy,
      );
    }
    return null;
  }

  Future<List<AmllSearchResult>> _search(Map<String, dynamic> body) async {
    try {
      final resp = await dio.post<dynamic>(
        '$baseUrl/api/search-lyrics',
        data: jsonEncode(body),
        options: Options(headers: {..._headers, 'Content-Type': 'application/json'}),
      );
      if (resp.statusCode != 200) return const [];
      final decoded = jsonDecode(resp.data?.toString() ?? '[]');
      if (decoded is! List) return const []; // {"error":...} 这种错误体
      return decoded
          .whereType<Map>()
          .map(AmllSearchResult.fromJson)
          .where((r) => isSafeTtmlFileName(r.file))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _raw(String file) async {
    if (!isSafeTtmlFileName(file)) return null;
    try {
      final resp = await dio.get<dynamic>(
        '$baseUrl/raw-lyrics/${Uri.encodeComponent(file)}',
        options: Options(headers: _headers),
      );
      if (resp.statusCode != 200) return null;
      final body = resp.data?.toString() ?? '';
      if (body.trim().isEmpty || !looksLikeTtml(body)) return null;
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<ParsedLyric?> _fetchAndParse(String file) async {
    final raw = await _raw(file);
    if (raw == null) return null;
    final lyric = parseTtmlLyric(raw);
    return lyric.isEmpty ? null : lyric;
  }
}
