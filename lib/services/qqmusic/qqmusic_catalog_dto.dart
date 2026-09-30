/// QQ音乐**目录浏览**接口的 DTO（歌手库 / 歌单推荐 / 榜单 / 新歌推荐）。
///
/// ## 与 `qqmusic_dto.dart` 的分工
/// `qqmusic_dto.dart` 负责「一首歌的元数据」；这里是「歌的集合 + 集合本身的
/// 元信息」。两者共同点是歌曲一律归一到 [QQSongMeta]，这样目录里的任何一首
/// 都能直接走既有的入库 → 匹配 → 播放链路，不需要第二套模型。
///
/// ## 实测接口对照（2026-09 验证可用）
/// | 用途 | 接口 | 备注 |
/// |---|---|---|
/// | 榜单分组 | POST `musicu.fcg` `musicToplist.ToplistInfoServer/GetAll` | → `data.group[].toplist[]` |
/// | 榜单详情 | POST `musicu.fcg` `.../GetDetail` | → `data.songInfoList[]`（**有 mid**）|
/// | 歌手列表 | GET `c.y.qq.com/v8/fcg-bin/v8.fcg?channel=singer&page=list` | → `data.list[]` |
/// | 歌手歌曲 | POST `musicu.fcg` `music.web_singer_info_svr/get_singer_detail_info` | → `data.songlist[]` |
/// | 歌单列表 | GET `c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg` | → `data.list[]` |
/// | 歌单详情 | POST `musicu.fcg` `music.srfDissInfo.aiDissInfo/uniform_get_Dissinfo` | → `dirinfo` + `songlist[]` |
/// | 新歌 | 榜单 `topId=27`（巅峰榜·新歌） | 复用榜单详情 |
library;

import 'qqmusic_dto.dart';

/// 歌手地区编码 → 中文标签（接口的 `Farea` 字段）。
///
/// ## 这**不是**筛选项，只是显示用的字典
/// 实测发现：歌手列表接口的 `area` / `key` 参数**服务端直接忽略**
/// （传 -100/1/2/3/4/5 返回的总数和内容完全一致，`key` 换成非
/// `all_all_all` 还会返回非 JSON 的错误页）。所以「按地区筛歌手」这件事
/// 用现有可用接口做不到。
///
/// 与其摆出一排点了没反应的筛选按钮，不如把 `Farea` 当**标签**显示出来
/// （每行歌手后面缀「内地」「港台」），信息是真的，交互也不骗人。
const Map<int, String> kSingerAreaLabels = {
  0: '',
  1: '内地',
  2: '港台',
  3: '欧美',
  4: '日本',
  5: '韩国',
  6: '其他',
};

/// 歌单排序。[QQMusicProvider.fetchPlaylists] 的 `sortId` 参数取值。
///
/// 实测 1/3/4/5 返回的是同一批（都是「推荐」语义），只有 2 是「最新」。
/// 所以这里只暴露两个**真实不同**的档位，不摆出四个其实一样的按钮。
const List<(int, String)> kPlaylistSorts = [(5, '推荐'), (2, '最新')];

/// 新歌榜的 topId（巅峰榜·新歌）。
const int kNewSongTopId = 27;

/// 一个榜单分组（巅峰榜 / 地区榜 / 特色榜 / 全球榜）
class ToplistGroup {
  final String name;
  final List<ToplistBrief> toplists;

  const ToplistGroup({required this.name, required this.toplists});
}

/// 榜单卡片。含前几首预览，让卡片本身就有信息量（不必点进去才知道是什么榜）。
class ToplistBrief {
  final int topId;
  final String title;

  /// 次级标题，形如「飙升榜 第272天」
  final String subtitle;

  /// 更新时间，接口给的是「2026-09-29」这样的日期串
  final String updateTime;

  final int listenNum;

  /// 榜内歌曲总数
  final int totalNum;

  final List<ToplistPreviewRow> preview;

  const ToplistBrief({
    required this.topId,
    required this.title,
    this.subtitle = '',
    this.updateTime = '',
    this.listenNum = 0,
    this.totalNum = 0,
    this.preview = const [],
  });
}

/// 榜单卡片上的**预览行**。
///
/// ## 为什么是独立类型，而不是复用 [QQSongMeta]
/// 榜单**列表**接口（`GetAll`）返回的预览歌只有 `songId`（数字）、标题、歌手名，
/// **没有 `songMid`**。没有 mid 就无法入库、无法匹配音源、无法取歌词。
///
/// 如果这里图省事复用 [QQSongMeta]，就会得到一个 `songMid == ''` 的假歌曲对象，
/// 一旦有人拿它去播放，链路上会静默退化成 `local:` 派生键（E23 的同类陷阱）。
/// 用一个**结构上就没有 mid 字段**的类型，让「预览不可播放」这件事写在类型里：
/// 要播必须进详情页（`GetDetail` 才给 mid）。
class ToplistPreviewRow {
  final int rank;
  final String title;
  final String singer;

  const ToplistPreviewRow({
    required this.rank,
    required this.title,
    required this.singer,
  });
}

/// 榜单详情（可播放：这里的歌都带真实 mid）
class ToplistDetail {
  final int topId;
  final String title;
  final String updateTime;
  final int listenNum;
  final List<QQSongMeta> songs;

  const ToplistDetail({
    required this.topId,
    required this.title,
    this.updateTime = '',
    this.listenNum = 0,
    this.songs = const [],
  });

  bool get isEmpty => songs.isEmpty;
}

/// 歌手条目
class SingerBrief {
  /// 歌手 mid，查他的歌要用它
  final String mid;
  final String name;

  /// 别名/英文名（接口的 `Fother_name`），可能为空
  final String otherName;

  /// 拼音首字母（接口的 `Findex`），用于索引分组
  final String letter;

  /// 地区编码，见 [kSingerAreaLabels]
  final int area;

  const SingerBrief({
    required this.mid,
    required this.name,
    this.otherName = '',
    this.letter = '',
    this.area = 0,
  });
}

/// 歌手列表的一页
class SingerPage {
  final List<SingerBrief> singers;
  final int total;
  final int page;
  final int totalPage;

  const SingerPage({
    required this.singers,
    this.total = 0,
    this.page = 1,
    this.totalPage = 1,
  });

  bool get hasMore => page < totalPage;
}

/// 歌单条目（推荐列表用）
class PlaylistBrief {
  /// 歌单 id（接口字段叫 `dissid`）
  final String dissId;
  final String title;

  /// 封面 URL。歌单卡片有没有真封面，观感差别极大——
  /// 这是整个目录里**唯一**能拿到真实图片的地方（歌曲封面靠 albumMid 拼）。
  final String cover;

  final int listenNum;
  final String creator;
  final String introduction;

  const PlaylistBrief({
    required this.dissId,
    required this.title,
    this.cover = '',
    this.listenNum = 0,
    this.creator = '',
    this.introduction = '',
  });
}

/// 歌单详情
class PlaylistDetail {
  final String dissId;
  final String title;
  final String cover;
  final int listenNum;
  final String description;

  /// 歌单声明**总数**（接口的 `total_song_num`）。
  /// 与 `songs.length` 可能不等：版权下架的歌会被过滤掉（`filtered_song`）。
  /// 分开记录是为了不把「过滤」误报成「只有这么多」。
  final int total;
  final List<QQSongMeta> songs;

  const PlaylistDetail({
    required this.dissId,
    required this.title,
    this.cover = '',
    this.listenNum = 0,
    this.description = '',
    this.total = 0,
    this.songs = const [],
  });
}
