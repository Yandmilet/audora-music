/// B站接口的 DTO 定义。
///
/// 与设计文档 3.2「BilibiliVideo 表」字段对齐，便于直接落库。
library;

/// 搜索结果里的视频候选（Stage 1 产出）
class VideoCandidate {
  final String bvid;
  final String title;
  final String author;
  final int mid;
  final int durationSec;
  final int play;
  final int pubdate;

  /// 分区名（搜索结果里通常没有，详情接口才有）
  final String typename;

  /// 分P id（搜索阶段未知，详情接口补齐）
  final int cid;

  /// 标签（详情接口才可能有）
  final String tag;

  /// 简介
  final String desc;

  const VideoCandidate({
    required this.bvid,
    required this.title,
    this.author = '',
    this.mid = 0,
    this.durationSec = 0,
    this.play = 0,
    this.pubdate = 0,
    this.typename = '',
    this.cid = 0,
    this.tag = '',
    this.desc = '',
  });

  int get durationMs => durationSec * 1000;

  VideoCandidate copyWith({
    String? bvid,
    String? title,
    String? author,
    int? mid,
    int? durationSec,
    int? play,
    int? pubdate,
    String? typename,
    int? cid,
    String? tag,
    String? desc,
  }) {
    return VideoCandidate(
      bvid: bvid ?? this.bvid,
      title: title ?? this.title,
      author: author ?? this.author,
      mid: mid ?? this.mid,
      durationSec: durationSec ?? this.durationSec,
      play: play ?? this.play,
      pubdate: pubdate ?? this.pubdate,
      typename: typename ?? this.typename,
      cid: cid ?? this.cid,
      tag: tag ?? this.tag,
      desc: desc ?? this.desc,
    );
  }

  @override
  String toString() =>
      'VideoCandidate($bvid, "$title", $author, ${durationSec}s, play=$play)';
}

/// 视频分P（合辑场景的核心）
class VideoPage {
  final int cid;
  final int page;
  final String part;
  final int durationSec;

  const VideoPage({
    required this.cid,
    required this.page,
    required this.part,
    required this.durationSec,
  });
}

/// 视频详情（Stage 3 产出）
class VideoDetail {
  final String bvid;
  final int cid;
  final String title;
  final String ownerName;
  final int ownerMid;
  final String tname;
  final int durationSec;
  final int playCount;
  final int pubdate;
  final String desc;
  final String pic;
  final List<VideoPage> pages;

  /// 详情接口的 tag 字段（新版接口可能已移除，为空则不算命中）
  final String tag;

  const VideoDetail({
    required this.bvid,
    required this.cid,
    required this.title,
    this.ownerName = '',
    this.ownerMid = 0,
    this.tname = '',
    required this.durationSec,
    this.playCount = 0,
    this.pubdate = 0,
    this.desc = '',
    this.pic = '',
    this.pages = const [],
    this.tag = '',
  });

  int get durationMs => durationSec * 1000;
}

/// DASH 音频流
class AudioStream {
  final int id;
  final String baseUrl;
  final int bandwidth;
  final String mimeType;
  final String codecs;

  const AudioStream({
    required this.id,
    required this.baseUrl,
    required this.bandwidth,
    this.mimeType = 'audio/mp4',
    this.codecs = '',
  });

  /// 音质的中文标签。注意：部分资料把 30280 标成 320K、30232 标成 128K 是**错的**，
  /// 以 bilibili-API-collect 官方文档为准。
  String get qualityLabel => audioQualityLabel(id, bandwidth: bandwidth);

  /// 数值越大音质越高，用于排序兜底
  int get qualityRank => switch (id) {
        30251 => 500,
        30250 => 450,
        30280 => 300,
        30232 => 200,
        30216 => 100,
        _ => 0,
      };
}

/// 音质优先级：官方推荐顺序，取第一个命中的
const kQualityPriority = [30251, 30250, 30280, 30232, 30216];

/// B站音质 ID → 中文标签。
///
/// 放在顶层而不是 [AudioStream] 的成员里：UI 层（播放页音源详情）拿到的是
/// 「上一次拉流落在库里的 qualityId」，并没有 AudioStream 对象，
/// 之前因此各写了一份映射（Repository 里还有一份私有的），改一处漏一处。
/// [bandwidth] 仅在 ID 不在已知表里时兜底显示。
String audioQualityLabel(int id, {int bandwidth = 0}) => switch (id) {
      30251 => 'Hi-Res 无损',
      30250 => '杜比全景声',
      30280 => '192Kbps',
      30232 => '132Kbps',
      30216 => '64Kbps',
      _ => bandwidth > 0 ? '${(bandwidth / 1000).round()}Kbps' : '未知音质',
    };

/// 音质档位排序值（越大越好）。
///
/// 公开的理由：音质**上限筛选**不只在挑流时用到——缓存里的 URL 也要按
/// 它判断「是否仍符合当前偏好」（见 [SourceResolver] 的缓存命中条件）。
int audioQualityRank(int id) => switch (id) {
      30251 => 500,
      30250 => 450,
      30280 => 300,
      30232 => 200,
      30216 => 100,
      _ => 0,
    };

/// 从 DASH audio 列表里挑最优音质。
///
/// 先按 [kQualityPriority] 命中，全部未命中时用 bandwidth（实际带宽）兜底排序
/// —— 不依赖 ID 映射的准确性。
///
/// [ceiling] 为音质**上限**（用户偏好）。设了上限就只在该档次以内挑，
/// 挑不到再放宽到全部可用流 —— 宁可播差一点，也不能因为偏好过窄而没声。
/// 传 0（默认）表示不限制，等同于「一直取最高」。
AudioStream? pickBestAudio(List<AudioStream> streams, {int ceiling = 0}) {
  if (streams.isEmpty) return null;

  if (ceiling > 0) {
    final ceilingRank = audioQualityRank(ceiling);
    final allowed =
        streams.where((s) => audioQualityRank(s.id) <= ceilingRank).toList();
    // 偏好档位下一首都没有（例如该视频只有更高音质）→ 放宽，别静默无声
    if (allowed.isNotEmpty) return _pickWithin(allowed);
  }
  return _pickWithin(streams);
}

AudioStream? _pickWithin(List<AudioStream> streams) {
  for (final q in kQualityPriority) {
    for (final s in streams) {
      if (s.id == q) return s;
    }
  }
  return streams.reduce((a, b) => a.bandwidth >= b.bandwidth ? a : b);
}
