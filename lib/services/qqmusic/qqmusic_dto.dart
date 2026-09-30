/// QQ音乐 DTO 与「DTO → domain Song」的映射。
library;

import '../../models/models.dart';

/// QQ音乐搜索结果 / 详情结果的统一中间表示。
///
/// 搜索接口与详情接口字段名不同，这里做归一化；
/// 两个来源都缺的字段（作词/作曲/编曲）留空，由歌词解析补齐。
class QQSongMeta {
  /// 歌曲唯一标识（去重键）
  final String songMid;

  final String title;
  final List<String> artists;
  final String album;

  /// 专辑 mid，用于拼封面 URL
  final String albumMid;

  /// 时长（秒）
  final int interval;

  /// 发行日期
  final DateTime? releaseDate;

  /// 副标题（形如「原曲：《ヤキモチ》—高桥优」）
  final String subtitle;

  const QQSongMeta({
    required this.songMid,
    required this.title,
    required this.artists,
    this.album = '',
    this.albumMid = '',
    this.interval = 0,
    this.releaseDate,
    this.subtitle = '',
  });

  /// 从搜索接口的 song 对象构造。
  ///
  /// 实测字段：
  ///   songmid / songname / singer[{name}] / albumname / albummid /
  ///   interval(秒) / pubtime(秒级时间戳)
  factory QQSongMeta.fromSearchJson(Map<String, dynamic> json) {
    final singers = <String>[];
    final rawSinger = json['singer'];
    if (rawSinger is List) {
      for (final s in rawSinger) {
        if (s is Map) {
          final name = s['name']?.toString() ?? '';
          if (name.isNotEmpty) singers.add(name);
        }
      }
    }

    return QQSongMeta(
      songMid: json['songmid']?.toString() ?? '',
      title: _clean(json['songname']?.toString() ?? ''),
      artists: singers,
      album: _clean(json['albumname']?.toString() ?? ''),
      albumMid: json['albummid']?.toString() ?? '',
      interval: _toInt(json['interval']),
      releaseDate: _parseUnixSeconds(json['pubtime']),
      subtitle: json['lyric']?.toString() ?? '',
    );
  }

  /// 从**目录类接口**的 song 对象构造（榜单详情 / 歌手歌曲 / 歌单详情共用）。
  ///
  /// ## 为什么要单独写一个容错解析
  /// 目录类接口有**两套字段命名**同时在线，而且会随接口新老版本混用：
  ///
  /// | 语义 | 新版（musicu.fcg） | 老版（c.y.qq.com） |
  /// |---|---|---|
  /// | 歌曲 mid | `mid` | `songmid` |
  /// | 标题 | `title` / `name` | `songname` |
  /// | 专辑 | `album: {mid, name}` | `albummid` / `albumname` |
  ///
  /// 只按其中一套写，换个榜单/换个入口就会静默拿到空 mid ——
  /// 而空 mid 会让入库退化成 `local:` 派生键，歌词从此取不到（E23 那类
  /// 静默失败）。所以这里**两套都认**，拿不到就如实留空。
  ///
  /// ⚠️ 榜单**列表**接口（GetAll）的预览歌曲是第三套形状，且**不给 mid**，
  /// 见 `ToplistPreviewRow` 的注释。
  factory QQSongMeta.fromCatalogJson(Map<String, dynamic> j) {
    final artists = <String>[];
    final rawSinger = j['singer'];
    if (rawSinger is List) {
      for (final s in rawSinger) {
        if (s is Map) {
          final name = s['name']?.toString() ?? '';
          if (name.isNotEmpty) artists.add(name);
        }
      }
    }

    // 专辑：新版是嵌套对象，老版是两个平铺字段
    final albumObj = j['album'];
    var albumMid = '';
    var albumName = '';
    if (albumObj is Map) {
      albumMid = albumObj['mid']?.toString() ?? '';
      albumName = albumObj['name']?.toString() ?? '';
    }
    if (albumMid.isEmpty) albumMid = j['albummid']?.toString() ?? '';
    if (albumName.isEmpty) albumName = j['albumname']?.toString() ?? '';

    return QQSongMeta(
      songMid: j['mid']?.toString() ?? j['songmid']?.toString() ?? '',
      title: _clean(
        j['title']?.toString() ??
            j['name']?.toString() ??
            j['songname']?.toString() ??
            '',
      ),
      artists: artists,
      album: _clean(albumName),
      albumMid: albumMid,
      interval: _toInt(j['interval']),
      // 新版给 "YYYY-MM-DD"，老版给秒级 pubtime，两者都要能认
      releaseDate: _parseDateString(j['time_public']?.toString()) ??
          _parseUnixSeconds(j['pubtime']),
      subtitle: j['subtitle']?.toString() ?? '',
    );
  }

  /// 用详情接口的 track_info 覆盖搜索结果的粗略字段。
  ///
  /// 实测字段：
  ///   mid / title / singer[{name}] / album{name,mid} /
  ///   interval(秒) / time_public("YYYY-MM-DD") / subtitle
  QQSongMeta mergeDetail(Map<String, dynamic> ti) {
    final singers = <String>[];
    final rawSinger = ti['singer'];
    if (rawSinger is List) {
      for (final s in rawSinger) {
        if (s is Map) {
          final name = s['name']?.toString() ?? '';
          if (name.isNotEmpty) singers.add(name);
        }
      }
    }
    final albumObj = ti['album'];
    final albumName = albumObj is Map
        ? _clean(albumObj['name']?.toString() ?? '')
        : album;
    final albumMidNew =
        albumObj is Map ? (albumObj['mid']?.toString() ?? '') : '';

    return QQSongMeta(
      songMid: ti['mid']?.toString() ?? songMid,
      title: _clean(ti['title']?.toString() ?? ti['name']?.toString() ?? title),
      artists: singers.isNotEmpty ? singers : artists,
      album: albumName.isNotEmpty ? albumName : album,
      albumMid: albumMidNew.isNotEmpty ? albumMidNew : albumMid,
      interval: _toInt(ti['interval']) > 0 ? _toInt(ti['interval']) : interval,
      releaseDate: _parseDateString(ti['time_public']?.toString()) ??
          releaseDate,
      subtitle: ti['subtitle']?.toString() ?? subtitle,
    );
  }

  /// 专辑封面 URL。
  ///
  /// 设计文档 3.1 给出的是 `T002R300x300M000{albumMid}.jpg` 形式。
  /// host 用 `y.gtimg.cn`（QQ 音乐前端统一的图片 CDN，直连无 302；
  /// `y.qq.com/music/photo_new` 会重定向到它）。
  String? get coverUrl => coverUrlFor(albumMid);

  /// albumMid → 封面 URL 的唯一拼装点。DB 侧（SongRow.toSong）读回
  /// album_mid 后也用它拼，保证内存对象与落库读回对象的 URL 一致。
  static String? coverUrlFor(String albumMid) => albumMid.isEmpty
      ? null
      : 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg';

  /// 转为领域模型 Song。
  Song toSong({QQCredits? credits, int coverSeed = 0}) {
    return Song(
      title: title,
      // 设计文档 3.1：多歌手用 / 分隔，**保留原始顺序**（首位是主唱，影响匹配权重）
      artist: artists.join('/'),
      album: album,
      duration: interval,
      lyricist: _nullIfEmpty(credits?.lyricist),
      composer: _nullIfEmpty(credits?.composer),
      arranger: _nullIfEmpty(credits?.arranger),
      releaseDate: releaseDate,
      // 元数据入库时音源状态未知，交由匹配引擎回填
      sourceStatus: SourceStatus.none,
      coverSeed: coverSeed,
      coverUrl: coverUrl,
    );
  }

  String? _nullIfEmpty(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  /// pubtime 是**秒级**时间戳
  static DateTime? _parseUnixSeconds(dynamic v) {
    final n = _toInt(v);
    if (n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }

  /// time_public 是 "YYYY-MM-DD" 字符串
  static DateTime? _parseDateString(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    return DateTime.tryParse(s.trim());
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 创作者信息（从歌词头部解析）。
///
/// QQ音乐 JSON 里没有作词/作曲/编曲字段，实测这三项只出现在歌词文本头部：
/// ```
/// [00:06.42]词：米果
/// [00:07.92]曲：高桥优
/// [00:10.07]编曲：池洼浩一 (Kouichi Ikekubo)
/// ```
class QQCredits {
  final String? lyricist;
  final String? composer;
  final String? arranger;

  const QQCredits({this.lyricist, this.composer, this.arranger});

  static const empty = QQCredits();

  /// 从 LRC 头部解析 `词：` / `曲：` / `编曲：`（兼容 `作词：` / `作曲：`）。
  ///
  /// ## 为什么不能全文搜
  /// 正文歌词里会出现「曲」「词」等字，全文 indexOf 会命中错误位置。
  /// 实测反例：Lemon 的正文有 `[0x:xx]tokei wo...`，曾把「作曲」解析成 `)]`。
  ///
  /// ## 判定规则
  /// 扫描 lyrics 开头的一段，遇到**正文行**即停止。判定「正文行」的依据是
  /// **行首 token 不是创作者关键词** —— 而不是「有没有时间戳」。因为
  /// 创作者标注本身也带时间戳：
  /// ```
  /// [00:00.00]起风了 (原版) - 买辣椒也用券    ← 带时间戳的"标题行"，非标注非正文
  /// [00:06.42]词：米果                      ← 标注行，必须命中
  /// [00:07.92]曲：高桥优                    ← 标注行
  /// [00:28.88]这一路上走走停停               ← 正文，从这里停止
  /// ```
  /// 中间那行「起风了 (原版) - 买辣椒也用券」既不是标注也不该停止扫描，
  /// 因此停止条件只认「行首 token 不在创作者关键词集合里，且该行看起来像正文」。
  /// 这里用更稳的启发式：**只在前 30 行内找，且要求行首 token 精确等于关键词**。
  static QQCredits parseFromLrc(String lrc) {
    final lines = lrc.split('\n');
    final timeTag = RegExp(r'^\[[\d:.]+\]');

    String? pick(List<String> keys) {
      // 只看前 30 行：创作者信息必然在歌曲开头
      final limit = lines.length < 30 ? lines.length : 30;
      for (var i = 0; i < limit; i++) {
        final t = lines[i].trim();
        if (t.isEmpty) continue;
        // 去掉时间戳前缀
        final body = t.replaceFirst(timeTag, '').trim();
        if (body.isEmpty) continue;

        // 行首 token：取第一个冒号（半角或全角）之前的内容
        final sepIdx = _firstSeparatorIndex(body);
        if (sepIdx <= 0) continue;
        final head = body.substring(0, sepIdx).trim();

        if (!keys.contains(head)) continue;

        final v = body.substring(sepIdx + 1).trim();
        // 值必须像创作者名：非空、长度合理、不含成对歌词标点残留
        if (v.isNotEmpty &&
            v.length <= 60 &&
            !RegExp(r'^[\)\]\}]').hasMatch(v)) {
          return v;
        }
      }
      return null;
    }

    return QQCredits(
      lyricist: pick(['作词', '词']),
      composer: pick(['作曲', '曲']),
      arranger: pick(['编曲']),
    );
  }

  /// 返回首个冒号（半角或全角）的下标；没有则返回 -1
  static int _firstSeparatorIndex(String s) {
    final half = s.indexOf(':');
    final full = s.indexOf('：');
    if (half < 0) return full;
    if (full < 0) return half;
    return half < full ? half : full;
  }
}

/// 创作者信息（定义在 provider 里，这里 re-export 便于统一引用）
typedef QQLyricCredits = ({String? lyricist, String? composer, String? arranger});

/// 一次歌词请求拿回的全部内容。
///
/// 从 `(lrc, credits)` 二元组升级成类的原因：第三个成员 `trans` 进来后，
/// `result?.$1` / `.$2` 这种下标访问全得跟着改，而调用方有 4 处，
/// 任何一处漏改都只在特定路径上暴露。命名成员让漏改变成编译错误。
class QQLyric {
  /// 原文 LRC（已 Base64 解码）
  final String lrc;

  /// 译文 LRC（QQ 侧字段名 `trans`）。
  ///
  /// ⚠️ 实测（2026-09-29）：匿名请求下 15 首热门外语歌的 `trans` **全为空**。
  /// 字段本身存在（响应里还有 `trans_t` / `hasMultiTrans`），
  /// 但内容要登录态才给。所以这里保留解析逻辑占位，
  /// 真拿不到时由 Repository 回落到网易源——不是死代码。
  final String? trans;

  /// 从 LRC 头部解析出的创作者信息
  final QQCredits credits;

  const QQLyric({required this.lrc, this.trans, required this.credits});

  bool get hasTranslation => trans != null && trans!.trim().isNotEmpty;
}

/// 批量解析的单条输入：**标题 + 歌手 + 期望时长**三元组。
///
/// 严格模式必须知道期望时长，否则时长这一维失效、退化成二重校验。
/// 用三元组而非裸关键词，是为了强制调用方把手上已有的信息交全 ——
/// 曲库导入的原始素材（B站收藏夹 / 本地歌单）天然带时长。
class BatchQuery {
  final String title;
  final String artist;

  /// 期望时长（秒）。<=0 表示调用方确实没有时长信息（会跳过该维度）。
  final int durationSec;

  /// 调用方自带的标识（如 B站 bvid），便于把失败结果映射回原始条目。
  final String refId;

  const BatchQuery({
    required this.title,
    required this.artist,
    this.durationSec = 0,
    this.refId = '',
  });

  @override
  String toString() => '$title - $artist'
      '${durationSec > 0 ? ' (${durationSec}s)' : ''}';
}

/// 一条被淘汰的记录。批量导入最怕「30 首进去、24 首出来、不知道丢的是哪 6 首」。
class BatchRejection {
  final BatchQuery query;
  final String reason;

  const BatchRejection(this.query, this.reason);

  @override
  String toString() => '${query.refId.isNotEmpty ? '[${query.refId}] ' : ''}'
      '$query → $reason';
}

/// 一条解析成功的记录。
///
/// ## 为什么必须带上 [songMid]
/// 领域模型 [Song] **刻意不含存储字段**（见 `rows.dart` 的说明），
/// 所以 QQ音乐的真实 `songMid` 在 `toSong()` 时被丢掉。入库时若只剩
/// 标题 + 歌手，就只能派生 `local:title|artist` 兜底——而带 `local:`
/// 前缀的 mid 在 `fetchLyric` 里会被直接判为「查不到」，歌词功能
/// 静默失效（实测：真机歌词命中 0 首）。
///
/// 这里把 mid 与 Song 一起带回，让调用方能落真实 mid。
class ResolvedEntry {
  /// 输入 query（用于对齐诊断信息 / 取调用方自带的 refId）
  final BatchQuery query;

  /// 解析出的领域对象（不含存储字段）
  final Song song;

  /// QQ音乐真实 songMid（14 位十六进制）。**入库必须用它**。
  final String songMid;

  /// QQ音乐专辑 mid，用于拼封面 URL；可能为空。
  final String albumMid;

  const ResolvedEntry({
    required this.query,
    required this.song,
    required this.songMid,
    this.albumMid = '',
  });

  @override
  String toString() => 'ResolvedEntry($songMid, ${song.title})';
}

/// 批量解析结果：成功的歌 + 被淘汰的详情。
///
/// ## 为什么 pairs 而不是两个平行 List
/// `songs` 与输入的 `queries` **索引不对齐**——失败项被跳过了，
/// `songs` 是紧凑的。调用方若天真地用 `queries[i]` 去取对应输入，
/// 只要前面失败过一首，后面全部错位（这正是 `importFromKeywords`
/// 第一版踩的坑）。这里用 (query, song) 配对，从类型上杜绝错位。
///
/// 另外中间没有 `songs` 与 `queries` 的平行 list 让人误用——只管 `successes`。
class BatchResolveResult {
  /// 成功项：输入 query / Song / 真实 songMid 三者配对
  final List<ResolvedEntry> successes;

  final List<BatchRejection> rejections;

  const BatchResolveResult({
    required this.successes,
    required this.rejections,
  });

  List<Song> get songs => successes.map((e) => e.song).toList();

  int get total => successes.length + rejections.length;
  int get successCount => successes.length;
  int get rejectedCount => rejections.length;

  /// 成功率（0-1）。total 为 0 时返回 0，避免除零。
  double get successRate => total == 0 ? 0 : successCount / total;

  @override
  String toString() =>
      'BatchResolveResult($successCount/$total 成功, '
      '${(successRate * 100).toStringAsFixed(0)}%)';
}
