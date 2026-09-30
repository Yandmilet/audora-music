/// QQ音乐元数据 Provider（设计文档 2.1 的 `MetadataProvider` 实现）。
///
/// 数据来源（均为公开 Web 接口，实测可用）：
///   1. 搜索  GET  https://shc.y.qq.com/soso/fcgi-bin/search_for_qq_cp
///        → songname / singer[] / albumname / albummid / interval / pubtime
///   2. 详情  GET  https://u.y.qq.com/cgi-bin/musicu.fcg
///        module=music.pf_song_detail_svr&method=get_song_detail_yqq
///        → 精确 interval / time_public / 专辑 / 副标题
///   3. 歌词  GET  同上 fcg，module=music.musichallSong.PlayLyricInfo
///        → Base64 的 LRC 文本；**作词/作曲/编曲从 LRC 头部的
///          `词：xxx` / `曲：xxx` / `编曲：xxx` 行解析**（JSON 里没有这三个字段）
///
/// 注意：`interval` / `pubtime` 的单位处理——搜索接口 pubtime 是**秒级时间戳**，
/// 详情接口 time_public 是 **"YYYY-MM-DD" 字符串**，两者都要归一成 DateTime。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/models.dart';
import 'qqmusic_catalog_dto.dart';
import 'qqmusic_dto.dart';

class QQMusicApiException implements Exception {
  final int code;
  final String message;
  final String endpoint;

  const QQMusicApiException(this.code, this.message, {required this.endpoint});

  @override
  String toString() => 'QQMusicApiException($code) @$endpoint: $message';
}

class QQMusicProvider {
  QQMusicProvider({Dio? dio}) : dio = dio ?? _buildDio();

  final Dio dio;

  static Dio _buildDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ));

  static const _searchUrl =
      'https://shc.y.qq.com/soso/fcgi-bin/search_for_qq_cp';
  static const _fcgUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

  /// 歌手列表（老接口，但目录里**唯一**能用的歌手入口）
  static const _singerListUrl = 'https://c.y.qq.com/v8/fcg-bin/v8.fcg';

  /// 歌单分类列表
  static const _playlistTagUrl =
      'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg';

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Referer': 'https://y.qq.com/',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 搜索歌曲。返回按官方相关性排序的候选列表。
  Future<List<QQSongMeta>> search(String keyword, {int pageSize = 20}) async {
    if (keyword.trim().isEmpty) return [];
    try {
      final resp = await dio.get<dynamic>(
        _searchUrl,
        queryParameters: {
          'w': keyword,
          'p': 1,
          'n': pageSize,
          'format': 'json',
        },
        options: Options(headers: _headers),
      );
      final map = _decode(resp.data, _searchUrl);
      final data = map['data'] as Map<String, dynamic>?;
      final song = data?['song'] as Map<String, dynamic>?;
      final list = song?['list'];
      if (list is! List) return [];

      final result = <QQSongMeta>[];
      for (final item in list) {
        if (item is! Map) continue;
        final meta = QQSongMeta.fromSearchJson(item.cast<String, dynamic>());
        if (meta.songMid.isEmpty) continue;
        result.add(meta);
      }
      return result;
    } on DioException catch (e) {
      throw QQMusicApiException(-1, e.message ?? e.type.name,
          endpoint: _searchUrl);
    }
  }

  /// 拉歌曲详情（精确时长 / 发行日期 / 专辑）。
  Future<QQSongMeta?> fetchDetail(QQSongMeta base) async {
    try {
      final body = jsonEncode({
        'comm': {'ct': 24, 'cv': 0},
        'req_1': {
          'module': 'music.pf_song_detail_svr',
          'method': 'get_song_detail_yqq',
          'param': {'song_type': 0, 'song_mid': base.songMid},
        },
      });
      final resp = await dio.get<dynamic>(
        _fcgUrl,
        queryParameters: {'data': body},
        options: Options(headers: _headers),
      );
      final map = _decode(resp.data, _fcgUrl);
      final ti = ((map['req_1'] as Map?)?['data'] as Map?)?['track_info'];
      if (ti is! Map) return null;
      return base.mergeDetail(ti.cast<String, dynamic>());
    } on DioException catch (e) {
      throw QQMusicApiException(-1, e.message ?? e.type.name, endpoint: _fcgUrl);
    }
  }

  /// 拉歌词原文（LRC）+ 译文轨，并顺带解析出作词 / 作曲 / 编曲。
  ///
  /// 拿不到歌词时返回 null。译文（`trans`）拿不到是常态，见 [QQLyric.trans]。
  Future<QQLyric?> fetchLyric(String songMid) async {
    try {
      final body = jsonEncode({
        'comm': {'ct': 24, 'cv': 0},
        'req_2': {
          'module': 'music.musichallSong.PlayLyricInfo',
          'method': 'GetPlayLyricInfo',
          'param': {'songMID': songMid},
        },
      });
      final resp = await dio.get<dynamic>(
        _fcgUrl,
        queryParameters: {'data': body},
        options: Options(headers: _headers),
      );
      final map = _decode(resp.data, _fcgUrl);
      final data = (map['req_2'] as Map?)?['data'];
      if (data is! Map) return null;

      final raw = data['lyric']?.toString() ?? '';
      if (raw.isEmpty) return null;

      // lyric 字段是 Base64 编码的 LRC 文本
      String lrc;
      try {
        lrc = utf8.decode(base64.decode(raw));
      } catch (_) {
        // 个别情况返回的是明文
        lrc = raw;
      }

      // 译文轨同为基础 Base64 的 LRC，但**没内容时是空串**，
      // 空串要当成"没有译文"而不是"译文是空歌词"。
      String? trans;
      final rawTrans = data['trans']?.toString() ?? '';
      if (rawTrans.isNotEmpty) {
        try {
          trans = utf8.decode(base64.decode(rawTrans));
        } catch (_) {
          trans = rawTrans;
        }
      }

      return QQLyric(lrc: lrc, trans: trans, credits: QQCredits.parseFromLrc(lrc));
    } catch (_) {
      // 歌词属展示增强，失败不影响主流程
      return null;
    }
  }

  /// 一步到位：搜索 → 取详情 → （可选）取创作者，返回可直接入库的 Song。
  ///
  /// [withLyricCredits] = true 时多一次请求换取作词/作曲/编曲。
  ///
  /// 注意：**不做相关性校验**，直接采信搜索引擎的第一条。如果关键词构造不当
  /// （例如「米津玄師 Lemon」却把歌名写错），拿到的会是完全无关的歌。
  /// 需要严格场景请用 [resolveFirstMatching]。
  Future<Song?> resolveSong(
    String keyword, {
    bool withLyricCredits = false,
  }) async {
    final list = await search(keyword, pageSize: 1);
    if (list.isEmpty) return null;
    var meta = list.first;
    final detail = await fetchDetail(meta);
    if (detail != null) meta = detail;

    QQCredits? credits;
    if (withLyricCredits) {
      final lyr = await fetchLyric(meta.songMid);
      credits = lyr?.credits;
    }
    return meta.toSong(credits: credits);
  }

  /// 严格模式解析：**标题 + 歌手 + 时长三重校验**全部通过才返回。
  ///
  /// ## 为什么必须有时长这一道
  /// 标题和歌手都能被同名不同曲骗过。实测教训：误填关键词时接口
  /// `code:0`、字段齐全、**安静地返回了完全无关的《晴天》**——
  /// 只看标题会以为成功，但「互相包含」在小样本下也可能成立。
  /// 时长是唯一的物理硬证据，且 QQ音乐与 B站两边的时长天然有 1-3 秒误差，
  /// 因此阈值放到 [durationToleranceSec]，既能容忍转码误差，
  /// 又足以区分原版(256s)与 Live 版(275s)这类真实差异。
  ///
  /// 校验在**详情接口返回的精确字段**上做，不用搜索接口的粗略值
  /// （搜索结果的标题被截断、歌手顺序可能不同）。
  ///
  /// 任何一项不过就继续试下一个候选；全部不过返回 null，**绝不退而求其次**。
  Future<Song?> resolveFirstMatching(
    String title,
    String artist, {
    /// 期望时长（秒）。>0 时强制参与校验；<=0 表示调用方无时长信息，跳过该维度。
    int expectDurationSec = 0,

    /// 时长容差（秒）
    int durationToleranceSec = 5,

    bool withLyricCredits = false,

    /// 诊断回调：每淘汰一个候选的原因，便于排查「为什么没匹配上」
    void Function(String bvid, String reason)? onReject,
  }) async {
    final meta = await _resolveFirstMatchingMeta(
      title,
      artist,
      expectDurationSec: expectDurationSec,
      durationToleranceSec: durationToleranceSec,
      withLyricCredits: withLyricCredits,
      onReject: onReject,
    );
    return meta?.$1;
  }

  /// [resolveFirstMatching] 的内核：返回 `(Song, 真实 songMid, albumMid)`。
  ///
  /// ## 为什么单独抽出这一层
  /// 批量导入必须把 **真实 songMid** 落库（否则歌词取不到，见
  /// `BatchResolveResult` 的注释）。但领域模型 `Song` 不带存储字段，
  /// 单靠它的返回值无法把 mid 传出去。这里让内核把 meta 信息一并带出，
  /// 对外的 [resolveFirstMatching] 仍然只暴露 `Song`，不影响既有调用方。
  Future<(Song, String, String)?> _resolveFirstMatchingMeta(
    String title,
    String artist, {
    int expectDurationSec = 0,
    int durationToleranceSec = 5,
    bool withLyricCredits = false,
    void Function(String bvid, String reason)? onReject,
  }) async {
    final list = await search('$title $artist', pageSize: 10);
    if (list.isEmpty) {
      onReject?.call('', '搜索无结果');
      return null;
    }

    final nTitle = _norm(title);
    final nArtist = _norm(artist);

    for (final candidate in list) {
      var meta = candidate;
      final detail = await fetchDetail(candidate);
      if (detail != null) meta = detail;

      final mTitle = _norm(meta.title);

      // ── 校验 1：标题互相包含（容忍「(旧版)」这类后缀）──
      final titleOk = mTitle.contains(nTitle) || nTitle.contains(mTitle);
      if (!titleOk) {
        onReject?.call(meta.songMid, '标题不符：「${meta.title}」');
        continue;
      }

      // ── 校验 2：歌手必须命中一个（同样做互含，容忍写法差异）──
      final artistOk = meta.artists
          .any((a) => _norm(a).contains(nArtist) || nArtist.contains(_norm(a)));
      if (!artistOk) {
        onReject?.call(meta.songMid,
            '歌手不符：「${meta.artists.join("/")}」不含「$artist」');
        continue;
      }

      // ── 校验 3：时长吻合 ──
      if (expectDurationSec > 0) {
        final delta = (meta.interval - expectDurationSec).abs();
        if (delta > durationToleranceSec) {
          onReject?.call(
            meta.songMid,
            '时长不符：${meta.interval}s vs 期望 ${expectDurationSec}s'
            '（差 ${delta}s > ${durationToleranceSec}s）',
          );
          continue;
        }
      }

      QQCredits? credits;
      if (withLyricCredits) {
        credits = (await fetchLyric(meta.songMid))?.credits;
      }
      return (meta.toSong(credits: credits), meta.songMid, meta.albumMid);
    }
    return null;
  }

  /// 归一化：去空格与标点，转小写，便于比对
  ///
  /// 用字符类排除标点；双引号用 \x22 转义，避免与外层 Dart 字符串冲突。
  static final _normPunct = RegExp(
    '[\\s\\-_·・,，.。!！?？:：;；\x22\x27“”‘’()（）\\[\\]【】]',
  );

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(_normPunct, '').trim();

  /// 批量解析（曲库导入用）。串行 + 间隔，避免触发风控。
  ///
  /// ## 默认即严格
  /// 每一项都走 [resolveFirstMatching] 的**三重校验**（标题 + 歌手 + 时长），
  /// 不用 [resolveSong] 的「采信第一条」——后者在批量导入场景下出错是静默的，
  /// 用户拿到入库结果时已无法分辨哪首是错的。
  ///
  /// ## 为什么输入是三元组而不是关键词
  /// 严格模式必须知道「期望时长」，否则时长这一维失效、退化成二重校验。
  /// 曲库导入的原始素材（B站收藏夹 / 本地歌单）天然带有时长，随手丢弃
  /// 再让 provider 去猜是浪费。用 [BatchQuery] 强制调用方把已知信息交全。
  ///
  /// 诊断
  /// 返回 [BatchResolveResult]，失败的项连原因一起带回。批量导入最怕
  /// 「30 首进去、24 首出来、不知道丢的是哪 6 首」，所以这里不留死角。
  ///
  /// 成功项以 `(query, song)` 配对返回，**不要**试图用索引去对应输入的
  /// `queries`——失败项被跳过后索引会错位。
  Future<BatchResolveResult> resolveBatch(
    List<BatchQuery> queries, {
    int durationToleranceSec = 5,
    bool withLyricCredits = false,
    void Function(int done, int total)? onProgress,
    void Function(BatchQuery query, String reason)? onReject,
  }) async {
    final successes = <ResolvedEntry>[];
    final rejections = <BatchRejection>[];

    for (var i = 0; i < queries.length; i++) {
      final q = queries[i];
      try {
        final resolved = await _resolveFirstMatchingMeta(
          q.title,
          q.artist,
          expectDurationSec: q.durationSec,
          durationToleranceSec: durationToleranceSec,
          withLyricCredits: withLyricCredits,
        );
        if (resolved != null) {
          // ★ songMid 必须随 Song 一起带回：入库要靠它，否则歌词取不到
          successes.add(ResolvedEntry(
            query: q,
            song: resolved.$1,
            songMid: resolved.$2,
            albumMid: resolved.$3,
          ));
        } else {
          const reason = '三重校验全部候选均不通过';
          rejections.add(BatchRejection(q, reason));
          onReject?.call(q, reason);
        }
      } catch (e) {
        // 单首失败跳过，不打断整批；但原因要留痕
        final reason = '请求异常：$e';
        rejections.add(BatchRejection(q, reason));
        onReject?.call(q, reason);
      }
      onProgress?.call(i + 1, queries.length);
      if (i < queries.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return BatchResolveResult(successes: successes, rejections: rejections);
  }

  // ── 目录浏览（歌手库 / 歌单推荐 / 榜单 / 新歌） ──────────────
  //
  // 与搜索/详情的区别：这是**只读浏览**，用户不点歌就不入库。
  // 所以响应带一层 TTL 缓存——榜单/歌单一天就更新一两次，
  // 每次进页面都重拉纯属浪费（也让翻回上一页变快）。

  /// 缓存 TTL。5 分钟内重复请求直接命中，榜单卡片页频繁来回切时几乎零开销。
  static const _cacheTtl = Duration(minutes: 5);
  final Map<String, (DateTime, dynamic)> _cache = {};

  Future<T> _cached<T>(String key, Future<T> Function() fetch) async {
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _cacheTtl) {
      return hit.$2 as T;
    }
    final v = await fetch();
    _cache[key] = (DateTime.now(), v);
    // 只加不删会缓慢膨胀，但 key 空间有限（榜单十几个 / 歌手页几页），
    // 超过 64 条时整体清一次足够了——不值得为它上 LRU。
    if (_cache.length > 64) _cache.removeWhere((k, v) => k != key);
    return v;
  }

  /// POST musicu.fcg 的目录类调用。模块/方法固定成对出现，封装一次。
  Future<Map<String, dynamic>> _catalogPost(
    String module,
    String method,
    Map<String, dynamic> param,
  ) async {
    try {
      final body = jsonEncode({
        'comm': {'ct': 24, 'cv': 0},
        'req_1': {'module': module, 'method': method, 'param': param},
      });
      final resp = await dio.get<dynamic>(
        _fcgUrl,
        queryParameters: {'data': body},
        options: Options(headers: _headers),
      );
      final map = _decode(resp.data, _fcgUrl);
      final req1 = map['req_1'] as Map?;
      final code = (req1?['code'] as num?)?.toInt() ?? 0;
      if (code != 0) {
        throw QQMusicApiException(code, 'module 调用失败', endpoint: module);
      }
      return ((req1?['data'] as Map?) ?? const {}).cast<String, dynamic>();
    } on DioException catch (e) {
      throw QQMusicApiException(-1, e.message ?? e.type.name, endpoint: module);
    }
  }

  /// 榜单分组列表（巅峰榜 / 地区榜 / 特色榜…）。
  ///
  /// 预览歌只有 `songId` 没有 mid（见 [ToplistPreviewRow]），
  /// 想播放必须进详情页——这是接口的形状决定的，不是我们偷懒。
  Future<List<ToplistGroup>> fetchToplistGroups() => _cached(
        'toplistGroups',
        () async {
          final data = await _catalogPost('musicToplist.ToplistInfoServer',
              'GetAll', const {});
          final groups = <ToplistGroup>[];
          final raw = data['group'];
          if (raw is! List) return groups;
          for (final g in raw) {
            if (g is! Map) continue;
            final name = g['groupName']?.toString() ?? '';
            final lists = <ToplistBrief>[];
            final rawLists = g['toplist'];
            if (rawLists is List) {
              for (final t in rawLists) {
                if (t is! Map) continue;
                final previews = <ToplistPreviewRow>[];
                final rawSongs = t['song'];
                if (rawSongs is List) {
                  for (final s in rawSongs) {
                    if (s is! Map) continue;
                    previews.add(ToplistPreviewRow(
                      rank: (s['rank'] as num?)?.toInt() ?? 0,
                      title: s['title']?.toString() ?? '',
                      singer: s['singerName']?.toString() ?? '',
                    ));
                  }
                }
                lists.add(ToplistBrief(
                  topId: (t['topId'] as num?)?.toInt() ?? 0,
                  title: t['title']?.toString() ?? '',
                  subtitle: t['titleDetail']?.toString() ?? '',
                  updateTime: t['updateTime']?.toString() ?? '',
                  listenNum: (t['listenNum'] as num?)?.toInt() ?? 0,
                  totalNum: (t['totalNum'] as num?)?.toInt() ?? 0,
                  preview: previews,
                ));
              }
            }
            if (name.isNotEmpty && lists.isNotEmpty) {
              groups.add(ToplistGroup(name: name, toplists: lists));
            }
          }
          return groups;
        },
      );

  /// 榜单详情。歌都带真实 mid，可直接入库播放。
  ///
  /// [period] 传空表示最新一期；实测传旧期号可以拿历史榜单，暂不用。
  /// 参数名用 [limit] 而不是 `num`——后者会遮蔽 Dart 的 `num` 类型，
  /// 导致函数体里的 `as num?` 强转编译失败。
  Future<ToplistDetail> fetchToplistDetail(int topId, {int limit = 100}) =>
      _cached('toplistDetail:$topId:$limit', () async {
        final data = await _catalogPost(
          'musicToplist.ToplistInfoServer',
          'GetDetail',
          {'topId': topId, 'offset': 0, 'num': limit, 'period': ''},
        );
        final meta = (data['data'] as Map?) ?? const {};
        final songs = <QQSongMeta>[];
        final raw = data['songInfoList'];
        if (raw is List) {
          for (final s in raw) {
            if (s is! Map) continue;
            final m = QQSongMeta.fromCatalogJson(s.cast<String, dynamic>());
            if (m.songMid.isNotEmpty) songs.add(m);
          }
        }
        return ToplistDetail(
          topId: topId,
          title: meta['title']?.toString() ?? '',
          updateTime: meta['updateTime']?.toString() ?? '',
          listenNum: (meta['listenNum'] as num?)?.toInt() ?? 0,
          songs: songs,
        );
      });

  /// 歌手列表（按热度分页，每页最多 80）。
  ///
  /// ## 为什么没有地区筛选
  /// 接口的 `area`/`key` 参数实测被服务端忽略（见 [kSingerAreaLabels]）。
  /// 返回的歌手自带地区编码，UI 把它当标签显示。
  Future<SingerPage> fetchSingers({int page = 1, int pageSize = 80}) =>
      _cached('singers:$page:$pageSize', () async {
        final resp = await dio.get<dynamic>(
          _singerListUrl,
          queryParameters: {
            'channel': 'singer',
            'page': 'list',
            'key': 'all_all_all',
            'pagesize': pageSize,
            'pagenum': page,
            'format': 'json',
          },
          options: Options(headers: _headers),
        );
        final map = _decode(resp.data, _singerListUrl);
        final data = map['data'] as Map<String, dynamic>? ?? const {};
        final total = (data['total'] as num?)?.toInt() ?? 0;
        final singers = <SingerBrief>[];
        final raw = data['list'];
        if (raw is List) {
          for (final s in raw) {
            if (s is! Map) continue;
            final mid = s['Fsinger_mid']?.toString() ?? '';
            final name = s['Fsinger_name']?.toString() ?? '';
            if (mid.isEmpty || name.isEmpty) continue;
            singers.add(SingerBrief(
              mid: mid,
              name: name,
              otherName: s['Fother_name']?.toString() ?? '',
              letter: s['Findex']?.toString() ?? '',
              // 字段值实测是字符串 "1"，不是数字
              area: int.tryParse(s['Farea']?.toString() ?? '') ?? 0,
            ));
          }
        }
        return SingerPage(
          singers: singers,
          total: total,
          page: page,
          totalPage: total <= 0 ? 1 : (total / pageSize).ceil(),
        );
      });

  /// 歌手的歌曲列表（按热度降序）。
  ///
  /// ⚠️ 参数名实测是**小写** `singermid`——用驼峰 `singerMid` 会被
  /// 服务端以 code=400 拒掉，且错误信息完全不带原因。
  Future<List<QQSongMeta>> fetchSingerSongs(String singerMid,
          {int limit = 100}) =>
      _cached('singerSongs:$singerMid:$limit', () async {
        final data = await _catalogPost(
          'music.web_singer_info_svr',
          'get_singer_detail_info',
          {
            'singermid': singerMid,
            'order': 1,
            'begin': 0,
            'num': limit,
            'songType': 0,
          },
        );
        final songs = <QQSongMeta>[];
        final raw = data['songlist'];
        if (raw is List) {
          for (final s in raw) {
            if (s is! Map) continue;
            final m = QQSongMeta.fromCatalogJson(s.cast<String, dynamic>());
            if (m.songMid.isNotEmpty) songs.add(m);
          }
        }
        return songs;
      });

  /// 歌单推荐列表。
  ///
  /// ⚠️ 必须带 `inCharset=utf8&outCharset=utf-8`，否则服务端按 gb2312 编码
  /// 返回——dio 不认这个字符集，会直接解码失败。
  Future<List<PlaylistBrief>> fetchPlaylists(
          {int sortId = 5, int page = 0, int pageSize = 30}) =>
      _cached('playlists:$sortId:$page:$pageSize', () async {
        final resp = await dio.get<dynamic>(
          _playlistTagUrl,
          queryParameters: {
            'g_tk': 5381,
            'loginUin': 0,
            'hostUin': 0,
            'format': 'json',
            'inCharset': 'utf8',
            'outCharset': 'utf-8',
            'notice': 0,
            'platform': 'yqq.json',
            'needNewCode': 0,
            'categoryId': 10000000,
            'sortId': sortId,
            'sin': page * pageSize,
            'ein': page * pageSize + pageSize - 1,
          },
          options: Options(headers: _headers),
        );
        final map = _decode(resp.data, _playlistTagUrl);
        final data = map['data'] as Map<String, dynamic>? ?? const {};
        final result = <PlaylistBrief>[];
        final raw = data['list'];
        if (raw is List) {
          for (final s in raw) {
            if (s is! Map) continue;
            final id = s['dissid']?.toString() ?? '';
            if (id.isEmpty) continue;
            final creator = s['creator'];
            result.add(PlaylistBrief(
              dissId: id,
              title: s['dissname']?.toString() ?? '',
              cover: s['imgurl']?.toString() ?? '',
              listenNum: (s['listennum'] as num?)?.toInt() ?? 0,
              creator: creator is Map ? creator['name']?.toString() ?? '' : '',
              introduction: s['introduction']?.toString() ?? '',
            ));
          }
        }
        return result;
      });

  /// 歌单详情。`total` 是声明总数，与 `songs.length` 可能不等
  /// （版权下架的被过滤掉），UI 上不要拿 songs.length 冒充总数。
  Future<PlaylistDetail> fetchPlaylistDetail(String dissId) =>
      _cached('playlistDetail:$dissId', () async {
        final data = await _catalogPost(
          'music.srfDissInfo.aiDissInfo',
          'uniform_get_Dissinfo',
          {'disstid': int.tryParse(dissId) ?? 0, 'loginUin': 0},
        );
        final dir = (data['dirinfo'] as Map?) ?? const {};
        final songs = <QQSongMeta>[];
        final raw = data['songlist'];
        if (raw is List) {
          for (final s in raw) {
            if (s is! Map) continue;
            final m = QQSongMeta.fromCatalogJson(s.cast<String, dynamic>());
            if (m.songMid.isNotEmpty) songs.add(m);
          }
        }
        return PlaylistDetail(
          dissId: dissId,
          title: dir['title']?.toString() ?? '',
          cover: dir['picurl']?.toString() ?? '',
          listenNum: (dir['listennum'] as num?)?.toInt() ?? 0,
          description: data['desc']?.toString() ?? '',
          total: (data['total_song_num'] as num?)?.toInt() ?? songs.length,
          songs: songs,
        );
      });

  static Map<String, dynamic> _decode(dynamic raw, String endpoint) {
    if (raw == null) {
      throw QQMusicApiException(-1, '响应体为空', endpoint: endpoint);
    }
    final map = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : raw as Map<String, dynamic>;
    final code = (map['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw QQMusicApiException(code, map['message']?.toString() ?? '未知错误',
          endpoint: endpoint);
    }
    return map;
  }
}
