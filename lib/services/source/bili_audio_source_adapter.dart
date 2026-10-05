/// 适配器：让 [BiliApi] 实现 [AudioSourceProvider] 接口。
///
/// ## 设计原则
/// 本适配器是**薄转调层** —— 不做任何业务逻辑改动，只负责：
/// 1. 把通用 DTO（SourceCandidate / SourceDetail / AudioSourceInfo）与
///    B站专属 DTO（VideoCandidate / VideoDetail / AudioStream）互相转换。
/// 2. 把 AudioSourceProvider 接口签名转调给 BiliApi 的同名方法。
/// 3. 提供 [requiredHeaders] —— 这是 B站特有的（CDN 校验 Referer / Origin），
///    定义在此处让换源时自动更新，SourceResolver 不再硬编码 bilibili.com。
///
/// ## 行为零改动承诺
/// BiliApi 是纯网络层，本适配器不碰它的内部逻辑 —— Wbi 签名、限频、
/// 重试都由 BiliApiClient + BiliApi 自己负责。
/// 所有现有单测（match_engine_test / source_resolver_test 等）保持不变。
library;

import 'audio_source_provider.dart';
import '../bilibili/bili_api.dart';
import '../bilibili/bili_dto.dart' as bili;

/// B站音源适配器。
///
/// 构造时接收一个已初始化的 [BiliApi] 实例（内部已带 BiliApiClient，
/// 共享限流器），Adapter 不自己初始化 —— 装配层决定实例化时机。
///
/// ## requiredHeaders 为什么在这里
/// 之前 B站的拉流请求头（Referer: bilibili.com 等）写死在
/// [SourceResolver.audioHeaders] 里。现在它属于「这个源拉流时需要什么」
/// —— 自然归 Adapter 所有。换源时新 Adapter 会返回自己的头（可能是空 Map），
/// SourceResolver 只需透传即可。
class BiliAudioSourceAdapter implements AudioSourceProvider {
  const BiliAudioSourceAdapter(this._api);

  final BiliApi _api;

  @override
  String get sourceType => 'bilibili';

  /// B站 CDN 拉流必须带的请求头。
  ///
  /// `*.bilivideo.com` 的音频 CDN 会校验 Referer 和 Origin，
  /// 不带直接 403。这是 B站独有的，其他音频源不一定有这个要求 ——
  /// 换源后对应 Adapter 会返回空 Map 或自己的头。
  ///
  /// 本字段是 B站拉流头的**唯一来源**。之前写死在
  /// SourceResolver.audioHeaders 里，现在归入 AudioSourceProvider 接口层。
  @override
  Map<String, String> get requiredHeaders => const {
        'Referer': 'https://www.bilibili.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Origin': 'https://www.bilibili.com',
      };

  // ═══════════════════════════════════════════════════════════════
  // 转调实现
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<List<SourceCandidate>> searchCandidates(
    String keyword, {
    int durationFilter = 0,
    int pageSize = 20,
    int maxRetries = 3,
  }) async {
    final list = await _api.searchVideos(
      keyword,
      durationFilter: durationFilter,
      pageSize: pageSize,
      maxRetries: maxRetries,
    );
    return list.map(_videoCandidateToSource).toList();
  }

  @override
  Future<List<SourceCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int pageSize = 20,
    int maxRetries = 3,
  }) async {
    // BiliApi 自己就有 searchWithFallback —— 复用它的逻辑，
    // 不走接口默认实现（先分档搜、空了改全量搜）。
    final list = await _api.searchWithFallback(
      keyword,
      durationFilter: durationFilter,
      maxRetries: maxRetries,
    );
    return list.map(_videoCandidateToSource).toList();
  }

  @override
  Future<SourceDetail?> fetchSourceDetail(String sourceKey) async {
    final detail = await _api.fetchVideoDetail(sourceKey);
    if (detail == null) return null;
    return _videoDetailToSource(detail);
  }

  @override
  Future<AudioSourceInfo?> fetchAudioStream(
    String sourceKey,
    String sourceSubKey, {
    int qualityCeiling = 0,
  }) async {
    // sourceSubKey 是 String，BiliApi 要 int cid
    final cid = int.tryParse(sourceSubKey) ?? 0;
    final stream = await _api.fetchAudioStream(
      sourceKey,
      cid,
      qualityCeiling: qualityCeiling,
    );
    if (stream == null) return null;
    return AudioSourceInfo(
      url: stream.baseUrl,
      qualityId: stream.id,
      bandwidth: stream.bandwidth,
      mimeType: stream.mimeType,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // DTO 互转
  // ═══════════════════════════════════════════════════════════════

  /// VideoCandidate → SourceCandidate
  SourceCandidate _videoCandidateToSource(bili.VideoCandidate v) => SourceCandidate(
        sourceType: 'bilibili',
        sourceKey: v.bvid,
        sourceSubKey: v.cid > 0 ? v.cid.toString() : '',
        title: v.title,
        author: v.author,
        durationSec: v.durationSec,
        playCount: v.play,
        category: v.typename,
      );

  /// VideoDetail → SourceDetail
  SourceDetail _videoDetailToSource(bili.VideoDetail v) => SourceDetail(
        sourceType: 'bilibili',
        sourceKey: v.bvid,
        sourceSubKey: v.cid.toString(),
        title: v.title,
        uploaderName: v.ownerName,
        uploaderId: v.ownerMid,
        durationSec: v.durationSec,
        playCount: v.playCount,
        coverUrl: v.pic,
        category: v.tname,
        pubdate: v.pubdate,
        tag: v.tag,
        subItems: v.pages
            .map((p) => SourceSubItem(
                  sourceSubKey: p.cid.toString(),
                  pageIndex: p.page,
                  title: p.part,
                  durationSec: p.durationSec,
                ))
            .toList(),
      );
}
