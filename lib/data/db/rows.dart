/// 领域模型 ↔ SQLite 行的映射。
///
/// ## 为什么单独一层（不直接给 model 加 toMap）
/// 领域模型 `Song` 是**给 UI 和算法用的**，不该感知数据库细节
/// （比如 `qq_song_mid` 这个纯存储概念、`created_at` 这种审计字段）。
/// 中间的 Entity 层承担两件事：
///   1. 单位 / 命名转换（domain `duration`(秒) ↔ db `duration_ms`）
///   2. 补上 domain 不需要但存储必需的字段（qqSongMid / 时间戳）
library;

import '../../models/models.dart';
import '../../services/match/match_config.dart';
import '../../services/match/match_scorer.dart';
import '../../services/qqmusic/qqmusic_dto.dart' show QQSongMeta;

/// Song 表的行表示
class SongRow {
  final int? id;

  /// QQ音乐唯一标识。**domain 的 Song 里没有这个字段**——
  /// 它是纯存储概念。解析时由 provider 的 songMid 提供，
  /// 手动录入的歌则用 `title|artist` 的哈希兜底（保证 UNIQUE 不冲突）。
  ///
  /// ⚠️ 步骤 6 双写期：qq_song_mid 照常读写，meta_source_type/meta_source_id
  /// 是它的冗余副本（QQ 歌两者值相同）。步骤 7 领域模型接上后逐步让新写入只走通用列。
  final String qqSongMid;

  /// 通用元数据源类型 —— 'qq' / 'netease' / ...（未来扩展）
  final String metaSourceType;

  /// 通用元数据源 ID —— 与 meta_source_type 配对，唯一标识一首歌
  final String metaSourceId;

  final String title;
  final String artists;
  final String album;
  final String albumMid;
  final String singerMid;
  final int? singerId;
  final String? lyricist;
  final String? composer;
  final String? arranger;
  final String? genre;
  final int? releaseDate;
  final int durationMs;
  final int coverSeed;
  final int lyricOffsetMs;
  final int createdAt;
  final int updatedAt;

  const SongRow({
    this.id,
    required this.qqSongMid,
    this.metaSourceType = 'qq',
    this.metaSourceId = '',
    required this.title,
    required this.artists,
    this.album = '',
    this.albumMid = '',
    this.singerMid = '',
    this.singerId,
    this.lyricist,
    this.composer,
    this.arranger,
    this.genre,
    this.releaseDate,
    this.durationMs = 0,
    this.coverSeed = 0,
    this.lyricOffsetMs = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'qq_song_mid': qqSongMid,
        // 双写：新库用 (meta_source_type, meta_source_id) 唯一，
        // 旧库只有 (qq_song_mid) 唯一，两套都写上保证旧库 UNIQUE 不冲突
        'meta_source_type': metaSourceType,
        'meta_source_id': metaSourceId.isEmpty ? qqSongMid : metaSourceId,
        'title': title,
        'artists': artists,
        'album': album,
        'album_mid': albumMid,
        'singer_mid': singerMid,
        'singer_id': singerId,
        'lyricist': lyricist,
        'composer': composer,
        'arranger': arranger,
        'genre': genre,
        'release_date': releaseDate,
        'duration_ms': durationMs,
        'cover_seed': coverSeed,
        'lyric_offset_ms': lyricOffsetMs,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory SongRow.fromMap(Map<String, Object?> m) {
    // 读通用列，为空时兜底从旧列派生（兼容 v4→v5 迁移前的老行）
    final metaType = m['meta_source_type'] as String?;
    final metaId = m['meta_source_id'] as String?;
    final qqMid = m['qq_song_mid'] as String? ?? '';
    return SongRow(
      id: m['id'] as int?,
      qqSongMid: qqMid,
      metaSourceType: (metaType != null && metaType.isNotEmpty) ? metaType : 'qq',
      metaSourceId: (metaId != null && metaId.isNotEmpty) ? metaId : qqMid,
      title: m['title'] as String? ?? '',
      artists: m['artists'] as String? ?? '',
      album: m['album'] as String? ?? '',
      albumMid: m['album_mid'] as String? ?? '',
      singerMid: m['singer_mid'] as String? ?? '',
      singerId: m['singer_id'] as int?,
      lyricist: m['lyricist'] as String?,
      composer: m['composer'] as String?,
      arranger: m['arranger'] as String?,
      genre: m['genre'] as String?,
      releaseDate: m['release_date'] as int?,
      durationMs: m['duration_ms'] as int? ?? 0,
      coverSeed: m['cover_seed'] as int? ?? 0,
      lyricOffsetMs: m['lyric_offset_ms'] as int? ?? 0,
      createdAt: m['created_at'] as int? ?? 0,
      updatedAt: m['updated_at'] as int? ?? 0,
    );
  }

  /// 领域 Song → 行。
  ///
  /// [qqSongMid] 必需：QQ音乐来源的歌用真实 mid；
  /// 手动录入或来源不明时用 `title|artist` 派生（见 [deriveMid]）。
  /// [metaSourceType]/[metaSourceId] 默认从 qqSongMid 派生（'qq' + qqSongMid），
  /// 将来接入其他元数据源时调用方传入正确值。
  factory SongRow.fromSong(
    Song song, {
    required String qqSongMid,
    String albumMid = '',
    String singerMid = '',
    int? singerId,
    String metaSourceType = 'qq',
    String? metaSourceId,
    int? createdAt,
    int? now,
  }) {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final release = song.releaseDate;
    final effectiveMetaId = metaSourceId ?? qqSongMid;
    return SongRow(
      qqSongMid: qqSongMid,
      metaSourceType: metaSourceType,
      metaSourceId: effectiveMetaId,
      title: song.title,
      artists: song.artist,
      album: song.album,
      albumMid: albumMid,
      singerMid: singerMid,
      singerId: singerId,
      lyricist: song.lyricist,
      composer: song.composer,
      arranger: song.arranger,
      genre: song.genre,
      releaseDate:
          release == null ? null : release.millisecondsSinceEpoch ~/ 1000,
      durationMs: song.duration * 1000,
      coverSeed: song.coverSeed,
      lyricOffsetMs: song.lyricOffsetMs,
      createdAt: createdAt ?? ts,
      updatedAt: ts,
    );
  }

  /// 行 → 领域 Song。注意 `duration_ms` 转回**秒**。
  Song toSong({AudioSource? source, SourceStatus? status, bool liked = false}) {
    return Song(
      // 带上数据库 id：播放页/重匹配需要它来定位行
      id: id,
      title: title,
      artist: artists,
      album: album,
      albumMid: albumMid.isEmpty ? null : albumMid,
      duration: durationMs ~/ 1000,
      lyricist: lyricist,
      composer: composer,
      arranger: arranger,
      genre: genre,
      releaseDate: releaseDate == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(releaseDate! * 1000),
      sourceStatus: status ?? SourceStatus.none,
      source: source,
      liked: liked,
      coverSeed: coverSeed,
      // 封面 URL 从落库的 album_mid 拼出（读回即带，UI 不必再查详情）。
      // album_mid 为空（mock/手动录入）→ null → UI 回退占位渐变。
      coverUrl: QQSongMeta.coverUrlFor(albumMid),
      // singerMid 为空字符串时转 null（与 Song 模型的可空语义对齐）
      singerMid: singerMid.isEmpty ? null : singerMid,
      singerId: singerId,
      lyricOffsetMs: lyricOffsetMs,
    );
  }

  /// 手动录入 / 来源不明时的 mid 兜底。
  ///
  /// 用 `local:` 前缀 + title|artist 区分于真实 QQ mid，
  /// 避免与真实 mid 撞键（真实 mid 是 14 位十六进制，不会带这个前缀）。
  static String deriveMid(String title, String artist) =>
      'local:${title.toLowerCase().trim()}|${artist.toLowerCase().trim()}';

  bool get isLocal => qqSongMid.startsWith('local:');
}

/// BilibiliVideo 表的行表示
class VideoRow {
  final String bvid;
  final int cid;

  /// 通用音源类型 —— 'bilibili' / 'youtube' / ...（未来扩展）
  final String sourceType;

  /// 通用音源主键 —— 对 B站 = bvid，对 YouTube = videoId，等等
  final String sourceKey;

  /// 通用音源子键 —— 对 B站 = cid.toString()（分P定位），
  /// 对无分P的平台可留空
  final String sourceSubKey;

  final String title;
  final String author;
  final int mid;
  final int durationMs;
  final String typename;
  final String? tag;
  final String? description;
  final int playCount;
  final int pubdate;
  final int fetchedAt;
  final String? audioUrl;
  final int? audioUrlExpireAt;
  final int? audioQualityId;
  final int? audioBitrate;
  final bool available;
  final String? unavailableReason;

  const VideoRow({
    required this.bvid,
    required this.cid,
    this.sourceType = 'bilibili',
    this.sourceKey = '',
    this.sourceSubKey = '',
    required this.title,
    this.author = '',
    this.mid = 0,
    this.durationMs = 0,
    this.typename = '',
    this.tag,
    this.description,
    this.playCount = 0,
    this.pubdate = 0,
    required this.fetchedAt,
    this.audioUrl,
    this.audioUrlExpireAt,
    this.audioQualityId,
    this.audioBitrate,
    this.available = true,
    this.unavailableReason,
  });

  Map<String, Object?> toMap() => {
        'bvid': bvid,
        'cid': cid,
        // 双写：source_key/source_sub_key 与 bvid/cid 冗余副本
        // 旧库只在 (bvid) 上有主键约束，新库 UNIQUE 还没改（步骤 8）
        'source_type': sourceType,
        'source_key': sourceKey.isEmpty ? bvid : sourceKey,
        'source_sub_key': sourceSubKey.isEmpty ? cid.toString() : sourceSubKey,
        'title': title,
        'author': author,
        'mid': mid,
        'duration_ms': durationMs,
        'typename': typename,
        'tag': tag,
        // 简介截断存 500 字（设计文档 3.2 明确要求）
        'description': description == null
            ? null
            : (description!.length > 500
                ? description!.substring(0, 500)
                : description),
        'play_count': playCount,
        'pubdate': pubdate,
        'fetched_at': fetchedAt,
        'audio_url': audioUrl,
        'audio_url_expire_at': audioUrlExpireAt,
        'audio_quality_id': audioQualityId,
        'audio_bitrate': audioBitrate,
        'available': available ? 1 : 0,
        'unavailable_reason': unavailableReason,
      };

  factory VideoRow.fromMap(Map<String, Object?> m) {
    // 读通用列，为空时兜底从旧列派生（兼容 v4→v5 迁移前的老行）
    final srcType = m['source_type'] as String?;
    final srcKey = m['source_key'] as String?;
    final srcSub = m['source_sub_key'] as String?;
    final bvid = m['bvid'] as String? ?? '';
    final cid = m['cid'] as int? ?? 0;
    return VideoRow(
      bvid: bvid,
      cid: cid,
      sourceType: (srcType != null && srcType.isNotEmpty) ? srcType : 'bilibili',
      sourceKey: (srcKey != null && srcKey.isNotEmpty) ? srcKey : bvid,
      sourceSubKey: (srcSub != null && srcSub.isNotEmpty) ? srcSub : cid.toString(),
      title: m['title'] as String? ?? '',
      author: m['author'] as String? ?? '',
      mid: m['mid'] as int? ?? 0,
      durationMs: m['duration_ms'] as int? ?? 0,
      typename: m['typename'] as String? ?? '',
      tag: m['tag'] as String?,
      description: m['description'] as String?,
      playCount: m['play_count'] as int? ?? 0,
      pubdate: m['pubdate'] as int? ?? 0,
      fetchedAt: m['fetched_at'] as int? ?? 0,
      audioUrl: m['audio_url'] as String?,
      audioUrlExpireAt: m['audio_url_expire_at'] as int?,
      audioQualityId: m['audio_quality_id'] as int?,
      audioBitrate: m['audio_bitrate'] as int?,
      available: (m['available'] as int? ?? 1) == 1,
      unavailableReason: m['unavailable_reason'] as String?,
    );
  }

  bool get isAudioUrlValid {
    if (audioUrl == null || audioUrl!.isEmpty) return false;
    if (audioUrlExpireAt == null) return false;
    // 留 5 分钟安全边际（设计文档 8.2）
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now < audioUrlExpireAt! - 300;
  }
}

/// SongSourceBinding 表的行表示
class BindingRow {
  final int? id;
  final int songId;
  final String bvid;

  /// 通用音源类型 —— 默认 'bilibili'（步骤 6 双写期冗余副本）
  final String sourceType;

  /// 通用音源主键 —— 默认等于 bvid
  final String sourceKey;

  final bool isActive;
  final double matchScore;
  final MatchConfidence confidence;

  /// 六维分数明细的 JSON 串
  final String? scoreDetail;
  final MatchType matchType;
  final int matchedAt;
  final String? note;

  const BindingRow({
    this.id,
    required this.songId,
    required this.bvid,
    this.sourceType = 'bilibili',
    this.sourceKey = '',
    this.isActive = false,
    required this.matchScore,
    required this.confidence,
    this.scoreDetail,
    required this.matchType,
    required this.matchedAt,
    this.note,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'song_id': songId,
        'bvid': bvid,
        // 双写：source_type/source_key 与 bvid 冗余副本
        'source_type': sourceType,
        'source_key': sourceKey.isEmpty ? bvid : sourceKey,
        'is_active': isActive ? 1 : 0,
        'match_score': matchScore,
        'confidence': confidence.label,
        'score_detail': scoreDetail,
        'match_type': matchType.label,
        'matched_at': matchedAt,
        'note': note,
      };

  factory BindingRow.fromMap(Map<String, Object?> m) {
    // 读通用列，为空时兜底从旧列派生
    final srcType = m['source_type'] as String?;
    final srcKey = m['source_key'] as String?;
    final bvid = m['bvid'] as String? ?? '';
    return BindingRow(
      id: m['id'] as int?,
      songId: m['song_id'] as int? ?? 0,
      bvid: bvid,
      sourceType: (srcType != null && srcType.isNotEmpty) ? srcType : 'bilibili',
      sourceKey: (srcKey != null && srcKey.isNotEmpty) ? srcKey : bvid,
      isActive: (m['is_active'] as int? ?? 0) == 1,
      matchScore: (m['match_score'] as num?)?.toDouble() ?? 0,
      confidence: _parseConfidence(m['confidence']?.toString()),
      scoreDetail: m['score_detail'] as String?,
      matchType: _parseMatchType(m['match_type']?.toString()),
      matchedAt: m['matched_at'] as int? ?? 0,
      note: m['note'] as String?,
    );
  }

  /// 从打分结果构造（自动匹配路径）
  factory BindingRow.fromScored({
    required int songId,
    required ScoredCandidate scored,
    bool isActive = false,
    String? note,
    int? now,
  }) {
    final bvid = scored.video.bvid;
    return BindingRow(
      songId: songId,
      bvid: bvid,
      sourceType: 'bilibili',
      sourceKey: bvid,
      isActive: isActive,
      matchScore: scored.total,
      confidence: scored.confidence,
      // score_detail 存 JSON —— 可调优的关键（设计文档 3.3）
      scoreDetail: detailToJson(scored.detail),
      matchType: MatchType.autoMatched,
      matchedAt: now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      note: note,
    );
  }

  /// 从原始分数构造（人工绑定路径 —— 此时没有 VideoCandidate，
  /// 只有用户/算法给出的一个分数和可选的六维明细）。
  factory BindingRow.fromManual({
    required int songId,
    required String bvid,
    required double score,
    ScoreDetail? detail,
    MatchType matchType = MatchType.manualBound,
    String? note,
    int? now,
  }) {
    return BindingRow(
      songId: songId,
      bvid: bvid,
      sourceType: 'bilibili',
      sourceKey: bvid,
      isActive: true,
      matchScore: score,
      // 人工绑定的置信度必然是确定的，标 AUTO 表示「可直接播放」
      confidence: MatchConfidence.auto,
      scoreDetail: detail == null ? null : detailToJson(detail),
      matchType: matchType,
      matchedAt: now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      note: note,
    );
  }

  /// ScoreDetail → JSON 串。
  ///
  /// 手写而不是用 `dart:convert`，原因：字段是 6 个固定数值键 + penalty，
  /// 手写能保证**键顺序稳定**（便于 `score_detail` 直接肉眼比对和
  /// 设计文档 5.3 的 `json_extract` 查询）。
  static String detailToJson(ScoreDetail d) {
    final m = d.toJson();
    final buf = StringBuffer('{');
    var first = true;
    m.forEach((k, v) {
      if (!first) buf.write(',');
      first = false;
      buf.write('"$k":$v');
    });
    buf.write('}');
    return buf.toString();
  }

  /// 解析 score_detail JSON（s1..s6 必需 + penalty 可选，v0.4 新增）
  ScoreDetail? get parsedDetail {
    final raw = scoreDetail;
    if (raw == null || raw.isEmpty) return null;
    try {
      final cleaned = raw.replaceAll(RegExp(r'[{}"\s]'), '');
      final parts = cleaned.split(',');
      final map = <String, double>{};
      for (final p in parts) {
        final kv = p.split(':');
        if (kv.length != 2) continue;
        final v = double.tryParse(kv[1]);
        if (v != null) map[kv[0]] = v;
      }
      if (map.length < 6) return null;
      return ScoreDetail(
        s1TitleArtist: map['s1'] ?? 0,
        s2Duration: map['s2'] ?? 0,
        s3Uploader: map['s3'] ?? 0,
        s4Publish: map['s4'] ?? 0,
        s5Category: map['s5'] ?? 0,
        s6Format: map['s6'] ?? 0,
        // v0.4 起 score_detail 带 penalty 键；老数据（v0.3 落库）没有，兜 0
        penalty: map['penalty'] ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static MatchConfidence _parseConfidence(String? s) => switch (s) {
        'AUTO' => MatchConfidence.auto,
        'REJECTED' => MatchConfidence.rejected,
        _ => MatchConfidence.review,
      };

  static MatchType _parseMatchType(String? s) => switch (s) {
        'MANUAL_BOUND' => MatchType.manualBound,
        'USER_SELECTED' => MatchType.userSelected,
        _ => MatchType.autoMatched,
      };
}
