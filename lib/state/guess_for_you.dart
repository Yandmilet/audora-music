/// 「猜你想听」——按本机听歌偏好，用 QQ音乐**匿名可用**的接口现场组一批歌。
///
/// ## 为什么不是 QQ 的个性化推荐接口
/// 2026-10-11 实测：QQ 音乐所有推荐类 module（`music.personRec.*`、
/// `musicTsRecommend.*`、`MUSIC.IndexTop.RecommendService`、
/// `music.rec.*`、`music.musichallPlaylist.PlayListCgi`、
/// `music.radio.UfoRadio` 等 11 个 module/method 组合）匿名请求一律
/// `code=500003 / subcode=860100001·860100005`（风控）。真正的「千人千面」
/// 要 QQ 登录态，而本应用只有 B站扫码登录，没有 QQ 账号体系。
///
/// 所以推荐算法放在这一层，**数据源仍然全是 QQ 音乐**，只用验证过可匿名
/// 访问的两类接口：
///   1. `music.web_singer_info_svr / get_singer_detail_info`（歌手热歌，
///      按热度降序）—— 负责「像你的口味」
///   2. `musicToplist.ToplistInfoServer / GetDetail`（热歌榜 / 新歌榜）
///      —— 负责「掺一点新的、别总是那几首」
///
/// ## 数据纪律
/// 与首页目录浏览同一条红线：没有 mock 兜底。单个来源失败就跳过它，
/// 所有来源都失败（多半是没网）就如实返回一句文案，不端一盘假歌给用户。
///
/// ## 为什么从 AppState 拆出来（组合式拆分，**不是** part 文件）
/// 自洽叶子模块：只依赖 catalog（远端）、三份口味列表（只读）和一个起播
/// 回调，不碰播放/曲库核心。AppState 保留同名转发。
library;

import 'dart:math';

import '../data/repository/library_repository.dart';
import '../models/models.dart';
import '../services/qqmusic/qqmusic_dto.dart';
import '../services/qqmusic/qqmusic_provider.dart';

/// QQ 榜单 topId（实测取自 `ToplistInfoServer/GetAll` 的「巅峰榜」分组）。
const int kHotToplistId = 26; // 热歌榜
const int kNewToplistId = 27; // 新歌榜

/// 口味种子（一位歌手 + 得票数）。
typedef TasteSeed = ({String singerMid, String name, int votes});

class GuessForYouBox {
  GuessForYouBox({
    required QQMusicProvider? Function() catalog,
    required List<Song> Function() topPlayed,
    required List<Song> Function() liked,
    required List<Song> Function() recentlyPlayed,
    required Future<bool> Function(List<OnlineSong> items, int index) play,
    required void Function() onChange,
    Random? rng,
  })  : _catalog = catalog,
        _topPlayed = topPlayed,
        _liked = liked,
        _recentlyPlayed = recentlyPlayed,
        _play = play,
        _onChange = onChange,
        _rng = rng ?? Random();

  final QQMusicProvider? Function() _catalog;
  final List<Song> Function() _topPlayed;
  final List<Song> Function() _liked;
  final List<Song> Function() _recentlyPlayed;
  final Future<bool> Function(List<OnlineSong>, int) _play;
  final void Function() _onChange;
  final Random _rng;

  /// 正在拉推荐（首页卡片据此转圈并吞掉重复点击）。
  bool _busy = false;

  bool get busy => _busy;

  /// 目标条数。一屏多一点：够连着切十几首，又不至于让首次点击等太久——
  /// 每个来源都是一次远端往返，串行拉 4 个来源已经接近 2 秒。
  static const int targetSongs = 30;

  /// 跑一次推荐并起播。
  ///
  /// 返回 `null` 表示已经交给播放链路；返回文案表示失败原因，由 UI 呈现。
  /// 重入（连点两次）直接返回 null 静默吞掉——卡片此刻正在转圈，
  /// 再给一句「正在加载」的提示只会显得聒噪。
  Future<String?> run() async {
    if (_busy) return null;
    final qq = _catalog();
    if (qq == null) return '数据层未接入';

    _busy = true;
    _onChange();
    try {
      final items = await _collect(qq);
      if (items.isEmpty) return '没拉到推荐，检查网络后再试一次';
      // play 返回 false = 一条都没能入库（数据层没接 / 入库全失败）。
      // 这时候不能装作成功，否则卡片转完圈什么都没有，像坏了。
      if (!await _play(items, 0)) return '推荐没能入库播放，请重试';
      return null;
    } finally {
      _busy = false;
      _onChange();
    }
  }

  /// 汇总各来源 → 去重 → 打散 → 截断。
  Future<List<OnlineSong>> _collect(QQMusicProvider qq) async {
    // key = `title|artist`。用库内同款唯一键去重，而不是 songMid：
    // 榜单与歌手页对同一首歌给的 mid 偶有差异（不同版本条目），
    // 用户看到的是「怎么又是这首歌」，按 key 去重才对得上体感。
    final pool = <String, OnlineSong>{};
    final stale = _staleKeys();

    // ① 口味主池：得票最高的两位歌手的热歌。
    //    取 2 位而不是 5 位——5 个串行请求会让卡片转三四秒。
    for (final seed in _tasteSeeds().take(2)) {
      await _absorb(
        pool,
        stale,
        () => qq.fetchSingerSongs(seed.singerMid, limit: 12),
        8,
      );
    }

    // ② 掺新：热歌榜 + 新歌榜各取若干，保证不完全是老歌单的回声。
    //    量给得比歌手池大，是因为完全没有口味的新用户只剩这两个来源——
    //    各取 6 条的话「猜你想听」只有 12 首，切两下就到底了。
    await _absorb(
      pool,
      stale,
      () async => (await qq.fetchToplistDetail(kHotToplistId, limit: 30)).songs,
      12,
    );
    await _absorb(
      pool,
      stale,
      () async => (await qq.fetchToplistDetail(kNewToplistId, limit: 30)).songs,
      10,
    );

    final list = pool.values.toList()..shuffle(_rng);
    return list.take(targetSongs).toList();
  }

  /// 拉一个来源并塞进 [pool]，最多塞 [take] 条。
  ///
  /// 单个来源失败**不往上抛**：推荐是「尽力凑一批」，热歌榜挂了不影响
  /// 歌手热歌。真正全军覆没时 pool 为空，由 [run] 给出那一句文案。
  Future<void> _absorb(
    Map<String, OnlineSong> pool,
    Set<String> stale,
    Future<List<QQSongMeta>> Function() load,
    int take,
  ) async {
    final before = pool.length;
    try {
      final metas = await load();
      for (final m in metas) {
        if (pool.length - before >= take) break;
        final item = _asOnline(m);
        if (item.song.key.isEmpty || stale.contains(item.song.key)) continue;
        pool.putIfAbsent(item.song.key, () => item);
      }
    } catch (_) {
      // 见上：静默跳过，让下一个来源继续补
    }
  }

  /// QQ 目录 DTO → 可入库播放的 [OnlineSong]。
  ///
  /// `songMid` 是入库唯一凭据，漏传会派生出 `local:` 前缀、歌词静默失效
  /// （与 browse_screen 的 asOnlineSong 同一陷阱，字段必须带全）。
  OnlineSong _asOnline(QQSongMeta m) => OnlineSong(
        song: m.toSong(),
        songMid: m.songMid,
        albumMid: m.albumMid,
        singerMid: m.singerMid,
        singerId: m.singerId,
      );

  /// 最近听过的前 8 首不再推。「猜你想听」不是「重播刚才」。
  Set<String> _staleKeys() =>
      _recentlyPlayed().take(8).map((s) => s.key).toSet();

  /// 口味种子：常听计 2 票、收藏计 1 票，按得票降序。
  ///
  /// 常听权重更高是刻意的——收藏里躺着十几首「当时觉得不错再没听过」的
  /// 歌，常听才是当下真实的口味。两者都取，谁也没被排除。
  ///
  /// 只认带 `singerMid` 的歌：旧数据里可能有 mid 为空的行，那种歌手没法
  /// 发请求，留着只会在 _absorb 里静默失败，不如这里就滤掉。
  List<TasteSeed> _tasteSeeds() {
    final votes = <String, TasteSeed>{};

    void tally(List<Song> songs, int weight) {
      for (final s in songs) {
        final mid = s.singerMid;
        if (mid == null || mid.isEmpty || s.artist.isEmpty) continue;
        final cur = votes[mid];
        votes[mid] = (
          singerMid: mid,
          name: cur?.name ?? s.artist,
          votes: (cur?.votes ?? 0) + weight,
        );
      }
    }

    tally(_topPlayed(), 2);
    tally(_liked(), 1);

    final list = votes.values.toList()
      ..sort((a, b) => b.votes.compareTo(a.votes));
    return list;
  }
}
