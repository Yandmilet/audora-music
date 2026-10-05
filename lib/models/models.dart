/// 歌曲数据模型
/// 元数据来源：QQ音乐（歌名/歌手/专辑/作词/作曲/编曲/流派/发行时间/时长）
/// 音源来源：B站视频（通过匹配算法关联）
library;

/// 音乐地区分类。
///
/// 从 MockData 挪到这里：它是**领域常量**（榜单/曲库的地区维度），
/// 与「演示数据」无关。UI 只依赖它时不该被迫 import 整个 mock 文件。
/// 结构：(region key, 中文名, 归属地展示名)
const List<(String, String, String)> kRegions = [
  ('cn', '华语', '中国内地'),
  ('jp', '日本', '日本'),
  ('kr', '韩国', '韩国'),
  ('us', '欧美', '欧美'),
];

/// 音源匹配状态
enum SourceStatus {
  /// 已自动匹配，置信度达标
  ok,

  /// 匹配分处于灰区，需人工确认
  pending,

  /// 未找到可用音源
  none,
}

/// 匹配到的音源。
///
/// ## 通用化字段 vs B站专属字段
/// 步骤 8 起，领域层**只持有通用字段**（sourceType/sourceKey/sourceSubKey）。
/// bvid/cid 变成 getter 委托（B站专属映射），不再是 final 字段。
/// 这样彻底消除了「两个渠道来源的值不同步」的风险——只剩一个真相源。
///
/// 构造参数仍兼容 bvid/cid（所有旧调用点零改动），内部自动映射到通用字段。
///
/// 未来接入 YouTube Music / 网易云音频源时：
/// - sourceType = 'youtube', sourceKey = videoId, sourceSubKey = ''
/// - .bvid getter 返回 videoId（因为 'bvid' 这个名字对 YouTube 没意义，
///   但调用方可能只需要 sourceKey 值，不在意叫什么）
/// - 新代码一律用 sourceKey/sourceSubKey，别再读 bvid/cid
class AudioSource {
  /// 通用音源类型 —— 'bilibili' / 'youtube' / ...
  final String sourceType;

  /// 通用音源主键 —— 对 B站 = bvid，对 YouTube = videoId，等等
  final String sourceKey;

  /// 通用音源子键 —— 对 B站 = cid.toString()（分P定位），
  /// 对无分P的平台留空字符串
  final String sourceSubKey;

  /// B站专属主键 —— 委托到 sourceKey
  String get bvid => sourceKey;

  /// B站专属 cid —— 委托到 sourceSubKey
  int get cid => int.tryParse(sourceSubKey) ?? 0;

  /// 分P标题（多P时用于展示）
  final String? partTitle;

  /// 音频码率标签，如 "192Kbps"
  final String qualityLabel;

  /// DASH 音频质量 ID：30216=64K / 30232=132K / 30280=192K
  final int qualityId;

  /// 匹配总分 0..1
  final double matchScore;

  /// 是否自动通过（AUTO）还是进入人工复核（REVIEW）
  final bool auto;

  /// 时长差值（秒），音源视频时长 - 歌曲时长
  final int durationDelta;

  /// 上传者名称（B站 = UP主）
  final String uploader;

  /// 播放量，用于展示热度
  final int playCount;

  AudioSource({
    required String bvid,
    required int cid,
    String? sourceType,
    String? sourceKey,
    String? sourceSubKey,
    this.partTitle,
    required this.qualityLabel,
    required this.qualityId,
    required this.matchScore,
    required this.auto,
    required this.durationDelta,
    required this.uploader,
    this.playCount = 0,
  })  : sourceType = sourceType ?? 'bilibili',
        sourceKey = sourceKey ?? bvid,
        sourceSubKey = sourceSubKey ?? cid.toString();

  AudioSource copyWith({
    String? sourceType,
    String? sourceKey,
    String? sourceSubKey,
    // 兼容旧代码：单独传 bvid/cid 时自动映射到 sourceKey/sourceSubKey
    String? bvid,
    int? cid,
    String? partTitle,
    String? qualityLabel,
    int? qualityId,
    double? matchScore,
    bool? auto,
    int? durationDelta,
    String? uploader,
    int? playCount,
  }) {
    final effectiveSourceKey = sourceKey ?? bvid ?? this.sourceKey;
    final effectiveSourceSubKey = sourceSubKey ??
        (cid != null ? cid.toString() : this.sourceSubKey);
    return AudioSource(
      // copyWith 同时传 sourceKey/sourceSubKey 和 bvid/cid 时，
      // 先算好 sourceKey/sourceSubKey 再构造，避免两者不一致
      sourceType: sourceType ?? this.sourceType,
      sourceKey: effectiveSourceKey,
      sourceSubKey: effectiveSourceSubKey,
      bvid: effectiveSourceKey,
      cid: int.tryParse(effectiveSourceSubKey) ?? 0,
      partTitle: partTitle ?? this.partTitle,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      qualityId: qualityId ?? this.qualityId,
      matchScore: matchScore ?? this.matchScore,
      auto: auto ?? this.auto,
      durationDelta: durationDelta ?? this.durationDelta,
      uploader: uploader ?? this.uploader,
      playCount: playCount ?? this.playCount,
    );
  }
}

/// 歌曲
class Song {
  /// 数据库行 id。
  ///
  /// 可选的原因：mock 数据、导入过程中的中间态都没有 id；
  /// 只有从 SQLite 读出来的歌才带。需要写库的操作（重新匹配、人工确认）
  /// 必须先检查它是否非空，否则会写错行。
  final int? id;

  final String title;
  final String artist;
  final String album;

  /// 时长（秒）
  final int duration;

  /// 作词 / 作曲 / 编曲
  final String? lyricist;
  final String? composer;
  final String? arranger;

  /// 流派
  final String? genre;

  /// 发行时间
  final DateTime? releaseDate;

  /// 音源匹配状态
  final SourceStatus sourceStatus;

  /// 匹配到的音源（可为空）
  final AudioSource? source;

  /// 是否已收藏
  final bool liked;

  /// 封面渐变索引（真实封面缺失时的占位渐变，由 [CoverArt] 生成）
  final int coverSeed;

  /// QQ 音乐专辑封面 URL（由 albumMid 派生的展示字段，由 DB 侧 /
  /// DTO 拼装，Song 仍不感知 songMid/albumMid 这类存储主键）。
  /// null（mock 数据、来源不明的歌）时 UI 回退 [coverSeed] 占位渐变。
  final String? coverUrl;

  /// 首位歌手的 QQ 音乐 mid。
  ///
  /// 用途：播放页点击歌手名 → 构造 [SingerBrief] → 进入歌手详情页。
  /// 来源：QQSongMeta.singerMid 透传。本地曲库旧数据（加字段前落库）
  /// 可能为 null，此时歌手名点击入口仍可显示但会给出友好提示。
  final String? singerMid;

  /// 首位歌手的数字 ID（fetchSingerAlbums 必需）。
  ///
  /// null 时 SingerDetailScreen 降级为只展示「热门歌曲」tab。
  final int? singerId;

  /// 专辑 mid（用于在歌手详情页专辑列表里定位当前歌曲所在专辑）。
  ///
  /// 之前只有 SongRow 有这个字段（用来拼 coverUrl），现在暴露到 Song 模型。
  final String? albumMid;

  /// 歌词手动校准偏移（毫秒）。
  ///
  /// **语义**：正数 = 歌词整体后移（播放位置要再推进一点才到这一句）；
  /// 负数 = 歌词整体前移。默认 0 表示不偏移。
  ///
  /// **存储粒度**：per-song 而非 per-source。同一首歌的不同音源偏移可能不同，
  /// 但 90% 场景下换音源只需重新校准一次，换来 schema 大幅简化。
  ///
  /// **生效位置**：AppState.mappedLyricMs() 把播放器真实位置 × 比例因子
  /// 后加上这个值，映射到 LRC 时间空间再做行查找。
  final int lyricOffsetMs;

  const Song({
    this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.albumMid,
    required this.duration,
    this.lyricist,
    this.composer,
    this.arranger,
    this.genre,
    this.releaseDate,
    this.sourceStatus = SourceStatus.ok,
    this.source,
    this.liked = false,
    required this.coverSeed,
    this.coverUrl,
    this.singerMid,
    this.singerId,
    this.lyricOffsetMs = 0,
  });

  /// 唯一键：歌名 + 歌手（用于同名异曲消歧）
  String get key => '$title|$artist';

  Song copyWith({
    int? id,
    String? title,
    String? artist,
    String? album,
    String? albumMid,
    int? duration,
    String? lyricist,
    String? composer,
    String? arranger,
    String? genre,
    DateTime? releaseDate,
    SourceStatus? sourceStatus,
    AudioSource? source,
    bool? liked,
    int? coverSeed,
    String? coverUrl,
    String? singerMid,
    int? singerId,
    int? lyricOffsetMs,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumMid: albumMid ?? this.albumMid,
      duration: duration ?? this.duration,
      lyricist: lyricist ?? this.lyricist,
      composer: composer ?? this.composer,
      arranger: arranger ?? this.arranger,
      genre: genre ?? this.genre,
      releaseDate: releaseDate ?? this.releaseDate,
      sourceStatus: sourceStatus ?? this.sourceStatus,
      source: source ?? this.source,
      liked: liked ?? this.liked,
      coverSeed: coverSeed ?? this.coverSeed,
      coverUrl: coverUrl ?? this.coverUrl,
      singerMid: singerMid ?? this.singerMid,
      singerId: singerId ?? this.singerId,
      lyricOffsetMs: lyricOffsetMs ?? this.lyricOffsetMs,
    );
  }

  String get durationText {
    final m = duration ~/ 60;
    final s = duration % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// 排行榜
class Board {
  final String name;

  /// 区域：华语 / 日本 / 韩国 / 欧美
  final String region;

  /// 榜单归属地展示名
  final String regionLabel;
  final List<Song> songs;

  const Board({
    required this.name,
    required this.region,
    required this.regionLabel,
    required this.songs,
  });
}

/// 播放模式
enum PlayMode { sequential, shuffle, repeatOne }

extension PlayModeX on PlayMode {
  String get label => switch (this) {
        PlayMode.sequential => '顺序播放',
        PlayMode.shuffle => '随机播放',
        PlayMode.repeatOne => '单曲循环',
      };
}
