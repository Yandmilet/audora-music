/// 「猜你想听」的推荐链路测试（不联网）。
///
/// ## 为什么值得单独钉住
/// QQ 音乐所有**个性化推荐**接口匿名一律风控（`code=500003`，2026-10-11
/// 实测 11 个 module/method 组合），所以「猜你想听」是我们自己按听歌偏好
/// 组合出来的，不是服务端给的。既然是自己拼的，就有三件事必须锁住：
///   1. **口味从哪来**：常听 2 票 / 收藏 1 票，取前两位歌手；
///   2. **拉不到东西时不许装成功**：不能默默起播半批、更不能塞假数据；
///   3. **别把刚听过的又推一遍**：最近听过的前 8 首要被滤掉。
///
/// 用真实 [QQMusicProvider] 的子类做假实现（它的目录方法都可覆写），
/// 于是能验证「只依赖匿名可用的那两个接口」这一前提本身。
library;

import 'dart:async';

import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/qqmusic/qqmusic_catalog_dto.dart';
import 'package:audora_music/services/qqmusic/qqmusic_dto.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/state/guess_for_you.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录调用的假 QQ 目录接口。命中 [singerSongs] / [toplists] 给数据，
/// 对应的 *Error 非空时抛异常，用来验证「单来源失败不拖垮整批」。
class _FakeQQ extends QQMusicProvider {
  _FakeQQ({
    this.singerSongs = const {},
    this.toplists = const {},
    this.singerError,
    this.toplistError,
  });

  final Map<String, List<QQSongMeta>> singerSongs;
  final Map<int, List<QQSongMeta>> toplists;
  final Object? singerError;
  final Object? toplistError;

  final List<String> singerCalls = [];
  final List<int> topIdCalls = [];
  int limitSeen = 0;

  @override
  Future<List<QQSongMeta>> fetchSingerSongs(
    String singerMid, {
    int limit = 100,
  }) async {
    singerCalls.add(singerMid);
    if (singerError != null) throw singerError!;
    limitSeen = limit;
    return singerSongs[singerMid]!.take(limit).toList();
  }

  @override
  Future<ToplistDetail> fetchToplistDetail(int topId, {int limit = 100}) async {
    topIdCalls.add(topId);
    if (toplistError != null) throw toplistError!;
    return ToplistDetail(
      topId: topId,
      title: '榜$topId',
      songs: (toplists[topId] ?? const []).take(limit).toList(),
    );
  }
}

QQSongMeta _m(String mid, String title, String artist) => QQSongMeta(
      songMid: mid,
      title: title,
      artists: [artist],
      singerMid: 'S_$artist',
      interval: 200,
    );

/// 榜单一批发 N 首同歌手的歌（mid 递增保证 key 不撞）。
List<QQSongMeta> _many(String prefix, int n, [String artist = '某人']) =>
    [for (var i = 0; i < n; i++) _m('$prefix$i', '$prefix$i', artist)];

Song _s(String title, String artist, {String? singerMid}) => Song(
      title: title,
      artist: artist,
      duration: 200,
      coverSeed: 1,
      singerMid: singerMid ?? 'S_$artist',
    );

/// 被测盒子 + 一个记录起播入参的槽位。
class _Harness {
  _Harness({
    required QQMusicProvider? qq,
    List<Song> top = const [],
    List<Song> liked = const [],
    List<Song> recent = const [],
    bool playResult = true,
  }) {
    box = GuessForYouBox(
      catalog: () => qq,
      topPlayed: () => top,
      liked: () => liked,
      recentlyPlayed: () => recent,
      play: (items, index) async {
        played.add(items);
        playedIndex = index;
        return playResult;
      },
      onChange: () {},
    );
  }

  late final GuessForYouBox box;
  final List<List<OnlineSong>> played = [];
  int playedIndex = -1;

  /// 最近一次起播的曲目 key 集合。
  Set<String> get playedKeys =>
      played.last.map((e) => e.song.key).toSet();
}

void main() {
  group('口味种子', () {
    test('常听权重高于收藏：只有收藏时也能出种子；两者都有时常听歌手优先',
        () async {
      final qq = _FakeQQ(
        singerSongs: {
          'S_A': _many('a', 3, 'A'),
          'S_B': _many('b', 3, 'B'),
        },
      );
      final h = _Harness(
        qq: qq,
        // A 出现两次（常听+收藏）→ 3 票；B 只在收藏 → 1 票
        top: [_s('x', 'A')],
        liked: [_s('y', 'A'), _s('z', 'B')],
      );

      await h.box.run();

      expect(qq.singerCalls, containsAllInOrder(['S_A', 'S_B']));
      expect(qq.singerCalls.first, 'S_A',
          reason: '得票高的歌手必须排第一，否则口味等于没有');
      expect(qq.limitSeen, 12,
          reason: '只要热门前 12 首；按默认 100 首拉是白烧流量');
    });

    test('最多只请求两位歌手（每个来源都是一次远端往返，不能贪多）',
        () async {
      final qq = _FakeQQ(
        singerSongs: {
          for (final a in ['A', 'B', 'C', 'D']) 'S_$a': _many(a, 2, a),
        },
      );
      final h = _Harness(
        qq: qq,
        top: [_s('1', 'A'), _s('2', 'B'), _s('3', 'C'), _s('4', 'D')],
      );
      await h.box.run();
      expect(qq.singerCalls, hasLength(2));
    });

    test('没有 singerMid 的旧数据被滤掉，不发无效请求', () async {
      final qq = _FakeQQ(singerSongs: {'S_B': _many('b', 2, 'B')});
      final h = _Harness(
        qq: qq,
        top: [_s('老数据', 'A', singerMid: '')],
        liked: [_s('新数据', 'B')],
      );
      await h.box.run();
      expect(qq.singerCalls, isNot(contains('S_')));
      expect(qq.singerCalls, contains('S_B'));
    });
  });

  group('来源组合与过滤', () {
    test('榜单是兜底池：没有任何口味时，只靠榜单也能组出一批', () async {
      final qq = _FakeQQ(toplists: {
        kHotToplistId: _many('hot', 5),
        kNewToplistId: _many('new', 4),
      });
      final h = _Harness(qq: qq);

      final err = await h.box.run();

      expect(err, isNull);
      expect(qq.singerCalls, isEmpty, reason: '没口味种子就不该请求歌手接口');
      expect(qq.topIdCalls, containsAll([kHotToplistId, kNewToplistId]));
      expect(h.playedKeys, hasLength(9));
    });

    test('跨来源按 title|artist 去重，队列里不会出现两份同一首歌', () async {
      // 同一首歌以不同 songMid 出现两次（榜单聚合多版本的真实形态）
      final qq = _FakeQQ(
        singerSongs: {
          'S_A': [_m('mid1', '晴天', 'A'), _m('mid2', '搁浅', 'A')],
        },
        toplists: {
          kHotToplistId: [_m('other-mid', '晴天', 'A')],
          kNewToplistId: const [],
        },
      );
      final h = _Harness(qq: qq, top: [_s('x', 'A')]);

      await h.box.run();

      expect(h.played.last, hasLength(2));
      expect(h.playedKeys, containsAll({'晴天|A', '搁浅|A'}));
    });

    test('最近听过的前 8 首不再推', () async {
      final qq = _FakeQQ(
        singerSongs: {
          'S_A': [_m('1', '刚听过', 'A'), _m('2', '没听过', 'A')],
        },
      );
      final h = _Harness(
        qq: qq,
        top: [_s('x', 'A')],
        recent: [_s('刚听过', 'A')],
      );

      await h.box.run();

      expect(h.playedKeys, isNot(contains('刚听过|A')));
      expect(h.playedKeys, contains('没听过|A'));
    });

    test('超出目标条数会被截断（各来源加起来 38 首也只起播 30 首）', () async {
      final qq = _FakeQQ(
        singerSongs: {'S_A': _many('a', 10, 'A'), 'S_B': _many('b', 10, 'B')},
        toplists: {
          kHotToplistId: _many('h', 100),
          kNewToplistId: _many('n', 100),
        },
      );
      final h = _Harness(qq: qq, top: [_s('1', 'A'), _s('2', 'B')]);
      await h.box.run();
      // 8 + 8（两位歌手）+ 12 + 10（两个榜）= 38 → 截到 30
      expect(h.played.last.length, GuessForYouBox.targetSongs);
    });
  });

  group('失败必须如实', () {
    test('数据层未接入（qq == null）→ 一句文案，不发请求不起播', () async {
      final h = _Harness(qq: null);
      expect(await h.box.run(), '数据层未接入');
      expect(h.played, isEmpty);
    });

    test('热歌榜单独挂了，其余来源照常凑出一批', () async {
      final inner = _FakeQQ(
        singerSongs: {'S_A': _many('a', 3, 'A')},
        toplists: {kNewToplistId: _many('n', 2)},
      );
      final h = _Harness(qq: _OnlyHotBroken(inner), top: [_s('x', 'A')]);

      final err = await h.box.run();

      expect(err, isNull);
      expect(inner.singerCalls, contains('S_A'));
      // 3 首歌手热歌 + 2 首新歌榜，热歌榜的 8 个名额空着但不影响整批
      expect(h.played.last, hasLength(5));
    });

    test('所有来源都失败 → 返回文案且绝不起播（不端一盘假歌）', () async {
      final qq = _FakeQQ(
        singerError: Exception('风控'),
        toplistError: Exception('断网'),
      );
      final h = _Harness(qq: qq, top: [_s('x', 'A')]);

      final err = await h.box.run();

      expect(err, isNotNull);
      expect(h.played, isEmpty);
    });

    test('入库起播返回 false → 也要报错，不能转完圈什么都没有', () async {
      final qq = _FakeQQ(toplists: {kHotToplistId: _many('h', 3)});
      final h = _Harness(qq: qq, playResult: false);

      final err = await h.box.run();

      expect(err, '推荐没能入库播放，请重试');
      expect(h.played, hasLength(1), reason: '确实试过了，只是没成功');
    });
  });

  group('重入与状态', () {
    test('busy 期间第二次点击直接吞掉，不重复发请求', () async {
      final gate = _Gate();
      final qq = _BlockingQQ(gate);
      final h = _Harness(qq: qq);

      final first = h.box.run();
      await gate.entered;
      expect(h.box.busy, isTrue);

      // 连点：第二次既不发请求也不报错
      expect(await h.box.run(), isNull);
      expect(qq.calls, 1);

      gate.release.complete();
      await first;
      expect(h.box.busy, isFalse);
    });
  });
}

/// 只让热歌榜失败的另一半假实现。
class _OnlyHotBroken extends QQMusicProvider {
  _OnlyHotBroken(this.inner);

  final _FakeQQ inner;

  @override
  Future<List<QQSongMeta>> fetchSingerSongs(
    String singerMid, {
    int limit = 100,
  }) =>
      inner.fetchSingerSongs(singerMid, limit: limit);

  @override
  Future<ToplistDetail> fetchToplistDetail(int topId, {int limit = 100}) {
    if (topId == kHotToplistId) return Future.error(Exception('热歌榜挂了'));
    return inner.fetchToplistDetail(topId, limit: limit);
  }
}

/// 手动放行的门：用来把 run() 卡在「第一个请求已在途」的位置上。
class _Gate {
  final Completer<void> _in = Completer<void>();
  final Completer<void> _out = Completer<void>();
  Future<void> get entered => _in.future;
  Completer<void> get release => _out;
  void arrive() {
    if (!_in.isCompleted) _in.complete();
  }
}

class _BlockingQQ extends QQMusicProvider {
  _BlockingQQ(this.gate);

  final _Gate gate;
  int calls = 0;

  @override
  Future<List<QQSongMeta>> fetchSingerSongs(
    String singerMid, {
    int limit = 100,
  }) async {
    calls++;
    gate.arrive();
    await gate.release.future;
    return const [];
  }

  @override
  Future<ToplistDetail> fetchToplistDetail(int topId, {int limit = 100}) async {
    calls++;
    gate.arrive();
    await gate.release.future;
    return ToplistDetail(topId: topId, title: '', songs: const []);
  }
}
