/// SourceResolver 单测：缓存、拉流、失效判定。
///
/// ## 为什么这个测试值得写
/// 「URL 过期」是音乐播放器最难查的一类 bug：
///   - 表现是「播到一半突然停」，用户以为网络问题
///   - URL 有效期 120 分钟，手动测一次要等两小时
///   - 缓存判据写错（比如漏了 `expireAt` 比较）平时也看不出问题
///
/// 这里用**真实的内存 SQLite + 真实 VideoDao**（不是 mock），
/// 只把「拉流」这一步换成可控的假函数，于是能精确构造
/// 「URL 还差 100 秒过期」这种边界，验证刷新时机是否正确。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/bilibili/bili_exception.dart';
import 'package:audora_music/services/playback/source_resolver.dart';
import 'package:audora_music/services/source/audio_source_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  // ⚠️ 必须在任何 openDatabase 之前设置 factory。
  // sqflite 在测试环境没有原生实现，不设会报
  // `databaseFactory is only initialized when using sqflite`。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late SourceResolver resolver;

  /// 记录假拉流函数被调用的次数，用于验证「有没有走缓存」
  late int fetchCalls;

  /// 假拉流函数返回的值；设成 null 模拟「接口正常但无音频流」
  AudioSourceInfo? nextStream;

  /// 如果要让假函数抛异常，设在这里
  Object? nextError;

  /// 记录最后一次拉流时透传下来的音质上限（验证偏好真的传到了 fetcher）
  int lastCeiling = -1;

  setUp(() async {
    // ⚠️ 不能用 inMemoryDatabasePath：在 sqflite_common_ffi 下它等价于
    // file::memory:?cache=shared，同一进程内所有测试共享同一个库，
    // 上一个测试的数据会串进来（此前踩过这个坑）。
    final seq = _dbSeq++;
    db = await AppDatabase.open(path: 'file:resolver$seq?mode=memory&cache=shared');
    fetchCalls = 0;
    nextStream = null;
    nextError = null;
    lastCeiling = -1;

    resolver = SourceResolver(
      videos: db.videos,
      // 注：这里传的是 lambda 而不是 BiliApi 的方法引用，
      // 因为 AudioStreamFetcher 是普通函数类型，签名天然兼容
      api: (sourceKey, sourceSubKey, {qualityCeiling = 0}) async {
        fetchCalls++;
        lastCeiling = qualityCeiling;
        if (nextError != null) throw nextError!;
        return nextStream;
      },
      sourceHeaders: const {},
      // repo 传 null：本组测试只覆盖「拉流 + 缓存」，
      // 需要验证自动重匹配的用例单独构造带 repo 的实例
      repo: null,
    );
  });

  tearDown(() async => db.close());

  /// 造一首有音源的歌
  Song songWith({String bvid = 'BV1test', int cid = 100}) => Song(
        id: 1,
        title: '秘密',
        artist: '白浩寅',
        duration: 226,
        coverSeed: 3,
        sourceStatus: SourceStatus.ok,
        source: AudioSource(
          bvid: bvid,
          cid: cid,
          qualityLabel: '192Kbps',
          qualityId: 30280,
          matchScore: 0.95,
          auto: true,
          durationDelta: 2,
          uploader: 'UP',
        ),
      );

  /// 往库里写一行视频记录（可选带有效的缓存 URL）
  Future<void> seedVideo({
    String bvid = 'BV1test',
    int cid = 100,
    String? url,
    int? expireAt,
    int qualityId = 30280,
    int bitrate = 262779,
  }) async {
    await db.videos.upsert(VideoRow(
      bvid: bvid,
      cid: cid,
      title: '秘密',
      author: 'UP',
      durationMs: 228000,
      fetchedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      audioUrl: url,
      audioUrlExpireAt: expireAt,
      audioQualityId: url == null ? null : qualityId,
      audioBitrate: url == null ? null : bitrate,
    ));
  }

  int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  group('缓存命中', () {
    test('有效缓存直接返回，不发网络请求', () async {
      await seedVideo(url: 'https://cdn/cached.m4s', expireAt: nowSec() + 3600);

      final r = await resolver.resolve(songWith());

      expect(r.ok, isTrue);
      expect(r.url, 'https://cdn/cached.m4s');
      expect(r.fromCache, isTrue);
      expect(r.qualityId, 30280);
      expect(fetchCalls, 0, reason: '命中缓存不该发请求');
    });

    test('URL 已过期 → 重新拉流', () async {
      // 已经过期 1 秒
      await seedVideo(url: 'https://cdn/stale.m4s', expireAt: nowSec() - 1);
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/fresh.m4s',
        bandwidth: 262779,
      );

      final r = await resolver.resolve(songWith());

      expect(r.url, 'https://cdn/fresh.m4s');
      expect(r.fromCache, isFalse);
      expect(fetchCalls, 1);
    });

    test('URL 只剩 100 秒 → 视为无效并刷新（5 分钟安全边际生效）', () async {
      // VideoRow.isAudioUrlValid 要求 now < expireAt - 300，
      // 因此剩余不足 300 秒的 URL 会被判为「即将过期」而提前刷新。
      // 这条边界很关键：若不刷新，用户很可能在缓冲过程中就过期了。
      await seedVideo(url: 'https://cdn/almost.m4s', expireAt: nowSec() + 100);
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/fresh.m4s',
        bandwidth: 262779,
      );

      final r = await resolver.resolve(songWith());

      expect(r.fromCache, isFalse);
      expect(fetchCalls, 1);
    });

    test('forceRefresh 跳过缓存', () async {
      await seedVideo(url: 'https://cdn/cached.m4s', expireAt: nowSec() + 3600);
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/forced.m4s',
        bandwidth: 262779,
      );

      final r = await resolver.resolve(songWith(), forceRefresh: true);

      expect(r.url, 'https://cdn/forced.m4s');
      expect(fetchCalls, 1);
    });

    test('cid 不匹配时不吃缓存（分P可能变了）', () async {
      // 库里存的是 cid=100 的 URL，但歌现在指向 cid=200
      await seedVideo(bvid: 'BV1test', cid: 100, url: 'https://cdn/p1.m4s',
          expireAt: nowSec() + 3600);
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/p2.m4s',
        bandwidth: 262779,
      );

      final r = await resolver.resolve(songWith(cid: 200));

      expect(r.url, 'https://cdn/p2.m4s');
      expect(fetchCalls, 1);
    });
  });

  group('拉流成功写库', () {
    test('拉流后 URL 与过期时间落库，下次直接命中缓存', () async {
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/net.m4s',
        bandwidth: 262779,
      );

      final r1 = await resolver.resolve(songWith());
      expect(r1.fromCache, isFalse);
      expect(fetchCalls, 1);

      // 第二次：应命中缓存，不再发请求
      final r2 = await resolver.resolve(songWith());
      expect(r2.fromCache, isTrue);
      expect(r2.url, 'https://cdn/net.m4s');
      expect(fetchCalls, 1, reason: '第二次不该再发请求');

      // 顺手验证库里确实写进去了
      final row = await db.videos.getByBvid('BV1test');
      expect(row!.audioUrl, 'https://cdn/net.m4s');
      expect(row.audioUrlExpireAt, greaterThan(nowSec()));
      expect(row.available, isTrue);
    });

    test('库中原本没有该 bvid 的行时，补插一条并缓存 URL', () async {
      // ★ 这是一个真实修掉的缺陷回归测试。
      //
      // 原先 `updateAudioStream` 只有 UPDATE，行不存在时影响 0 行且不报错，
      // 于是 URL 永远写不进库 → 每次播放都要重新拉流（慢，且白耗限流配额）。
      // 修法：UPDATE 影响 0 行时改为 INSERT 一条最小记录。
      //
      // 正常「匹配 → 播放」路径上匹配引擎会先 upsert 视频行，所以
      // 这个问题不会暴露；但绕过匹配直接播放（或从备份恢复）就会踩到。
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/x.m4s',
        bandwidth: 1000,
      );

      final song = songWith(bvid: 'BV_not_in_db', cid: 777);
      await resolver.resolve(song);

      final row = await db.videos.getByBvid('BV_not_in_db');
      expect(row, isNotNull, reason: '行不存在时应补插');
      expect(row!.audioUrl, 'https://cdn/x.m4s');
      // cid 必须一起写对，否则下次读缓存时 cid 判定失败
      expect(row.cid, 777);
      expect(row.audioQualityId, 30280);
      expect(row.available, isTrue);

      // 再播一次应直接命中缓存
      final r2 = await resolver.resolve(song);
      expect(r2.fromCache, isTrue);
    });
  });

  group('失败路径', () {
    test('没有音源时立刻失败，不发请求', () async {
      const bare = Song(
        title: '未匹配的歌',
        artist: 'X',
        duration: 200,
        coverSeed: 1,
        sourceStatus: SourceStatus.none,
      );

      final r = await resolver.resolve(bare);

      expect(r.ok, isFalse);
      expect(r.error, contains('没有匹配到音源'));
      expect(fetchCalls, 0);
    });

    test('接口返回无音频流 → 标记 unavailable', () async {
      await seedVideo();
      nextStream = null; // 接口正常但无流

      final r = await resolver.resolve(songWith(), allowRematched: false);

      expect(r.ok, isFalse);
      expect(r.error, contains('无可用音频流'));

      final row = await db.videos.getByBvid('BV1test');
      expect(row!.available, isFalse);
      expect(row.audioUrl, isNull);
    });

    test('视频已删除（-404）→ 标记 unavailable 且带上原因', () async {
      await seedVideo();
      nextError = const BiliApiException(
        code: -404,
        message: '啥都木有',
        endpoint: '/x/player/wbi/playurl',
      );

      final r = await resolver.resolve(songWith(), allowRematched: false);

      expect(r.ok, isFalse);
      expect(r.error, contains('音源已失效'));

      final row = await db.videos.getByBvid('BV1test');
      expect(row!.available, isFalse);
      expect(row.unavailableReason, contains('-404'));
    });

    test('权限不足（-403）→ 同样标记 unavailable', () async {
      await seedVideo();
      nextError = const BiliApiException(
        code: -403,
        message: '权限不足',
        endpoint: '/x/player/wbi/playurl',
      );

      final r = await resolver.resolve(songWith(), allowRematched: false);
      expect(r.ok, isFalse);

      final row = await db.videos.getByBvid('BV1test');
      expect(row!.available, isFalse);
    });

    test('限流（-412）不标记音源失效——那是服务端问题不是视频问题', () async {
      await seedVideo();
      nextError = const BiliApiException(
        code: -412,
        message: '请求被拦截',
        endpoint: '/x/player/wbi/playurl',
      );
      final r = await resolver.resolve(songWith(), allowRematched: false);

      expect(r.ok, isFalse);
      expect(r.error, contains('拉流失败'));

      // ★ 关键：视频行必须保持 available = true
      // 若把限流也标成失效，用户网络抖动一次就会永久丢掉这首歌的音源。
      final row = await db.videos.getByBvid('BV1test');
      expect(row!.available, isTrue,
          reason: '限流是服务端问题，不能判定音源失效');
    });

    test('网络异常（非 BiliApiException）不标记失效', () async {
      await seedVideo();
      nextError = const BiliNetworkException('连接超时', endpoint: 'playurl');
      final r = await resolver.resolve(songWith(), allowRematched: false);

      expect(r.ok, isFalse);
      final row = await db.videos.getByBvid('BV1test');
      expect(row!.available, isTrue);
    });
  });

  group('-400「请求错误」cid 自愈', () {
    // ⚠️ 变量名故意叫 healFetchCalls 而不是 fetchCalls：
    // 外层 main() 作用域已有一个同名计数器（属于外层 resolver 的假函数），
    // 在这里再声明一个会遮蔽它，两个假函数各记各的账（真踩过）。
    late int healFetchCalls;
    late int repairCalls;
    int? repairedCid; // null = 修正函数不可用（模拟详情接口失败）

    /// true = 无论 cid 是多少都抛 -400（模拟「-400 另有原因」的场景，
    /// 用于验证 cid 没变化时自愈不浪费第二次拉流）
    bool failAll = false;

    late SourceResolver healingResolver;

    setUp(() {
      healFetchCalls = 0;
      repairCalls = 0;
      repairedCid = null;
      failAll = false;

      healingResolver = SourceResolver(
        videos: db.videos,
        api: (sourceKey, sourceSubKey, {qualityCeiling = 0}) async {
          healFetchCalls++;
          if (failAll || int.tryParse(sourceSubKey) == 0) {
            throw const BiliApiException(
              code: -400,
              message: '请求错误',
              endpoint: '/x/player/wbi/playurl',
            );
          }
          return const AudioSourceInfo(
            url: 'httpscdn/fixed.m4s',
            qualityId: 30280,
            bandwidth: 200000,
          );
        },
        repo: null,
        sourceHeaders: const {},
        repairSourceSubKey: (sourceKey) async {
          repairCalls++;
          return repairedCid?.toString();
        },
      );
    });

    Song songWithCid(int cid) => Song(
          id: 1,
          title: '千里之外',
          artist: '周杰伦/费玉清',
          duration: 256,
          coverSeed: 3,
          sourceStatus: SourceStatus.ok,
          source: AudioSource(
            bvid: 'BV1bad',
            cid: cid,
            qualityLabel: '192Kbps',
            qualityId: 30280,
            matchScore: 0.9,
            auto: true,
            durationDelta: 0,
            uploader: 'UP',
          ),
        );

    test('★ cid=0 播放必挂 → 修正 cid 后重拉成功，cid 落库', () async {
      // 复刻真机确诊的脏数据：video 行 cid=0（搜索接口不返回 cid）
      await seedVideo(bvid: 'BV1bad', cid: 0);
      repairedCid = 763429091;

      final r = await healingResolver.resolve(songWithCid(0));

      expect(r.ok, isTrue, reason: '-400 应触发 cid 自愈并重拉成功');
      expect(int.tryParse(r.sourceSubKey), 763429091, reason: '返回结果必须带修正后的 cid');
      expect(healFetchCalls, 2, reason: '第一次 -400 + 自愈后重试 = 2 次');
      expect(repairCalls, 1);

      // 修正后的 cid 必须随 URL 一起落库，否则下次缓存判定仍失配
      final row = await db.videos.getByBvid('BV1bad');
      expect(row!.cid, 763429091);
      expect(row.audioUrl, 'httpscdn/fixed.m4s');

      // 第二次播放：缓存应直接命中（cid 已修正，判定通过）
      final r2 = await healingResolver.resolve(songWithCid(763429091));
      expect(r2.fromCache, isTrue);
    });

    test('详情接口拿到的 cid 与原值相同 → 不重试，返回失败', () async {
      await seedVideo(bvid: 'BV1bad', cid: 100);
      failAll = true; // -400 另有原因（不是 cid 的问题）
      repairedCid = 100; // 详情返回的 cid 与绑定一致 → 自愈无意义

      final r = await healingResolver.resolve(songWithCid(100));

      expect(r.ok, isFalse);
      expect(r.error, contains('拉流失败'));
      expect(healFetchCalls, 1, reason: 'cid 未变化时不该重试拉流');
      expect(repairCalls, 1);
    });

    test('详情接口不可达（返回 null）→ 走原有失败路径', () async {
      await seedVideo(bvid: 'BV1bad', cid: 0);
      failAll = true;
      repairedCid = null; // 模拟详情接口失败 / 视频已删

      final r = await healingResolver.resolve(songWithCid(0));

      expect(r.ok, isFalse);
      expect(r.error, contains('请求错误'));
      expect(healFetchCalls, 1, reason: '修正不了 cid 就不该浪费第二次拉流');
    });

    test('未注入 repairCid → 保持旧行为（直接失败）', () async {
      await seedVideo(bvid: 'BV1bad', cid: 0);
      nextError = const BiliApiException(
        code: -400,
        message: '请求错误',
        endpoint: '/x/player/wbi/playurl',
      );

      // resolver（外层 setUp 建的）没有 repairCid；这里断言的
      // fetchCalls 也是外层作用域那个（外层假函数的计数）
      final r = await resolver.resolve(songWith(cid: 0), allowRematched: false);

      expect(r.ok, isFalse);
      expect(fetchCalls, 1);
    });
  });

  group('请求头', () {
    test('SourceResolver 必须从 sourceHeaders 参数读请求头，不再硬编码', () {
      // sourceHeaders 现在是 SourceResolver 的构造参数（每个音源的头不同）
      // SourceResolver 本身不再有静态 audioHeaders —— B站的头在 BiliAudioSourceAdapter 里
      expect(resolver.sourceHeaders, isA<Map<String, String>>());
    });
  });

  group('音质偏好透传', () {
    /// 造一条可拉流的歌（复用上面的辅助，避免重复样板）
    test('默认不限制：fetcher 收到 ceiling=0', () async {
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/audio.m4s',
        bandwidth: 320000,
      );
      final r = await resolver.resolve(songWith());
      expect(r.ok, isTrue);
      expect(lastCeiling, 0, reason: '没设偏好时应传 0（不限制）');
    });

    test('设了上限就透传下去（偏好必须真的到达 fetcher）', () async {
      resolver.qualityCeiling = 30232;
      nextStream = const AudioSourceInfo(
        qualityId: 30232,
        url: 'https://cdn/audio.m4s',
        bandwidth: 160000,
      );
      final r = await resolver.resolve(songWith());
      expect(r.ok, isTrue);
      // ★ 这是「设置项不是空壳」的证明：改设置真的改变了发给接口的参数
      expect(lastCeiling, 30232);
    });

    test('偏好可运行时修改，无需重建 Resolver', () async {
      nextStream = const AudioSourceInfo(
        qualityId: 30280,
        url: 'https://cdn/a.m4s',
        bandwidth: 320000,
      );
      resolver.qualityCeiling = 30216;
      await resolver.resolve(songWith());
      expect(lastCeiling, 30216);

      // 改偏好后第二次拉流应带新值（forceRefresh 绕过缓存）
      resolver.qualityCeiling = 30280;
      await resolver.resolve(songWith(), forceRefresh: true);
      expect(lastCeiling, 30280);
    });

    test('★ 缓存音质高于当前上限 → 重新拉流（偏好不能输给 100 分钟的缓存）',
        () async {
      // 之前缓存的是 192K，且远未过期
      await seedVideo(
        url: 'https://cdn/hi.m4s',
        expireAt: nowSec() + 3600,
        qualityId: 30280,
      );
      resolver.qualityCeiling = 30216;
      nextStream = const AudioSourceInfo(
        qualityId: 30216,
        url: 'https://cdn/low.m4s',
        bandwidth: 64000,
      );

      final r = await resolver.resolve(songWith());

      expect(r.url, 'https://cdn/low.m4s');
      expect(r.fromCache, isFalse);
      expect(fetchCalls, 1,
          reason: '缓存的 192K 不符合 64K 上限，必须重拉而不是继续用旧流');
      expect(lastCeiling, 30216);
    });

    test('缓存音质在上限以内 → 复用缓存，不发请求', () async {
      await seedVideo(
        url: 'https://cdn/low.m4s',
        expireAt: nowSec() + 3600,
        qualityId: 30216,
        bitrate: 64000,
      );
      resolver.qualityCeiling = 30280;

      final r = await resolver.resolve(songWith());

      expect(r.url, 'https://cdn/low.m4s');
      expect(r.fromCache, isTrue);
      expect(fetchCalls, 0, reason: '档位已符合偏好，没必要重拉');
    });
  });

  group('音质档位选择（pickBestAudio）', () {
    const streams = [
      AudioStream(id: 30280, baseUrl: 'hi', bandwidth: 320000),
      AudioStream(id: 30232, baseUrl: 'mid', bandwidth: 160000),
      AudioStream(id: 30216, baseUrl: 'low', bandwidth: 64000),
    ];

    test('不设上限时取最高（30280 优先于 30232）', () {
      expect(pickBestAudio(streams)!.id, 30280);
    });

    test('上限 30232 → 只在 30232/30216 之间挑，取 30232', () {
      expect(pickBestAudio(streams, ceiling: 30232)!.id, 30232);
    });

    test('上限 30216 → 只能取 30216', () {
      expect(pickBestAudio(streams, ceiling: 30216)!.id, 30216);
    });

    test('偏好档位下没有可用流 → 放宽到全部，而不是返回 null', () {
      // 视频只有 30280，用户却把上限压到 30216。
      // 这时宁可播高音质，也不能静默无声——这是「上限」而非「强制」的含义。
      const only = [AudioStream(id: 30280, baseUrl: 'hi', bandwidth: 320000)];
      final picked = pickBestAudio(only, ceiling: 30216);
      expect(picked, isNotNull, reason: '偏好过窄不该导致拿不到流');
      expect(picked!.id, 30280);
    });

    test('空列表返回 null，不抛异常', () {
      expect(pickBestAudio(const []), isNull);
    });
  });
}
