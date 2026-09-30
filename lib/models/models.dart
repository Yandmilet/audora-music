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

/// 匹配到的 B 站音源
class AudioSource {
  /// 视频 BV 号
  final String bvid;

  /// 分P的 cid（多P视频必需，(bvid,cid) 为复合键）
  final int cid;

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

  /// 时长差值（秒），B站视频时长 - 歌曲时长
  final int durationDelta;

  /// UP 主名称
  final String uploader;

  /// 播放量，用于展示热度
  final int playCount;

  const AudioSource({
    required this.bvid,
    required this.cid,
    this.partTitle,
    required this.qualityLabel,
    required this.qualityId,
    required this.matchScore,
    required this.auto,
    required this.durationDelta,
    required this.uploader,
    this.playCount = 0,
  });

  AudioSource copyWith({
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
    return AudioSource(
      bvid: bvid ?? this.bvid,
      cid: cid ?? this.cid,
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

  const Song({
    this.id,
    required this.title,
    required this.artist,
    this.album = '',
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
  });

  /// 唯一键：歌名 + 歌手（用于同名异曲消歧）
  String get key => '$title|$artist';

  Song copyWith({
    int? id,
    String? title,
    String? artist,
    String? album,
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
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
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
