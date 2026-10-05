/// QQ音乐 DTO 与「DTO → domain Song」的映射。
library;

import '../../models/models.dart';
import 'qqmusic_catalog_dto.dart';

// 批量解析 DTO 与 MetadataProvider 接口**共用同一套定义**。
//
// ## 为什么是 re-export 而不是各自一份
// 之前 BatchQuery / BatchRejection / ResolvedEntry / BatchResolveResult
// 在这里和 metadata_provider.dart 各有一份**逐字段相同**的拷贝，
// 适配器里被迫手写字段映射（Dart 无 structural typing），
// 调用方还会拿到两个同名不同类型、互相赋不了值的 BatchQuery。
// 现在只保留 metadata_provider.dart 一份权威定义，
// 本文件的老 import 路径继续可用（QQMusicProvider / 测试不用改 import）。
export '../metadata/metadata_provider.dart'
    show BatchQuery, BatchRejection, BatchResolveResult, ResolvedEntry;

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

  /// 专辑 mid，用于拼封面 URL + 专辑详情跳转
  final String albumMid;

  /// 首位歌手的字符串 mid（进入歌手详情页必需）。
  ///
  /// 目录类接口（musicu.fcg）的 singer 数组每个元素带 `mid` 字段；
  /// 搜索接口可能不带，此时为空字符串。取首位主唱即可——
  /// 多歌手场景下「进谁的详情」本身就是歧义的，选第一个是最合理的默认。
  final String singerMid;

  /// 首位歌手的数字 ID（fetchSingerAlbums 必需）。
  ///
  /// singer 数组每个元素通常带 `id`（int）。部分来源（mock/搜索老接口）
  /// 可能没有这个字段，此时为 null，SingerDetailScreen 会降级。
  final int? singerId;

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
    this.singerMid = '',
    this.singerId,
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
    var firstSingerMid = '';
    int? firstSingerId;
    final rawSinger = json['singer'];
    if (rawSinger is List) {
      for (final s in rawSinger) {
        if (s is Map) {
          final name = s['name']?.toString() ?? '';
          if (name.isNotEmpty) singers.add(name);
          if (firstSingerMid.isEmpty) {
            firstSingerMid = s['mid']?.toString() ?? '';
          }
          firstSingerId ??= (s['id'] as num?)?.toInt();
        }
      }
    }

    return QQSongMeta(
      songMid: json['songmid']?.toString() ?? '',
      title: _clean(json['songname']?.toString() ?? ''),
      artists: singers,
      album: _clean(json['albumname']?.toString() ?? ''),
      albumMid: json['albummid']?.toString() ?? '',
      singerMid: firstSingerMid,
      singerId: firstSingerId,
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
    var firstSingerMid = '';
    int? firstSingerId;
    final rawSinger = j['singer'];
    if (rawSinger is List) {
      for (final s in rawSinger) {
        if (s is Map) {
          final name = s['name']?.toString() ?? '';
          if (name.isNotEmpty) artists.add(name);
          // 目录接口 singer 数组每个元素带 mid + id 字段（实测 musicu.fcg 返回）
          if (firstSingerMid.isEmpty) {
            firstSingerMid = s['mid']?.toString() ?? '';
          }
          firstSingerId ??= (s['id'] as num?)?.toInt();
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
      singerMid: firstSingerMid,
      singerId: firstSingerId,
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
    var newSingerMid = '';
    int? newSingerId;
    final rawSinger = ti['singer'];
    if (rawSinger is List) {
      for (final s in rawSinger) {
        if (s is Map) {
          final name = s['name']?.toString() ?? '';
          if (name.isNotEmpty) singers.add(name);
          if (newSingerMid.isEmpty) {
            newSingerMid = s['mid']?.toString() ?? '';
          }
          newSingerId ??= (s['id'] as num?)?.toInt();
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
      singerMid: newSingerMid.isNotEmpty ? newSingerMid : singerMid,
      singerId: newSingerId ?? singerId,
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
      albumMid: albumMid.isEmpty ? null : albumMid,
      duration: interval,
      lyricist: _nullIfEmpty(credits?.lyricist),
      composer: _nullIfEmpty(credits?.composer),
      arranger: _nullIfEmpty(credits?.arranger),
      releaseDate: releaseDate,
      // 元数据入库时音源状态未知，交由匹配引擎回填
      sourceStatus: SourceStatus.none,
      coverSeed: coverSeed,
      coverUrl: coverUrl,
      singerMid: singerMid.isEmpty ? null : singerMid,
      singerId: singerId,
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

// ═══════════════════════════════════════════════════════════════
// 综合搜索聚合结果（四分类）
// ═══════════════════════════════════════════════════════════════
//
// QQ 音乐公开搜索接口 `search_for_qq_cp` **只返回歌曲**，没有独立的
// 歌手 / 专辑 / 歌单搜索端点。但每条歌曲结果内嵌了完整的歌手信息
// （singer[].{mid, name, id}）和专辑信息（albummid, albumname）。
/// 因此歌手和专辑是**从歌曲结果中提取去重**得到的——语义上等同于
/// 「搜到的所有歌曲里出现过哪些歌手 / 专辑」。

/// 一次综合搜索的完整结果。
///
/// 四个分类各自独立：歌曲是接口直接返回的列表；歌手 / 专辑是
/// 从歌曲结果中按 mid 去重提取的；歌单暂缺（无公开搜索接口）。
class QQSearchResults {
  /// 搜到的所有歌曲（完整的 QQSongMeta，含 mid / 封面等）
  final List<QQSongMeta> songs;

  /// 从歌曲中提取的唯一歌手（按出现次数降序，首位即关键词匹配度最高）
  final List<SingerBrief> singers;

  /// 从歌曲中提取的唯一专辑（同上）
  final List<AlbumBrief> albums;

  /// 歌单搜索结果——目前无公开接口，始终为空列表。
  /// 留这个字段是为了 UI 层四 Tab 结构完整，将来有接口可直接接上。
  final List<PlaylistBrief> playlists;

  const QQSearchResults({
    this.songs = const [],
    this.singers = const [],
    this.albums = const [],
    this.playlists = const [],
  });

  bool get isEmpty =>
      songs.isEmpty && singers.isEmpty && albums.isEmpty && playlists.isEmpty;
  bool get isNotEmpty => !isEmpty;

  int get songTotal => songs.length;
  int get singerTotal => singers.length;
  int get albumTotal => albums.length;
  int get playlistTotal => playlists.length;

  /// 从歌曲列表中提取唯一歌手和专辑，构建完整的聚合结果。
  ///
  /// ## 为什么按出现次数排序
  /// 搜索"周杰伦"时，前 30 首里大部分都是周杰伦的歌，那周杰伦
  /// 应该排在歌手列表的第一位（count=30）。出现次数越少说明
  /// 匹配度越低（可能只是客串了一首歌），排在后面。
  static QQSearchResults fromSongs(List<QQSongMeta> songs) {
    // 歌手：按 mid 去重 + 统计出现次数
    final singerCount = <String, int>{};
    final singerMap = <String, SingerBrief>{};
    for (final s in songs) {
      // 每首歌的首位歌手是主唱，所有出现的歌手都要统计
      for (var i = 0; i < s.artists.length; i++) {
        final mid = s.singerMid;
        if (mid.isEmpty) continue;
        singerCount[mid] = (singerCount[mid] ?? 0) + 1;
        if (!singerMap.containsKey(mid)) {
          // 注意：singerMid 只存了首位主唱的 mid 和 id
          // 非首位歌手没有独立 mid（搜索接口只给一个 singerMid），
          // 所以 artist 数组可能有 2 个名字但只有 1 个 mid
          singerMap[mid] = SingerBrief(
            mid: mid,
            singerId: s.singerId,
            name: s.artists.isNotEmpty ? s.artists.first : '',
            pic: QQSearchResults._singerPicUrl(mid),
          );
        }
      }
    }
    final singers = singerMap.values.toList()
      ..sort((a, b) {
        final ca = singerCount[a.mid] ?? 0;
        final cb = singerCount[b.mid] ?? 0;
        return cb.compareTo(ca); // 次数多的排前面
      });

    // 专辑：按 albummid 去重
    final albumCount = <String, int>{};
    final albumMap = <String, AlbumBrief>{};
    for (final s in songs) {
      final mid = s.albumMid;
      if (mid.isEmpty) continue;
      albumCount[mid] = (albumCount[mid] ?? 0) + 1;
      if (!albumMap.containsKey(mid)) {
        albumMap[mid] = AlbumBrief(
          mid: mid,
          name: s.album,
          cover: QQSongMeta.coverUrlFor(mid) ?? '',
          singerName: s.artists.join('/'),
          releaseDate: s.releaseDate != null
              ? _formatDate(s.releaseDate!)
              : '',
        );
      }
    }
    final albums = albumMap.values.toList()
      ..sort((a, b) {
        final ca = albumCount[a.mid] ?? 0;
        final cb = albumCount[b.mid] ?? 0;
        return cb.compareTo(ca);
      });

    return QQSearchResults(
      songs: songs,
      singers: singers,
      albums: albums,
      playlists: const [],
    );
  }

  /// 歌手头像 URL（T001R300x300M000{mid}.jpg 用 https）
  static String _singerPicUrl(String mid) =>
      'https://y.gtimg.cn/music/photo_new/T001R300x300M000$mid.jpg';

  /// DateTime → "YYYY-MM-DD"
  static String _formatDate(DateTime dt) {
    final y = dt.year.toString();
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
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
