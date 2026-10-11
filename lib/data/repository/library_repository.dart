/// 曲库 Repository —— UI 与「匹配引擎 + 数据库」之间的唯一通道。
///
/// ## 为什么要有这一层
/// UI 不该知道：匹配分几个阶段、表怎么建、`duration` 是秒还是毫秒、
/// 什么时候该重新匹配。这些全在这里收口。UI 只说「我要这个歌单的歌」
/// 和「把这首重新匹配一下」。
///
/// ## 与 SourceResolver 的分工
/// Repository 负责**元数据 + 绑定关系**（谁配谁）；
/// 真正「拿 URL 去播」的活是播放器的 SourceResolver 干（见设计文档 8.2），
/// 这里只提供已落库的绑定信息。
library;

import 'dart:math';

import '../../models/models.dart';
import '../../services/bilibili/bili_dto.dart';
import '../../services/lyric/lrc_parser.dart';
import '../../services/lyric/lyric_translation.dart';
import '../../services/match/match_config.dart';
import '../../services/match/match_engine.dart';
import '../../services/metadata/metadata_provider.dart';
import '../../services/net/rate_limiter.dart' show mapWithConcurrency;
import '../../services/netease/netease_provider.dart';
import '../db/app_database.dart';
import '../db/dao/binding_dao.dart';
import '../db/dao/song_dao.dart' show ExcludeScope;
import '../db/dao/video_dao.dart';
import '../db/dao/play_stats_dao.dart';
import '../db/schema.dart';
import '../db/rows.dart';

/// 曲库统计（我的页面展示）
class LibraryStats {
  final int songCount;
  final int videoCount;
  final int bindingCount;
  final Map<String, int> byConfidence;

  const LibraryStats({
    required this.songCount,
    required this.videoCount,
    required this.bindingCount,
    required this.byConfidence,
  });

  int get autoCount => byConfidence['AUTO'] ?? 0;
  int get reviewCount => byConfidence['REVIEW'] ?? 0;
  int get rejectedCount => byConfidence['REJECTED'] ?? 0;
}

/// 一首歌的完整视图（元数据 + 当前音源）
class SongWithSource {
  final Song song;
  final AudioSource? source;
  final BindingRow? binding;

  const SongWithSource({
    required this.song,
    this.source,
    this.binding,
  });

  /// 数据库行 id（来自 song，非空时才能落库操作）
  ///
  /// 用 getter 而非独立字段：两个 id 并存迟早会不一致，
  /// 而 `Song.id` 已经在 `SongRow.toSong` 里填好了。
  int? get id => song.id;

  bool get playable => source != null;
}

/// 一首歌的歌词素材（原文 + 可选译文）。
///
/// 拆成 bundle 而不是让 `fetchLyric` 直接返回解析好的 [ParsedLyric]：
/// 数据层不该依赖"怎么显示"，解析归 UI 层的 AppState 管。
class LyricBundle {
  /// 原文 LRC
  final String lrc;

  /// 译文 LRC（原文轨的时间轴为准，由 `attachTranslation` 对齐）
  final String? translation;

  /// 译文来源：'qq'（官方 trans 字段）/ 'netease'（网易 tlyric）/ null（无译文）
  final String? translationSource;

  const LyricBundle({
    required this.lrc,
    this.translation,
    this.translationSource,
  });

  bool get hasTranslation =>
      translation != null && translation!.trim().isNotEmpty;
}

/// 在线搜索结果的一条预览。
///
/// ## 为什么不能直接返回 domain 的 [Song]
/// `Song` **刻意不含存储字段**（没有 `songMid` / `albumMid`），
/// 而搜索结果的唯一价值就是「可以拿它去入库」——入库必须要真实 `songMid`
/// （见 `ResolvedEntry` 的注释：丢了 mid 就派生 `local:`，歌词静默失效）。
///
/// 所以在搜索边界上就必须把 mid 一起带出来。这不是冗余字段，
/// 而是把「这条结果能否正确入库」的信息从搜索阶段一直传下去。
class OnlineSong {
  /// 领域对象（用于展示：标题 / 歌手 / 专辑 / 时长 / 封面）
  final Song song;

  /// QQ音乐真实 songMid。入库的唯一凭据。
  final String songMid;

  /// 专辑 mid，用于拼封面 URL + 专辑详情跳转
  final String albumMid;

  /// 首位歌手 mid，用于入库后播放页点击歌手名进详情
  final String singerMid;

  /// 首位歌手数字 ID（fetchSingerAlbums 必需）
  final int? singerId;

  /// 是否已经在本地曲库里了。
  ///
  /// 由 `searchOnline` 顺带用 mid 查一次库得出——否则用户点了「导入」
  /// 才发现是重复的，体验上像是失败。UI 据此把按钮变成「已在库中」。
  final bool inLibrary;

  const OnlineSong({
    required this.song,
    required this.songMid,
    this.albumMid = '',
    this.singerMid = '',
    this.singerId,
    this.inLibrary = false,
  });
}

/// 匹配结果摘要（批量匹配的进度回报）
class MatchSummary {
  final int total;
  final int autoBound;
  final int needReview;
  final int failed;
  final List<String> rejections;

  const MatchSummary({
    required this.total,
    required this.autoBound,
    required this.needReview,
    required this.failed,
    this.rejections = const [],
  });

  double get autoRate => total == 0 ? 0 : autoBound / total;
}

class LibraryRepository {
  LibraryRepository({
    required this.db,
    required this.engine,
    required this.metadata,
    this.netease,
  });

  final AppDatabase db;
  final MatchEngine engine;

  /// 元数据 Provider（搜索 / 详情 / 歌词 / 批量解析）。
  ///
  /// 当前注入的是 [QQMusicMetadataAdapter] 包装后的 QQMusicProvider；
  /// 未来换网易云 / Spotify / 本地音乐库时只换 Adapter，这里其他代码不动。
  final MetadataProvider metadata;

  /// 译文补充源。**可选**：不注入就只显示原文，功能降级但不报错。
  final NeteaseProvider? netease;

  // ── 导入：QQ音乐元数据 → 曲库 ─────────────────────────────

  /// 把一批「标题 + 歌手 + 时长」三元组解析成完整元数据并入库。
  ///
  /// 严格模式：每个关键词走 [QQMusicProvider.resolveFirstMatching]
  /// 的三重校验（标题 + 歌手 + 时长），不合格的不入库。
  /// 返回 [BatchResolveResult]，失败的项连原因一起带回。
  ///
  /// ## 去重键的取值顺序
  /// 1. **QQ音乐真实 `songMid`**（`ResolvedEntry.sourceId`）—— 首选。
  ///    歌词接口只认它，落到 `local:` 兜底会让歌词静默失效。
  /// 2. 解析结果里带回来的 `BatchQuery.refId`（调用方自带的稳定标识，如 B站 bvid）。
  /// 3. 都没有时退回 `local:title|artist`。
  ///
  /// **注意 `local:` 兜底的局限**：同名同歌手的不同版本（原版 / Live）会
  /// 撞到同一个键，后导入的覆盖先导入的。要区分版本，调用方必须提供 refId
  /// 或在 title 里带上版本标识（如「秘密 (Live)」）。
  Future<BatchResolveResult> importFromKeywords(
    List<BatchQuery> queries, {
    bool withLyricCredits = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = await metadata.resolveBatch(
      queries,
      withLyricCredits: withLyricCredits,
      onProgress: onProgress,
    );

    if (result.successes.isEmpty) return result;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = <SongRow>[];
    for (final entry in result.successes) {
      final s = entry.song;
      final ref = entry.query.refId;
      // ⚠️ 顺序不能颠倒：真实 sourceId（原 songMid）必须优先于 refId 前缀。
      // 之前这里恒走 `ref:` / `local:` 分支，QQ音乐解析出的真实 mid 被丢弃，
      // 导致 fetchLyric 里 `startsWith('local:')` 直接返回 null —— 歌词命中 0 首。
      final mid = entry.sourceId.isNotEmpty
          ? entry.sourceId
          : (ref.isNotEmpty ? 'ref:$ref' : SongRow.deriveMid(s.title, s.artist));
      rows.add(SongRow.fromSong(
        s,
        qqSongMid: mid,
        // 封面 URL 由 coverSourceId（原 albumMid）拼出，一起落库避免每次播放重新查详情
        albumMid: entry.coverSourceId,
        singerMid: '',
        now: now,
      ));
    }
    await db.songs.upsertAll(rows);
    return result;
  }

  /// 直接从已解析的 Song 列表入库（有真实 mid 的场景）
  Future<List<int>> importSongs(
    List<(Song song, String songMid, String albumMid)> items,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = items
        .map((e) => SongRow.fromSong(
              e.$1,
              qqSongMid: e.$2,
              albumMid: e.$3,
              singerMid: '',
              now: now,
            ))
        .toList();
    return db.songs.upsertAll(rows);
  }

  // ── 读取：曲库列表 ───────────────────────────────────────

  /// 曲库列表（带当前音源）。这是首页 / 音乐库的主数据源。
  Future<List<SongWithSource>> listSongs({int limit = 500, int offset = 0}) async {
    final rows = await db.songs.getAll(limit: limit, offset: offset);
    return _assemble(rows);
  }

  /// 本地曲库搜索
  Future<List<SongWithSource>> searchLocal(String keyword, {int limit = 50}) async {
    final rows = await db.songs.search(keyword, limit: limit);
    return _assemble(rows);
  }

  // ── 在线搜索（QQ音乐）─────────────────────────────────────

  /// 在线搜 QQ音乐，返回可一键导入的预览列表。
  ///
  /// ## 为什么这一层不直接落库
  /// 搜索是**只读**动作，用户看到结果后可能只挑其中两首导入。自动落库
  /// 会让「搜过什么」变成「库里有什么」——曲库被搜索污染，用户无法分辨。
  /// 所以这里只返回预览，入库由调用方显式触发（[importOnline]）。
  ///
  /// ## [withDetail] 的取舍
  /// 搜索结果里的标题会被截断、歌手顺序可能不同、时长是粗略值，
  /// 所以默认再拉一次详情补全。但详情是**每首一次请求**，20 条就是 20 次，
  /// 有风控风险。需要快速预览时可关掉，拿搜索接口的原始字段展示。
  ///
  /// ## 每首都要查一次本地库
  /// 用 `songMid` 反查是否已入库，把「是否重复」提前到展示阶段——
  /// 否则用户点导入才发现重复，观感上等同于导入失败。
  Future<List<OnlineSong>> searchOnline(
    String keyword, {
    int pageSize = 20,
    bool withDetail = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];

    final metas = await metadata.search(kw, pageSize: pageSize);
    if (metas.isEmpty) return [];

    // 详情补全 + 本地查重**并发 5** 执行。
    //
    // ## 为什么这里曾是全链路最慢的一步
    // 原实现对 20 条结果逐条 `await fetchDetail` + `await getByMid`——
    // 20 次串行 HTTP 往返（每次 ~200-500ms），用户按完回车要等 4~10 秒
    // 才看到列表。QQ 音乐接口没有 B站式「30 次/分钟」的硬限流
    // （搜索页一次会话也就 21 个请求；QQ Web 端一次页面加载的并发
    // 比这大得多），并发 5 不构成风控压力。
    //
    // 并发后总往返 ≈ 1 次搜索 + ceil(20/5) 轮详情 ≈ 5 轮，提速约 4 倍。
    // mapWithConcurrency 保证结果顺序与搜索排名一致。
    var done = 0;
    return mapWithConcurrency(metas, 5, (meta) async {
      var m = meta;
      if (withDetail) {
        try {
          final detail = await metadata.fetchDetail(m);
          if (detail != null) m = detail;
        } catch (_) {
          // 详情失败就退回搜索结果的粗略字段——不能因为一次补全失败
          // 就让整条结果消失，用户至少还能看到标题歌手。
        }
      }

      final existing =
          m.sourceId.isEmpty ? null : await db.songs.getByMid(m.sourceId);
      done++;
      onProgress?.call(done, metas.length);

      return OnlineSong(
        song: _metaToSong(m),
        songMid: m.sourceId,
        albumMid: m.coverSourceId,
        inLibrary: existing != null,
      );
    });
  }

  /// MetaSong → Song（通用 DTO → 领域模型）
  ///
  /// 之前这一步由 QQSongMeta.toSong() 完成。现在接口层统一用 MetaSong，
  /// Repository 边界做一次字段拷贝 —— 让领域模型保持纯源无关。
  Song _metaToSong(MetaSong m) => Song(
        title: m.title,
        artist: m.artistString,
        album: m.album,
        duration: m.durationSec,
        releaseDate: m.releaseDate,
        coverUrl: m.coverUrl,
        // coverSeed 是封面占位渐变索引，搜索预览场景不需要真实封面，默认 0
        coverSeed: 0,
      );

  /// 把在线搜索选中的条目入库。
  ///
  /// ## 为什么必须吃 [OnlineSong] 而不是 [Song]
  /// 入库需要真实 `songMid`；`Song` 里没有这个字段，只传 `Song` 就会
  /// 退化成 `local:` 派生 mid，歌词从此静默失效（E23 的根源）。
  /// 类型上强制带上 mid，让这个错误写不出来。
  ///
  /// 重复导入同一首不会产生两行：`qq_song_mid` 上有 UNIQUE 约束，
  /// [SongDao.upsertAll] 走的是「存在即更新」。
  Future<int> importOnline(List<OnlineSong> items) async {
    if (items.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = items
        .map((e) => SongRow.fromSong(
              e.song,
              qqSongMid: e.songMid,
              albumMid: e.albumMid,
              singerMid: e.singerMid,
              singerId: e.singerId,
              now: now,
            ))
        .toList();
    final ids = await db.songs.upsertAll(rows);
    return ids.length;
  }

  /// 浏览列表点歌即播的入库：把在线歌曲静默落库，返回**带 id** 的 Song 列表。
  ///
  /// ## 与 [importOnline] 的区别
  /// importOnline 是「导入」动作的入口：计数、报结果、驱动 UI 提示。
  /// persistOnline 是播放链路的**前置步骤**：用户点了榜单里第 5 首，
  /// 期望是「立刻开始播放」，入库只是让这首歌获得 id（收藏 / 播放统计
  /// / 按需匹配都依赖 id）——所以它必须安静、快（纯本地 SQLite upsert，
  /// 不发任何网络请求），失败也不该打断播放意图。
  ///
  /// ## 为什么返回 List<Song> 而不是只返回被点的那首
  /// 队列要能连续播放（下一首/上一首都在这份列表里），逐首入库会让
  /// 队列里的对象没有 id，播放统计就记不到正确的歌上。
  ///
  /// ## 去重
  /// 榜单/歌单里同一首歌可能出现多次（榜单聚合多版本），SQLite 的 mid
  /// 唯一键会让 upsert 返回相同 id——这里按 id 去重保序，避免队列里
  /// 出现两份相同的歌。
  Future<List<Song>> persistOnline(List<OnlineSong> items) async {
    if (items.isEmpty) return const [];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = items
        .map((e) => SongRow.fromSong(
              e.song,
              qqSongMid: e.songMid,
              albumMid: e.albumMid,
              singerMid: e.singerMid,
              singerId: e.singerId,
              now: now,
            ))
        .toList();
    final ids = await db.songs.upsertAll(rows);

    // 去重保序：同一 id 只留第一个出现的位置
    final seen = <int>{};
    final uniqueIds = <int>[];
    for (final id in ids) {
      if (id <= 0 || !seen.add(id)) continue;
      uniqueIds.add(id);
    }
    if (uniqueIds.isEmpty) return const [];

    final assembled = await _assembleByIds(uniqueIds);
    return assembled.map((e) => e.song).toList();
  }

  /// 单首歌（播放器用）
  Future<SongWithSource?> getSong(int id) async {
    final r = await db.songs.getById(id);
    if (r == null) return null;
    final list = await _assemble([r]);
    return list.isEmpty ? null : list.first;
  }

  /// 把 SongRow 列表装配成 SongWithSource 列表（带激活音源）。
  ///
  /// 抽出来是因为 `listSongs` / `searchLocal` / `getSong` 三处的
  /// 「查激活绑定 → 查视频 → 拼 AudioSource」逻辑完全一样，
  /// 分散写三遍必然会在某次改动时漏掉一处（`durationDelta` 那次就这么漏过）。
  Future<List<SongWithSource>> _assemble(List<SongRow> rows) async {
    if (rows.isEmpty) return [];

    final ids = rows.map((r) => r.id!).toList();
    final bindings = await _activeBindingsFor(ids);

    final bvids = bindings.values.map((b) => b.bvid).toSet().toList();
    final videos = await db.videos.getByBvids(bvids);
    final videoMap = {for (final v in videos) v.bvid: v};

    final out = <SongWithSource>[];
    for (final r in rows) {
      final b = bindings[r.id!];
      final v = b == null ? null : videoMap[b.bvid];
      final src = (b == null || v == null)
          ? null
          : _toAudioSource(b, v, songDurationSec: r.durationMs ~/ 1000);
      out.add(SongWithSource(
        song: r.toSong(source: src, status: _statusOf(b)),
        source: src,
        binding: b,
      ));
    }
    return out;
  }

  // ── 收藏 / 喜欢 ───────────────────────────────────────────

  /// 切换收藏状态，返回切换后是否已收藏。
  ///
  /// 返回新状态而不是 void：UI 需要立刻把它反映到红心上，
  /// 再去 [allLikedIds] 重新拉一遍全表是浪费。
  Future<bool> toggleLike(int songId) => db.liked.toggle(songId);

  /// 全部已收藏的 song_id
  Future<Set<int>> likedIds() => db.liked.allLikedIds();

  /// 收藏列表（按收藏时间倒序，最近收藏在前）
  Future<List<SongWithSource>> likedSongs({int limit = 500}) async {
    final ids = await db.liked.likedIdsByRecency(limit: limit);
    if (ids.isEmpty) return [];
    return _assemble(await songsByIdsOrdered(ids));
  }

  // ── 播放统计 ─────────────────────────────────────────────

  /// 记一次播放（流水 + 聚合，同一事务）。
  ///
  /// [playedMs] 是本次实际收听时长；未达门限时只进流水不计次数
  /// （见 `PlayStatsDao.recordPlay`）。
  Future<void> recordPlay(
    int songId, {
    required int playedMs,
    String? sourceBvid,
  }) =>
      db.plays.recordPlay(songId, playedMs: playedMs, sourceBvid: sourceBvid);

  /// 「常听」：按有效播放次数倒序的完整歌曲视图。
  ///
  /// [minCount] 默认 1，即听过至少一次就上榜。首页想要更严格可传 2/3。
  Future<List<SongWithSource>> topPlayedSongs({
    int limit = 20,
    int minCount = 1,
  }) async {
    final stats = await db.plays.topPlayed(limit: limit, minCount: minCount);
    return _assembleByIds(stats.map((s) => s.songId).toList());
  }

  /// 「最近播放」：按最后收听时间倒序（已按歌去重）。
  Future<List<SongWithSource>> recentlyPlayedSongs({int limit = 30}) async {
    final ids = await db.plays.recentlyPlayedSongIds(limit: limit);
    return _assembleByIds(ids);
  }

  /// 某首歌的播放统计（详情页展示「听了 N 次」）
  Future<PlayStat?> playStatOf(int songId) => db.plays.statOf(songId);

  /// 清除全部播放历史
  Future<void> clearPlayHistory() => db.plays.clearAll();

  // ── 每曲音量记忆（音效功能 P0）────────────────────────────

  /// 某首歌的记忆音量（没记过 = 1.0）。B站音源响度驳杂，
  /// 用户调过一次就永久记住、切歌自动恢复——见 schema.dart 的
  /// track_volume 表注释。
  Future<double> trackVolumeOf(int songId) => db.volumes.volumeOf(songId);

  /// 保存某首歌的音量记忆。调用方负责把值 clamp 在 0~1（just_audio
  /// 的 volume 有效域），DAO 如实存取。
  Future<void> saveTrackVolume(int songId, double volume) =>
      db.volumes.save(songId, volume);

  /// 一次 `IN (...)` 查回 song 行，并按 [ids] 入参顺序返回（孤儿 id 跳过）。
  ///
  /// 「常听榜」「最近播放」「收藏列表」三处共用——顺序是调用方的核心信息
  /// （时间序），查询本身无关紧要，由 Dart 侧按 [ids] 重排承载。
  Future<List<SongRow>> songsByIdsOrdered(List<int> ids) async {
    if (ids.isEmpty) return [];
    final uniqueIds = ids.toSet().toList();
    final inPlaceholders = List.filled(uniqueIds.length, '?').join(', ');
    final rows = await db.db.query(
      Tables.song,
      where: 'id IN ($inPlaceholders)',
      whereArgs: uniqueIds,
    );
    final byId = <int, SongRow>{
      for (final r in rows) r['id'] as int: SongRow.fromMap(r),
    };
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// 按给定 id 顺序组装完整视图。
  ///
  /// ## 一次 `IN (...)` 查询 + Dart 侧保序
  /// 早期版本逐个 `getById`（N+1：最近播放 30 首 = 30 次查询），
  /// 现在统一走 [songsByIdsOrdered]。
  Future<List<SongWithSource>> _assembleByIds(List<int> ids) async {
    if (ids.isEmpty) return [];
    return _assemble(await songsByIdsOrdered(ids));
  }

  // ── 歌词 ─────────────────────────────────────────────────

  /// 取一首歌的歌词（原文 LRC + 可能有的译文 LRC，均未解析）。
  ///
  /// ## 为什么要从库里反查 songMid
  /// QQ音乐的歌词接口只认 `songMid`，而领域模型 `Song` 是**刻意不带**
  /// 存储概念的（见 `rows.dart` 的注释）。所以这里按 `song.id` 回查
  /// `qq_song_mid`，把存储细节留在数据层。
  ///
  /// ## 译文来源的优先级
  /// 1. QQ 官方 `trans` 字段（时间轴与原文天然对齐，最准）
  /// 2. 网易 `tlyric`（QQ 匿名拿不到翻译时的补充源）
  ///
  /// **只有判定为非华语的歌才会去请求网易**——中文歌的译文就是它自己，
  /// 白打两次请求还会因为「译文 == 原文」被过滤掉，纯粹浪费。
  ///
  /// 返回 null 表示这首歌没有可用歌词（纯音乐、下架、未导入等），
  /// **不是错误**——调用方应静默留空而不是弹错。
  Future<LyricBundle?> fetchLyric(Song song) async {
    final id = song.id;
    // 没有 id 说明是 mock 数据，不可能有真实歌词
    if (id == null) return null;

    final row = await db.songs.getById(id);
    final mid = row?.qqSongMid ?? '';
    // local: 前缀是手动录入的派生 mid，元数据源查不到
    if (mid.isEmpty || mid.startsWith('local:')) return null;

    final result = await metadata.fetchLyric(mid);
    final lrc = result?.lrc;
    if (lrc == null || lrc.trim().isEmpty) return null;

    var trans = result?.hasTranslation == true ? result!.translation : null;
    // 步骤 7：从 MetadataProvider.sourceType 取值，而不是 runtimeType 拼字串
    // 旧写法 '${result?.runtimeType}' 会返回 'MetaLyric'（DTO 类名），
    // 新约定返回 'qq' / 'netease' 等 sourceType 标识
    var source = trans != null ? metadata.sourceType : null;

    if (trans == null && netease != null) {
      final body = parseLrc(lrc).lines.map((l) => l.text);
      if (looksNonChinese(body)) {
        final t = await netease!.fetchTranslationLrc(
          title: song.title,
          artist: song.artist,
        );
        if (t != null && t.trim().isNotEmpty) {
          trans = t;
          source = 'netease';
        }
      }
    }

    return LyricBundle(
      lrc: lrc,
      translation: trans,
      translationSource: source,
    );
  }

  // ── 匹配 ─────────────────────────────────────────────────

  /// 给单首歌跑匹配并落库（这是匹配的主入口）
  Future<MatchResult> matchOne(
    int songId, {
    void Function(String stage, String msg)? onLog,
  }) async {
    final row = await db.songs.getById(songId);
    if (row == null) {
      return const MatchResult(diagnostics: ['歌曲不存在']);
    }

    final song = row.toSong();
    // 排除已知失效的 bvid（设计文档 8.3 的自动修复）
    final failed = await db.bindings.getFailedBvids(songId);

    // P1 Uploader Bayesian Profile：带计数的已验证 UP 主
    final trustedUploaderProfile = await db.bindings.getActiveUploaderProfile();
    final trustedBvids = await db.bindings.getActiveBvids();

    final result = await engine.match(
      song,
      excludeBvids: failed,
      onLog: onLog,
      trustedUploaderProfile: trustedUploaderProfile,
      trustedBvids: trustedBvids,
    );

    if (!result.hasCandidate) return result;

    // 落库：视频行 + 候选 + 激活，全部收进**一个事务**。
    // 原来是三段独立提交（videos 逐条自动提交 / saveCandidates / activate），
    // 中途失败会出现「候选写了一半」或「激活指向不存在的候选行」；
    // 单事务保证要么整次匹配结果全部写入，要么全部不写。
    // 激活唯一性红线不变：deactivateAll 与激活写入同一事务内完成。
    final all = [result.best!, ...result.runnerUps];
    await db.db.transaction((txn) async {
      final videoDao = VideoDao(txn);
      final bindingDao = BindingDao(txn);

      for (final c in all) {
        await videoDao.upsert(_toVideoRow(c.video));
      }

      // 只激活 AUTO 的那条；非 AUTO 存为候选待人工确认
      for (final c in all) {
        await bindingDao.upsert(BindingRow.fromScored(
          songId: songId,
          scored: c,
          isActive: false,
        ));
      }

      await bindingDao.deactivateAll(songId);
      if (result.isBound) {
        await txn.update(
          Tables.binding,
          {'is_active': 1},
          where: 'song_id = ? AND bvid = ?',
          whereArgs: [songId, result.best!.video.bvid],
        );
      }
    });

    // V0.9 Golden Dataset：写匹配快照（非事务、失败静默）
    // 只记录 best + runnerUps——完整候选列表 MatchResult 不暴露，
    // 但这已经足够离线评估（margin/confidence/decision 都在）
    await db.matchSamples.insertMatchSample(
      songId: songId,
      song: song,
      result: result,
      allCandidates: all,
    );

    // V0.9 Golden Dataset 回填：匹配到正确 AUTO 候选 = 用户"隐式接受"
    if (result.isBound) {
      await db.matchSamples.markAccepted(songId, result.best!.video.bvid);
    }

    return result;
  }

  /// 播放兜底：激活该歌**已有的最高分候选**（不重新匹配）。
  ///
  /// ## 为什么需要它
  /// 匹配引擎对置信度不足的候选只存 REVIEW 不激活（`autoThreshold = 0.82`），
  /// 这是批量场景的正确姿势——自动给全库激活低置信候选会大面积播到翻唱。
  /// 但「用户点了这首歌想听」是另一个语境：B站 对新歌/冷门歌常常只有
  /// 非标准标题的投稿，最高分只到 0.81，若按 AUTO 硬卡，用户得到的是
  /// **静默失败**（点了没反应），比播一个可能不太对的版本糟糕得多。
  ///
  /// 红线不破：激活仍走 [db.bindings.activate]（唯一激活在事务内保证）；
  /// 批量匹配路径（[matchAllUnmatched]）**保持 AUTO-only 不变**。
  /// [minScore] 是底线：低于它的候选大概率根本不是这首歌，宁可不播。
  Future<bool> activateBestCandidate(int songId, {double minScore = 0.60}) async {
    final rows = await db.db.query(
      Tables.binding,
      columns: ['bvid', 'match_score'],
      where: 'song_id = ?',
      whereArgs: [songId],
      orderBy: 'match_score DESC',
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final score = (rows.first['match_score'] as num?)?.toDouble() ?? 0;
    if (score < minScore) return false;
    await db.bindings.activate(songId, rows.first['bvid'] as String);
    return true;
  }

  /// 给所有未匹配的歌批量跑匹配（设计文档 9.3 的 MatchWorker 逻辑）
  /// [onProgress] 每完成一首回调一次，UI 可显示进度。
  /// 内部有 800ms 间隔限速，**不可去掉**——B站接口密集请求会触发 -412。
  Future<MatchSummary> matchAllUnmatched({
    int limit = 50,
    void Function(int done, int total, String title)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final pending = await _unmatchedSongs(limit: limit);
    var autoBound = 0;
    var needReview = 0;
    var failed = 0;
    final rejections = <String>[];
    // 歌间抖动用随机源：整个批量任务共用一个实例即可
    final rng = Random();

    for (var i = 0; i < pending.length; i++) {
      if (shouldStop?.call() ?? false) break;
      final s = pending[i];
      try {
        final r = await matchOne(s.id!);
        if (r.isBound) {
          autoBound++;
        } else if (r.hasCandidate) {
          needReview++;
        } else {
          failed++;
          rejections.add('${s.title} - ${s.artists}：${r.diagnostics.lastOrNull ?? "无候选"}');
        }
      } catch (e) {
        failed++;
        rejections.add('${s.title} - ${s.artists}：请求异常 $e');
      }
      onProgress?.call(i + 1, pending.length, s.title);

      // 限速：设计文档 9.3 明确「delay(800) 不是可选项」——800ms 是下限红线。
      // v0.5 在下限之上加 0~600ms 随机抖动（800~1400ms），
      // 打散固定间隔的请求特征；总量仍远低于 30 次/分钟额度。
      if (i < pending.length - 1) {
        final jitterMs = 800 + rng.nextInt(601); // 800~1400
        await Future<void>.delayed(Duration(milliseconds: jitterMs));
      }
    }

    return MatchSummary(
      total: pending.length,
      autoBound: autoBound,
      needReview: needReview,
      failed: failed,
      rejections: rejections,
    );
  }

  /// 人工确认 / 改选（设计文档 6.2 的「待确认」队列操作）
  Future<void> confirmBinding({
    required int songId,
    required String bvid,
    required double score,
    bool userSelected = false,
    String? note,
  }) async {
    await db.bindings.bindManually(
      songId: songId,
      bvid: bvid,
      score: score,
      // 用户改选是调参最有价值的样本（设计文档 6.4）
      matchType: userSelected ? MatchType.userSelected : MatchType.manualBound,
      note: note,
    );
  }

  /// 待人工确认的队列
  Future<List<SongWithSource>> reviewQueue({int limit = 100}) async {
    final bindings = await db.bindings.getByConfidence(
      MatchConfidence.review,
      limit: limit,
    );
    return _hydrate(bindings);
  }

  /// 未匹配（连候选都没有）的歌。
  ///
  /// ⚠️ 判据是「**没有任何绑定记录**」，不是「没有激活音源」。
  /// 若用后者，一首 REVIEW 待确认的歌会同时出现在「待确认」和「未匹配」
  /// 两个列表里，用户会以为有两件事要做。
  ///
  /// 排除口径下推为 SQL `NOT IN` 子查询：旧写法 `getAll(limit*4)` 拉全表
  /// 再在 Dart 差集，库超过 400 首后列表开始静默漏歌（见
  /// [SongDao.getAllExcluding] 注释）。
  Future<List<SongWithSource>> unmatchedQueue({int limit = 100}) async {
    final rows = await db.songs.getAllExcluding(
      ExcludeScope.anyBinding,
      limit: limit,
    );
    return rows
        .map((r) => SongWithSource(
              song: r.toSong(status: SourceStatus.none),
            ))
        .toList();
  }

  // ── 统计 ─────────────────────────────────────────────────

  Future<LibraryStats> stats() async {
    final byConf = await db.bindings.stats();
    return LibraryStats(
      songCount: await db.songs.count(),
      videoCount: await db.videos.count(),
      bindingCount: await db.bindings.count(),
      byConfidence: byConf,
    );
  }

  // ── 内部工具 ─────────────────────────────────────────────

  /// 一次性取多首歌的激活绑定。
  ///
  /// 单条 `IN (...)` 查询（[BindingDao.getActiveFor]）。这里曾是本文件
  /// 最讽刺的一处：注释写着「避免 N+1」，实现是循环逐条 `getActive`——
  /// `listSongs(limit: 500)` 冷启动 = 500 次串行查询。
  Future<Map<int, BindingRow>> _activeBindingsFor(List<int> songIds) async {
    if (songIds.isEmpty) return {};
    return db.bindings.getActiveFor(songIds);
  }

  /// 把 BindingRow 列表补全成 SongWithSource（带歌曲与音源信息）。
  ///
  /// 歌曲行与视频行各用**一次** `IN (...)` 查回，再按入参顺序装配——
  /// 原来逐条 `getById` + `getByBvid`（100 条待确认 = 200 次查询），
  /// 与 [_activeBindingsFor] 是同一类 N+1。
  Future<List<SongWithSource>> _hydrate(List<BindingRow> bindings) async {
    if (bindings.isEmpty) return [];

    // songsByIdsOrdered 内部去重并按入参保序；这里自己维护绑定顺序。
    final rows = await songsByIdsOrdered(
      bindings.map((b) => b.songId).toList(),
    );
    final rowMap = <int, SongRow>{for (final r in rows) r.id!: r};

    final bvids = bindings.map((b) => b.bvid).toSet().toList();
    final videos = await db.videos.getByBvids(bvids);
    final videoMap = {for (final v in videos) v.bvid: v};

    final out = <SongWithSource>[];
    for (final b in bindings) {
      final row = rowMap[b.songId];
      if (row == null) continue;
      // 防御：绑定的 songId 与查出的行 id 必须一致。
      // 不一致说明数据被外部改过（如手工改库），跳过比带着错数据渲染好。
      if (row.id != b.songId) continue;
      final v = videoMap[b.bvid];
      final src = v == null
          ? null
          : _toAudioSource(b, v, songDurationSec: row.durationMs ~/ 1000);
      out.add(SongWithSource(
        song: row.toSong(source: src, status: _statusOf(b)),
        source: src,
        binding: b,
      ));
    }
    return out;
  }

  /// 没有激活绑定的歌（含从没匹配过、以及匹配失败后没绑上的）
  /// 「**没有激活音源**」的歌 —— 供批量匹配使用。
  ///
  /// ⚠️ 与 [unmatchedQueue] 判据不同：这里要求「没有**可播放**音源」，
  /// 因为 REVIEW 级候选虽然不能直接播，但也需要跑（重匹配可能升到 AUTO）。
  /// 而 [unmatchedQueue] 是给用户看的「待匹配」列表，判据是「完全没有候选」。
  ///
  /// 同样下推 SQL：旧写法 `getAll(limit*4)` 只扫前 200 首，库大了之后
  /// 批量匹配会漏掉排不进前 200 的歌（且越攒越多）。
  Future<List<SongRow>> _unmatchedSongs({int limit = 50}) async {
    return db.songs.getAllExcluding(
      ExcludeScope.activeBinding,
      limit: limit,
    );
  }

  static SourceStatus _statusOf(BindingRow? b) {
    if (b == null) return SourceStatus.none;
    return switch (b.confidence) {
      MatchConfidence.auto => SourceStatus.ok,
      MatchConfidence.review => SourceStatus.pending,
      MatchConfidence.rejected => SourceStatus.none,
    };
  }

  /// BindingRow + VideoRow → AudioSource。
  ///
  /// [songDurationSec] 是**必需的**：`durationDelta`（时长差）是人工兜底界面
  /// 最有效的辅助信息（设计文档 6.3「用户看到时长差 +2 秒基本可以确信是对的」），
  /// 而它必须由「视频时长 - 歌曲时长」算出来，不能只放视频时长。
  static AudioSource _toAudioSource(
    BindingRow b,
    VideoRow v, {
    required int songDurationSec,
  }) =>
      AudioSource(
        // 步骤 8：AudioSource 内部只持通用字段，bvid/cid 是 getter 委托
        bvid: v.sourceKey,
        cid: int.tryParse(v.sourceSubKey) ?? v.cid,
        sourceType: v.sourceType,
        sourceKey: v.sourceKey,
        sourceSubKey: v.sourceSubKey,
        qualityLabel: audioQualityLabel(v.audioQualityId ?? 0),
        qualityId: v.audioQualityId ?? 0,
        matchScore: b.matchScore,
        auto: b.confidence == MatchConfidence.auto,
        durationDelta: (v.durationMs ~/ 1000) - songDurationSec,
        uploader: v.author,
        playCount: v.playCount,
      );

  static VideoRow _toVideoRow(VideoCandidate c) => VideoRow(
        bvid: c.bvid,
        cid: c.cid,
        // 步骤 7：VideoRow 构造填通用列（VideoCandidate 仍用 B站字段，
        // 在边界做双写映射）
        sourceType: 'bilibili',
        sourceKey: c.bvid,
        sourceSubKey: c.cid > 0 ? c.cid.toString() : '',
        title: c.title,
        author: c.author,
        mid: c.mid,
        durationMs: c.durationMs,
        typename: c.typename,
        tag: c.tag.isEmpty ? null : c.tag,
        description: c.desc.isEmpty ? null : c.desc,
        playCount: c.play,
        pubdate: c.pubdate,
        fetchedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

  /// 手动兜底第一步：按关键词直接搜 B站，返回**未打分**的原始候选。
  ///
  /// 与 [matchOne] 的召回不同——不做打分、不过滤（标题黑名单等硬规则
  /// 全部不生效），选哪个交给用户判断。单次搜索一个请求，量级安全。
  ///
  /// ## 走引擎的搜索缓存而非裸调 API
  /// 用户「自动匹配 → 不满意 → 手动搜索」时，默认关键词「歌名 歌手」
  /// 与引擎 Q1 相同——共享缓存后同词直接命中，不再花 0.5s + 一次限流
  /// 额度重发请求。maxRetries 传 1：这是用户盯着转圈等结果的交互场景，
  /// 弱网下要尽快反馈失败，不能按后台批量的 3 次重试去熬。
  Future<List<VideoCandidate>> searchBiliCandidates(String keyword) =>
      engine.searchCached(keyword, durationFilter: 0, maxRetries: 1);

  /// 用详情接口修正 video 行的 cid —— playurl -400「请求错误」的自愈路径。
  ///
  /// ## 背景（2026-09-30 真机日志确诊）
  /// 搜索接口（search/type）**不返回 cid**。凡是绕过详情接口落库的视频行
  /// （手动搜索绑定、Stage3 详情全部失败后的兜底激活）cid 都是 0，
  /// playurl 拿 cid=0 请求恒返回 -400「请求错误」——表现为
  /// 「匹配到了音源，一播就报请求错误」，且对该 bvid 永远复现。
  ///
  /// 这里花一次详情请求取真实 cid 并就地修库，救活优先于整首重匹配
  /// （详情 1 次请求 << 重匹配的 10 次上下）。
  ///
  /// 返回修正后的 cid；详情不可达 / 视频已失效返回 null。
  /// 自愈是尽力而为：任何异常都吞掉返回 null，让调用方走原有失败文案。
  Future<int?> refreshSourceCid(String sourceKey) async {
    try {
      final detail = await engine.sourceProvider.fetchSourceDetail(sourceKey);
      final subKey = detail?.sourceSubKey ?? '';
      final cid = int.tryParse(subKey) ?? 0;
      if (cid <= 0) return null;
      await db.videos.updateCid(sourceKey, cid);
      return cid;
    } catch (_) {
      return null;
    }
  }

  /// 手动兜底第二步：把用户亲自挑中的视频绑定为该歌的音源。
  ///
  /// ## 顺序不能反：必须先落视频行再写绑定
  /// 绑定激活后 [SourceResolver] / [getSong] 都要从 video 表读元数据来
  /// 拼 AudioSource。手动搜来的视频是新的，若先激活后落库，
  /// 「选完还是暂无可用音源」。
  ///
  /// ## ⚠️ cid=0 的候选必须先补详情（2026-09-30 新增）
  /// 搜索接口不返回 cid，手动搜来的候选 cid 恒为 0；直接落库会让
  /// playurl 恒 -400「请求错误」——这正是真机日志里《千里之外》
  /// 《Lies》等歌「匹配到了但播不了」的根因。绑定前补一次详情拿真实 cid。
  Future<void> bindManualVideo({
    required int songId,
    required VideoCandidate video,
    String? note,
  }) async {
    var v = video;
    if (v.cid <= 0) {
      try {
        final d = await engine.sourceProvider.fetchSourceDetail(v.bvid);
        if (d != null) {
          v = v.copyWith(
            cid: int.tryParse(d.sourceSubKey) ?? 0,
            durationSec: d.durationSec,
            title: d.title,
            author: d.uploaderName,
            typename: d.category,
          );
        }
      } catch (_) {
        // 详情补全失败保持原样落库：resolve 的 -400 自愈还能兜底。
        // 这里不抛——用户刚亲手选完，绑定失败比绑一个待自愈的源更伤体验。
      }
    }
    await db.videos.upsert(_toVideoRow(v));
    // 置信度记 AUTO、matchType 记 USER_SELECTED：用户亲选即最高置信，
    // 同时保留调参最有价值的样本类型（设计文档 6.4）。
    await db.bindings.bindManually(
      songId: songId,
      bvid: video.bvid,
      score: 1.0,
      matchType: MatchType.userSelected,
      note: note ?? '手动搜索指定',
    );
    // Golden Dataset 反馈：手动搜索指定是对此前匹配快照的最终裁决——
    // 覆盖 AUTO 绑定时的隐式接受（chosen ≠ best → 负样本）。
    // 无快照时 DAO 静默无操作；失败也不影响绑定主流程。
    await db.matchSamples.markUserChoice(songId, video.bvid);
  }
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
