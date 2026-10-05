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
/// | 歌手列表 | POST `musicu.fcg` `Music.SingerListServer/get_singer_list` | → `data.singerlist[]`（**支持地区/类型/首字母筛选**）|
/// | 歌手歌曲 | POST `musicu.fcg` `music.web_singer_info_svr/get_singer_detail_info` | → `data.songlist[]` |
/// | 歌单列表 | GET `c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg` | → `data.list[]` |
/// | 歌单详情 | POST `musicu.fcg` `music.srfDissInfo.aiDissInfo/uniform_get_Dissinfo` | → `dirinfo` + `songlist[]` |
/// | 新歌 | 榜单 `topId=27`（巅峰榜·新歌） | 复用榜单详情 |
library;

import 'qqmusic_dto.dart';

// ═══════════════════════════════════════════════════════════════
// 歌手筛选字典（地区 / 类型 / 首字母）
// ═══════════════════════════════════════════════════════════════
//
// ## 口径来源：服务端自己的 `tags` 字典，不是我们猜的
// 新版歌手列表接口 `Music.SingerListServer/get_singer_list` 在返回体里
// 直接给了 `data.tags.{area,sex,genre,index}`，下面三张表与之逐字对齐
// （2026-09-30 实测抓取）。只要有接口能自报取值域，就不应该由客户端硬编。
//
// ## 与旧实现的区别（重要）
// 旧实现走 `c.y.qq.com/v8/fcg-bin/v8.fcg?channel=singer`，它的 `area`/`key`
// 参数**被服务端忽略**（传任何值都返回同一批，`key` 换成非 `all_all_all`
// 还会返回非 JSON 的错误页），所以当时只能把 `Farea` 当标签显示、
// 不敢做筛选按钮。新接口的筛选是**真实生效**的：
//   欧美+男+首字母A → 493 人；日本+女 → 461 人（均实测）。
// 因此本节从「显示用字典」升级为「筛选项字典」。

/// 服务端 `area` 的「全部」哨兵值。`sex` / `index` 的「全部」同值。
const int kSingerAll = -100;

/// 地区筛选项：(标签, 服务端 `area` 取值列表)。
///
/// ## 「华语」为什么要两个 id
/// 服务端把内地(`200`)与港台(`2`)拆成**互不重叠**的两档
/// （实测 内地 3364 人 / 港台 1538 人；周杰伦、陈奕迅、林俊杰都在港台档）。
/// 而中文语境下的「中」= 华语 = 内地 + 港台，若只取 `200`，
/// 用户点「中国」会看不到周杰伦——那是明显的错误。
///
/// 所以这一档在客户端合并两条分页流，详见
/// [QQMusicProvider.fetchSingers]。列表按标签显示，取值按多档请求。
///
/// 注：服务端还有 `其他`(`6`, 1823 人，含儿歌 / 影视原声 / Various Artists)，
/// 语义太杂，不作为筛选项暴露。
const List<(String, List<int>)> kSingerAreas = [
  ('全部', [kSingerAll]),
  ('华语', [200, 2]),
  ('日本', [4]),
  ('韩国', [3]),
  ('欧美', [5]),
];

/// 类型（服务端字段名叫 `sex`）筛选项。
///
/// 注意取值不与「字面直觉」对应：`0` 是男、`1` 是女、`2` 是组合，
/// `-100` 才是全部——写成 `sex: 1` 当「全部」会得到全女歌手。
const List<(String, int)> kSingerSexes = [
  ('全部', kSingerAll),
  ('男', 0),
  ('女', 1),
  ('组合', 2),
];

/// 首字母索引条上的字母序列：`#` + `A`..`Z`。
///
/// 「热门」(`index = -100`) 不在这条序列里——它不是一个字母，
/// 单独做成筛选项，见 [kSingerIndexHot]。
const List<String> kSingerLetters = [
  '#',
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

/// 首字母的「热门」取值（服务端 `index = -100`，与 [kSingerAll] 同值但语义不同）。
const int kSingerIndexHot = kSingerAll;

/// 字母 → 服务端 `index` 取值。
///
/// 实测映射：`A`=1 … `Z`=26，`#`=27（非拉丁文，实测内容是泰文等小语种名，
/// 所以 `#` 的语义是「其他字符」而不是「数字开头」）。
///
/// `#` 不是字母，不能用 `codeUnitAt` 算，必须单独判。
int singerIndexId(String letter) {
  if (letter == '#') return 27;
  final code = letter.toUpperCase().codeUnitAt(0);
  // 'A'(65) → 1，'Z'(90) → 26
  return code - 64;
}

/// 「华语」档内部成员档的地区标签，用于列表行尾的「内地 / 港台」小标签。
///
/// ## ⚠️ 不能靠遍历 [kSingerAreas] 反查
/// 华语把内地与港台**合成了一项**（`('华语', [200, 2])`），
/// [kSingerAreas] 里并没有 `[200]` 或 `[2]` 这样的单项。
/// 用「找出 id 与 areaId 相同的单项」去反查会恒为 `null`，
/// 结果是华语档下每一行都没有标签——真机装机验证时抓到的就是这个
/// （列表本身混排正确，但标签一个不显示，问题极隐蔽）。
///
/// 所以这一层单独维护，语义也清楚：它只描述「华语的组成档」。
const Map<int, String> kSingerSubAreaLabels = {
  200: '内地',
  2: '港台',
};

/// 从服务端 `singer_name` 里拆出括号内的别名 / 译名。
///
/// 新版接口**不再返回** `Fother_name`，译名被拼进了名字本体：
/// `Alan Walker (艾兰·沃克)` / `米津玄師 (よねづ けんし)` /
/// `G.E.M. 邓紫棋`（无括号，别名就是名字的一部分，拆不动也不该拆）。
///
/// 返回 `(显示名, 别名)`。拆不出别名时第二项为 `''`，
/// 且**显示名保持原样**——宁可多显示括号，也不能因为解析失败丢字。
(String, String) splitSingerName(String raw) {
  final s = raw.trim();
  if (s.length < 4) return (s, '');
  // 只认结尾处的半角 / 全角括号。写成「先取最后一个字符，再按它决定开括号」
  // 而不是两套 if，是为了让半角 / 全角只差一个字符表。
  final lastClose = s.endsWith(')') ? ')' : (s.endsWith('）') ? '）' : null);
  if (lastClose == null) return (s, '');
  final open = lastClose == ')' ? '(' : '（';
  final start = s.lastIndexOf(open);
  if (start <= 0) return (s, '');
  final inner = s.substring(start + 1, s.length - 1).trim();
  final outer = s.substring(0, start).trim();
  // 括号内容为空，或去掉括号后什么都不剩 → 不是别名，整体当名字
  if (inner.isEmpty || outer.isEmpty) return (s, '');
  return (outer, inner);
}

/// 歌手头像 URL 归一为 https。
///
/// 服务端返回的是**明文** `http://y.gtimg.cn/music/photo_new/T001R150x150M000{mid}.webp`。
/// 本 App 的 `AndroidManifest` 虽然开了 `usesCleartextTraffic="true"`，
/// 但专辑封面那条链路（见 `qqmusic_dto.dart` 的 `coverUrl`）早就统一走 https，
/// 实测同一张图 https 直连 200（webp，6.5 KB / 150×150）。
/// 没必要为歌手头像单独引入一条明文依赖——将来一旦收紧 `usesCleartextTraffic`，
/// 明文的那条会静默变成「头像全是首字母圆片」，很难查。
String normalizeSingerPic(String raw) {
  if (raw.isEmpty) return '';
  return raw.startsWith('http://') ? 'https://${raw.substring(7)}' : raw;
}

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

/// 歌手条目（新版歌手列表接口 `Music.SingerListServer/get_singer_list`）。
class SingerBrief {
  /// 歌手 mid（字符串），查他的歌要用它
  final String mid;

  /// 歌手数字 ID（服务端 `singer_id`）。
  ///
  /// ⚠️ 专辑列表接口 `AlbumListServer/GetAlbumList` 只认这个数字 ID，
  /// 不认字符串 [mid]。所以需要保留它。
  /// 部分来源（如搜索）可能不返回此字段，此时为 null。
  final int? singerId;

  /// 显示名。服务端 `singer_name` 原样保留，**不含**被拆出去的别名括号。
  final String name;

  /// 别名 / 译名。由 [splitSingerName] 从 `singer_name` 的尾部括号里拆出，
  /// 拆不出时为 `''`（如「周杰伦」「G.E.M. 邓紫棋」）。
  final String otherName;

  /// 头像 URL（服务端 `singer_pic`，形如
  /// `http://y.gtimg.cn/music/photo_new/T001R150x150M000{mid}.webp`）。
  ///
  /// ## ⚠️ 有 URL ≠ 有图：这是个 best-effort 字段
  /// 服务端**对每个歌手都会返回**这个 URL，但 CDN 上没照片的歌手会 **404**
  /// （换 `.jpg` / 300×300 一样 404，不是格式问题）。
  /// 2026-09-30 抽样实测可用率：
  ///
  /// | 档位 | 前 24 人可取到图 |
  /// | --- | --- |
  /// | 全部 / 热门 | 24 / 24 |
  /// | 韩国 | 24 / 24 |
  /// | 欧美 + 男 + 首字母 A（冷门） | **6 / 24** |
  ///
  /// 即：越冷门越容易缺图。所以 UI 侧的首字母圆片兜底**不是可选装饰**，
  /// 而是会被真实触发的分支（热门档看不出来，翻到 Z 就满屏都是）。
  final String pic;

  /// 这条记录是**从哪个 area 档位请求到的**（[kSingerAll] 表示请求时未限定地区）。
  ///
  /// ⚠️ 这是**请求侧信息**，不是服务端逐条返回的字段——新版接口每条只给
  /// `country` / `singer_id` / `singer_mid` / `singer_name` / `singer_pic`。
  /// 存它是为了让「华语」档的列表能标出每条是内地还是港台
  /// （见 [kSingerAreas] 的双档合并说明）。
  final int areaId;

  const SingerBrief({
    required this.mid,
    this.singerId,
    required this.name,
    this.otherName = '',
    this.pic = '',
    this.areaId = kSingerAll,
  });
}

/// 歌手列表的一页（可能是多档合并后的一页，见 [QQMusicProvider.fetchSingers]）
class SingerPage {
  final List<SingerBrief> singers;

  /// 命中总数。多档合并时是各档 `total` 之和。
  final int total;

  final int page;

  /// 是否还有下一页。
  ///
  /// ## 为什么是存字段而不是从 `page/totalPage` 算
  /// 多档合并时「总页数」这个量没有良定义：内地 43 页、港台 20 页，
  /// 合并流在第 21 页之后只剩内地还在产出。用 `total / 每页数` 去反推
  /// 会**把内地尾部截掉**。所以由 Provider 逐档判断「任一档还有下一页」
  /// 直接给出结论，UI 只消费这个布尔值。
  final bool hasMore;

  const SingerPage({
    required this.singers,
    this.total = 0,
    this.page = 1,
    this.hasMore = false,
  });
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

/// 专辑条目（歌手专辑列表 / 搜索专辑结果共用）
class AlbumBrief {
  /// 专辑 mid，查歌曲要用
  final String mid;

  final String name;

  /// 封面 URL（300×300）
  final String cover;

  /// 歌手名（专辑列表接口里给了歌手，不必到 UI 层再拼）
  final String singerName;

  /// 发行日期，如 "2024-06-01"
  final String releaseDate;

  /// 专辑里歌曲总数
  final int totalNum;

  const AlbumBrief({
    required this.mid,
    required this.name,
    this.cover = '',
    this.singerName = '',
    this.releaseDate = '',
    this.totalNum = 0,
  });

  /// 按发行日期倒序排序（新 → 旧）。日期格式 "YYYY-MM-DD" 可以直接字符串比较。
  static List<AlbumBrief> sortByDateDesc(List<AlbumBrief> list) {
    final sorted = List<AlbumBrief>.from(list);
    sorted.sort((a, b) => b.releaseDate.compareTo(a.releaseDate));
    return sorted;
  }
}

/// 专辑详情（可播放：歌曲都带真实 mid）
class AlbumDetail {
  final String mid;
  final String title;
  final String cover;
  final String singerName;
  final String releaseDate;
  final List<QQSongMeta> songs;

  const AlbumDetail({
    required this.mid,
    required this.title,
    this.cover = '',
    this.singerName = '',
    this.releaseDate = '',
    this.songs = const [],
  });

  bool get isEmpty => songs.isEmpty;
}
