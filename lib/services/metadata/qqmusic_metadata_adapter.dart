/// 适配器：让 [QQMusicProvider] 实现 [MetadataProvider] 接口。
///
/// ## 设计原则
/// 本适配器是**薄转调层** —— 不做任何业务逻辑改动，只负责：
/// 1. 把通用 DTO（MetaSong / MetaLyric）与 QQ 专属 DTO（QQSongMeta / QQLyric）
///    互相转换。批量 DTO 两侧本就是同一套类型，不涉及转换。
/// 2. 把 MetadataProvider 接口签名转调给 QQMusicProvider 的同名方法。
///
/// 这样做的好处：
/// - QQMusicProvider 的**行为零改动** —— 所有现有单测继续绿。
/// - Adapter 内部不涉及任何源专属业务逻辑 —— 未来换网易云/Spotify 时
///   只要再写一个同结构的 Adapter，Repository / MatchEngine / UI 全部不感知。
/// - 批量解析 DTO（BatchQuery / BatchRejection / ResolvedEntry /
///   BatchResolveResult）只在 metadata_provider.dart 定义一份，
///   qqmusic_dto.dart re-export 同一套类型 —— 所以 resolveBatch 是纯透传，
///   不需要任何字段拷贝（Dart 无 structural typing，同名不同类是赋不了值的）。
library;

import 'metadata_provider.dart';
import '../qqmusic/qqmusic_dto.dart' as qq;
import '../qqmusic/qqmusic_provider.dart';

/// QQ音乐元数据适配器。
///
/// 构造时接收一个已有的 [QQMusicProvider] 实例（可带自定义 Dio /
/// 限流器等），Adapter 不自己 new —— 由装配层决定实例化方式。
class QQMusicMetadataAdapter implements MetadataProvider {
  const QQMusicMetadataAdapter(this._qq);

  final QQMusicProvider _qq;

  @override
  String get sourceType => 'qq';

  // ═══════════════════════════════════════════════════════════════
  // 转调实现
  // ═══════════════════════════════════════════════════════════════

  @override
  Future<List<MetaSong>> search(String keyword, {int pageSize = 20}) async {
    final list = await _qq.search(keyword, pageSize: pageSize);
    return list.map(_qqSongMetaToMeta).toList();
  }

  @override
  Future<MetaSong?> fetchDetail(MetaSong base) async {
    if (base.sourceId.isEmpty) return null;
    // 需要先把 MetaSong 转回 QQSongMeta 才能调 fetchDetail
    final qqMeta = _metaSongToQq(base);
    final detail = await _qq.fetchDetail(qqMeta);
    if (detail == null) return null;
    return _qqSongMetaToMeta(detail);
  }

  @override
  Future<MetaLyric?> fetchLyric(String sourceId) async {
    final qqLyric = await _qq.fetchLyric(sourceId);
    if (qqLyric == null) return null;
    return MetaLyric(
      lrc: qqLyric.lrc,
      translation: qqLyric.trans,
      credits: MetaCredits(
        lyricist: qqLyric.credits.lyricist,
        composer: qqLyric.credits.composer,
        arranger: qqLyric.credits.arranger,
      ),
    );
  }

  @override
  Future<BatchResolveResult> resolveBatch(
    List<BatchQuery> queries, {
    int durationToleranceSec = 5,
    bool withLyricCredits = false,
    void Function(int done, int total)? onProgress,
    void Function(BatchQuery query, String reason)? onReject,
  }) async {
    // 批量 DTO 两侧共用同一套类型（见文件头说明），直接透传。
    return _qq.resolveBatch(
      queries,
      durationToleranceSec: durationToleranceSec,
      withLyricCredits: withLyricCredits,
      onProgress: onProgress,
      onReject: onReject,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // DTO 互转
  // ═══════════════════════════════════════════════════════════════

  /// QQSongMeta → MetaSong（搜索/详情 → 通用 DTO）
  MetaSong _qqSongMetaToMeta(qq.QQSongMeta m) => MetaSong(
        sourceId: m.songMid,
        sourceType: 'qq',
        title: m.title,
        artists: m.artists,
        album: m.album,
        durationSec: m.interval,
        coverSourceId: m.albumMid,
        coverUrl: m.coverUrl,
        releaseDate: m.releaseDate,
        subtitle: m.subtitle,
      );

  /// MetaSong → QQSongMeta（通用 DTO → 搜索前的「base」对象）
  ///
  /// fetchDetail 需要一个 QQSongMeta 作为入参（它要拿 songMid），
  /// 所以这里把通用 MetaSong 转回 QQ 专属。
  qq.QQSongMeta _metaSongToQq(MetaSong m) => qq.QQSongMeta(
        songMid: m.sourceId,
        title: m.title,
        artists: m.artists,
        album: m.album,
        albumMid: m.coverSourceId,
        interval: m.durationSec,
        releaseDate: m.releaseDate,
        subtitle: m.subtitle,
      );

}
