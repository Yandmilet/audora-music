/// B站三个核心接口的封装：搜索 / 详情 / 拉流。
///
/// 接口清单（均以 bilibili-API-collect 公开文档为准）：
///   搜索   GET /x/web-interface/wbi/search/type   需 Wbi 签名 + buvid3
///   详情   GET /x/web-interface/wbi/view          需 Wbi 签名
///   拉流   GET /x/player/wbi/playurl              需 Wbi 签名 + fnval=4048
library;

import 'bili_api_client.dart';
import 'bili_dto.dart';
import 'bili_exception.dart';

class BiliApi {
  BiliApi(this.client);

  final BiliApiClient client;

  static const _searchUrl = 'https://api.bilibili.com/x/web-interface/wbi/search/type';
  static const _viewUrl = 'https://api.bilibili.com/x/web-interface/wbi/view';
  static const _playUrlUrl = 'https://api.bilibili.com/x/player/wbi/playurl';

  /// 搜索视频。
  ///
  /// [durationFilter] 取值：0=全部 / 1=<10分钟 / 2=10-30分钟 / 3=30-60分钟 / 4=>60分钟。
  /// 设计文档 4.3.2 要求：分档搜索为空时必须回退到全量搜索，避免漏召。
  ///
  /// [maxRetries] 透传给客户端的重试器（默认 3 = 后台批量匹配的稳健档；
  /// 交互式搜索传 1 让失败尽快反馈给用户，见 `BiliApiClient.request`）。
  Future<List<VideoCandidate>> searchVideos(
    String keyword, {
    int durationFilter = 0,
    int pageSize = 20,
    int maxRetries = 3,
  }) async {
    if (keyword.trim().isEmpty) return [];

    final resp = await client.request(
      _searchUrl,
      params: {
        'search_type': 'video',
        'keyword': keyword,
        'page': 1,
        'page_size': pageSize,
        // 用 totalrank（综合排序）而非 click（播放量）：
        // 播放量高的往往是翻唱或鬼畜，热度与正确性不相关
        'order': 'totalrank',
        'duration': durationFilter,
        'tids': 0,
      },
      maxRetries: maxRetries,
    );

    final data = BiliApiClient.dataOf(resp);
    final list = data['result'];
    if (list is! List) return [];

    final candidates = <VideoCandidate>[];
    for (final item in list) {
      if (item is! Map) continue;
      final bvid = item['bvid']?.toString() ?? '';
      if (bvid.isEmpty) continue;

      candidates.add(VideoCandidate(
        bvid: bvid,
        title: cleanTitle(item['title']?.toString() ?? ''),
        author: stripHtml(item['author']?.toString() ?? ''),
        mid: _toInt(item['mid']),
        durationSec: parseDuration(item['duration']?.toString() ?? ''),
        play: _toInt(item['play']),
        pubdate: _toInt(item['pubdate']),
        // 搜索结果不含分区名，Stage 3 才补
        typename: item['typename']?.toString() ?? '',
        desc: item['description']?.toString() ?? '',
      ));
    }
    return candidates;
  }

  /// 搜索并自动回退：分档搜不到时改全量搜（设计文档 4.3.2）
  Future<List<VideoCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int maxRetries = 3,
  }) async {
    var items = await searchVideos(keyword,
        durationFilter: durationFilter, maxRetries: maxRetries);
    if (items.isEmpty && durationFilter != 0) {
      items = await searchVideos(keyword,
          durationFilter: 0, maxRetries: maxRetries);
    }
    return items;
  }

  /// 视频详情（Stage 3 精确校验）
  Future<VideoDetail?> fetchVideoDetail(String bvid) async {
    try {
      final resp = await client.request(_viewUrl, params: {'bvid': bvid});
      final data = BiliApiClient.dataOf(resp);
      if (data.isEmpty) return null;

      final owner = data['owner'] as Map<String, dynamic>?;
      final pages = <VideoPage>[];
      final rawPages = data['pages'];
      if (rawPages is List) {
        for (final p in rawPages) {
          if (p is! Map) continue;
          pages.add(VideoPage(
            cid: _toInt(p['cid']),
            page: _toInt(p['page']),
            part: p['part']?.toString() ?? '',
            durationSec: _toInt(p['duration']),
          ));
        }
      }

      return VideoDetail(
        bvid: data['bvid']?.toString() ?? bvid,
        cid: _toInt(data['cid']),
        title: cleanTitle(data['title']?.toString() ?? ''),
        ownerName: owner?['name']?.toString() ?? '',
        ownerMid: _toInt(owner?['mid']),
        tname: data['tname']?.toString() ?? '',
        durationSec: _toInt(data['duration']),
        playCount: _toInt((data['stat'] as Map?)?['view']),
        pubdate: _toInt(data['pubdate']),
        desc: data['desc']?.toString() ?? '',
        pic: data['pic']?.toString() ?? '',
        pages: pages,
        tag: _extractTag(data),
      );
    } on BiliApiException catch (e) {
      // 视频不存在 / 权限不足：属正常淘汰，不作为异常上抛
      if (e.isNotFound || e.isForbidden) return null;
      rethrow;
    }
  }

  /// 解析音频流（设计文档 7.1）
  ///
  /// fnval=4048 请求所有 DASH 流；返回里取 data.dash.audio[]
  ///
  /// [qualityCeiling] 是用户的音质**上限偏好**（0 = 不限制）。
  /// 它只在选流时起作用，不改变请求参数——请求始终要全集，
  /// 这样偏好放宽时不需要重新请求。
  Future<AudioStream?> fetchAudioStream(
    String bvid,
    int cid, {
    int qualityCeiling = 0,
  }) async {
    try {
      final resp = await client.request(
        _playUrlUrl,
        params: {
          'bvid': bvid,
          'cid': cid,
          // 4048 = 16+32+128+256+1024+2048+... 请求所有 DASH 流
          'fnval': 4048,
          'fnver': 0,
          'fourk': 1,
        },
      );
      final data = BiliApiClient.dataOf(resp);
      final dash = data['dash'] as Map<String, dynamic>?;
      final audioList = dash?['audio'];
      if (audioList is! List) return null;

      final streams = <AudioStream>[];
      for (final a in audioList) {
        if (a is! Map) continue;
        final baseUrl = (a['baseUrl'] ?? a['base_url'])?.toString() ?? '';
        if (baseUrl.isEmpty) continue;
        streams.add(AudioStream(
          id: _toInt(a['id']),
          baseUrl: baseUrl,
          bandwidth: _toInt(a['bandwidth']),
          mimeType: a['mimeType']?.toString() ?? 'audio/mp4',
          codecs: a['codecs']?.toString() ?? '',
        ));
      }
      return pickBestAudio(streams, ceiling: qualityCeiling);
    } on BiliApiException catch (e) {
      if (e.isNotFound || e.isForbidden) return null;
      rethrow;
    }
  }

  // ── 文本处理 ─────────────────────────────────────────────

  /// 清洗搜索结果标题里的高亮标签（设计文档 4.3.3）
  ///
  /// 例：`白浩寅 - <em class="keyword">秘密</em>【官方MV】`
  ///   → `白浩寅 - 秘密【官方MV】`
  static String cleanTitle(String raw) {
    return stripHtml(raw)
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 去 HTML 标签
  static String stripHtml(String raw) =>
      raw.replaceAll(RegExp(r'</?em[^>]*>'), '').replaceAll(RegExp(r'<[^>]+>'), '');

  /// 解析时长字符串为秒（设计文档 4.3.3）
  ///
  /// 支持 `"03:46"` 与 `"1:02:33"` 两种格式。
  static int parseDuration(String str) {
    final trimmed = str.trim();
    if (trimmed.isEmpty) return 0;
    final parts = trimmed.split(':');
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null) return 0;
      nums.add(n);
    }
    return switch (nums.length) {
      2 => nums[0] * 60 + nums[1],
      3 => nums[0] * 3600 + nums[1] * 60 + nums[2],
      _ => 0,
    };
  }

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  /// 详情接口可能以字符串或数组形式返回 tag，统一成逗号分隔串
  static String _extractTag(Map<String, dynamic> data) {
    final raw = data['tag'];
    if (raw == null) {
      final t2 = data['tname'];
      return t2?.toString() ?? '';
    }
    if (raw is String) return raw;
    if (raw is List) {
      return raw
          .map((e) => e is Map ? (e['tag_name']?.toString() ?? '') : e.toString())
          .where((s) => s.isNotEmpty)
          .join(',');
    }
    return '';
  }
}
