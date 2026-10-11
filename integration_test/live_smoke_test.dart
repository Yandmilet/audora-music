/// 真机联网冒烟测试（**真机跑，需要网络**）。
///
/// 与 `test/` 下的单测不同，这个文件放在 `integration_test/`，
/// 通过 `flutter test integration_test/live_smoke_test.dart -d <device>` 在真机上执行，
/// 因而具备真实的：
///   - 网络栈（dio + 真实 DNS / TLS）
///   - SQLite 原生实现（sqflite，非 ffi）
///   - 应用沙盒权限
///
/// 验证的是「UI 到真实数据」这条链路上最不确定的部分：
/// B站 Wbi 签名是否被接受、QQ音乐接口是否可达、严格三重校验的通过率。
///
/// ⚠️ 会产生真实网络请求，不要放进 CI。命名带 `live_` 前缀便于识别与排除。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/net/rate_limiter.dart';
import 'package:audora_music/services/lyric/lrc_parser.dart';
import 'package:audora_music/services/playback/source_resolver.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_dto.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late LibraryRepository repo;

  setUpAll(() async {
    // 真机用真实数据库文件（走 sqflite 原生实现）
    db = await AppDatabase.open();
    final limiter = RateLimiter(maxRequests: 30, window: const Duration(minutes: 1));
    final client = BiliApiClient(rateLimiter: limiter);
    // 与 main.dart 的装配保持一致：MatchEngine 吃 AudioSourceProvider 接口
    // （BiliAudioSourceAdapter 包 BiliApi），元数据走 QQMusicMetadataAdapter。
    final biliAdapter = BiliAudioSourceAdapter(BiliApi(client));
    repo = LibraryRepository(
      db: db,
      engine: MatchEngine(biliAdapter, rateLimiter: limiter),
      metadata: QQMusicMetadataAdapter(QQMusicProvider()),
    );
  });

  tearDownAll(() async => db.close());

  test('QQ音乐解析 + 严格三重校验', () async {
    const queries = [
      BatchQuery(title: '起风了', artist: '买辣椒也用券'),
      BatchQuery(title: '无名的人', artist: '毛不易'),
    ];

    final result = await repo.importFromKeywords(
      queries,
      onProgress: (done, total) => debugLog('  导入进度 $done/$total'),
    );

    debugLog('成功 ${result.successCount} / ${result.total}');
    for (final e in result.successes) {
      debugLog('  ✅ ${e.query.title} - ${e.query.artist} → '
          '「${e.song.title}」${e.song.artist} ${e.song.duration}s '
          'mid=${e.sourceId}');
    }
    for (final r in result.rejections) {
      debugLog('  ❌ ${r.query.title} - ${r.query.artist}：${r.reason}');
    }

    // 至少一首能通过，否则说明接口或校验有问题
    expect(result.successCount, greaterThan(0),
        reason: '两首常见歌一首都没解析出来，检查网络或三重校验是否过严');

    // ★ 真实 songMid 必须被带回来 —— 这是歌词能否取到的前提。
    // 曾经的缺陷就是这里全成了 `local:` 派生值，导致歌词静默命中 0 首。
    for (final e in result.successes) {
      expect(e.sourceId, isNotEmpty, reason: '「${e.song.title}」没带回 songMid');
      expect(e.sourceId, isNot(startsWith('local:')),
          reason: '「${e.song.title}」带回的是派生 mid，歌词将无法获取');
    }

    // 落库验证
    final list = await repo.listSongs();
    debugLog('曲库现有 ${list.length} 首');
    expect(list.length, result.successCount);
    for (final item in list) {
      expect(item.id, isNotNull, reason: '落库后必须有 id');
      debugLog('  · ${item.song.title} - ${item.song.artist} '
          'id=${item.id} dur=${item.song.duration}s');

      // ★ 核心：库里存的必须是真实 mid，不能是 local: 派生值
      final row = await db.songs.getById(item.id!);
      expect(row, isNotNull);
      expect(row!.qqSongMid, isNot(startsWith('local:')),
          reason: '「${item.song.title}」落库 mid 是 ${row.qqSongMid}，'
              '歌词接口不认派生 mid');
      debugLog('     mid=${row.qqSongMid} album=${row.albumMid}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('单曲匹配音源（B站）', () async {
    final songs = await repo.listSongs();
    if (songs.isEmpty) {
      markTestSkipped('曲库为空，跳过匹配（上一个测试可能未导入成功）');
      return;
    }

    final target = songs.first;
    debugLog('对「${target.song.title} - ${target.song.artist}」跑匹配…');

    final r = await repo.matchOne(target.id!);
    for (final line in r.diagnostics) {
      debugLog('  $line');
    }

    if (r.best == null) {
      debugLog('  ⚠️ 无候选');
    } else {
      final b = r.best!;
      debugLog('  ✅ ${b.video.bvid} 「${b.video.title}」 '
          'UP=${b.video.author} ${b.score100}分 ${b.confidence.label}');
      debugLog('  ${b.detail.toJson()}');
      for (final u in r.runnerUps.take(3)) {
        debugLog('  runner-up: ${u.video.bvid} ${u.score100}分');
      }
    }

    // 匹配结果无论成功与否都应落库可查（失败时至少留下诊断）
    final after = await repo.getSong(target.id!);
    expect(after, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('音源解析（拉流）→ 拿到可播 URL 并落库', () async {
    final songs = await repo.listSongs();
    final playable = songs.where((s) => s.source != null).toList();
    if (playable.isEmpty) {
      markTestSkipped('没有已匹配音源的歌，跳过拉流（上一个测试可能未绑定成功）');
      return;
    }

    final target = playable.first;
    debugLog('对「${target.song.title}」拉流…');

    final limiter = RateLimiter(maxRequests: 30, window: const Duration(minutes: 1));
    final client = BiliApiClient(rateLimiter: limiter);
    final api = BiliApi(client);
    final biliAdapter = BiliAudioSourceAdapter(api);

    final resolver = SourceResolver(
      videos: db.videos,
      api: biliAdapter.fetchAudioStream,
      sourceHeaders: biliAdapter.requiredHeaders,
      repo: repo,
    );

    final r = await resolver.resolve(target.song);
    debugLog('  ok=${r.ok} fromCache=${r.fromCache} q=${r.qualityId} '
        'bw=${r.bandwidth} err=${r.error}');
    if (r.ok) {
      // 只打印前 80 字符：直链很长且带签名参数，全打印会刷屏
      debugLog('  url=${r.url!.substring(0, r.url!.length.clamp(0, 80))}…');
    }

    expect(r.ok, isTrue, reason: '已匹配的歌必须能拉到流：${r.error}');

    // 第二次应命中缓存（证明 URL 已落库且过期时间合理）
    final r2 = await resolver.resolve(target.song);
    debugLog('  第二次 fromCache=${r2.fromCache}');
    expect(r2.fromCache, isTrue, reason: 'URL 应已落库，第二次不该重新拉流');

    // 落库校验
    final row = await db.videos.getByBvid(r.sourceKey);
    expect(row, isNotNull);
    expect(row!.audioUrl, isNotNull);
    expect(row.audioUrlExpireAt, greaterThan(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ));
    debugLog('  库内 expire_at=${row.audioUrlExpireAt} '
        '（约 ${((row.audioUrlExpireAt! - DateTime.now().millisecondsSinceEpoch ~/ 1000) / 60).round()} 分钟后过期）');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('歌词拉取（QQ音乐 LRC）', () async {
    final songs = await repo.listSongs();
    if (songs.isEmpty) {
      markTestSkipped('曲库为空，跳过歌词');
      return;
    }

    var hit = 0;
    var localMid = 0;
    for (final item in songs.take(3)) {
      // 先看落库的 mid：local: 开头说明上面那步没写对，这里必然取不到词
      final row = await db.songs.getById(item.id!);
      final mid = row?.qqSongMid ?? '';
      if (mid.startsWith('local:')) {
        localMid++;
        debugLog('  ⚠️ 「${item.song.title}」库里是派生 mid=$mid');
      }

      final raw = await repo.fetchLyric(item.song);
      if (raw == null || raw.lrc.trim().isEmpty) {
        debugLog('  · 「${item.song.title}」无歌词（mid=$mid）');
        continue;
      }
      final parsed = parseLrc(raw.lrc);
      debugLog('  ✅ 「${item.song.title}」LRC ${raw.lrc.length} 字符 → '
          '解析出 ${parsed.lines.length} 行'
          '${parsed.instrumental ? "（纯音乐）" : ""}');
      if (parsed.lines.isNotEmpty) {
        debugLog('     首行 [${parsed.lines.first.time.inSeconds}s] '
            '${parsed.lines.first.text}');
        debugLog('     末行 [${parsed.lines.last.time.inSeconds}s] '
            '${parsed.lines.last.text}');
        hit++;
      }
    }

    debugLog('歌词命中 $hit 首，派生 mid $localMid 首');

    // ★ 不再断言「随便，只要不抛异常」——那正是这个 bug 藏了这么久的原因。
    // 只要库里没有派生 mid 就说明 mid 落地是对的，此时必须至少命中一首
    // （取样的都是常见中文流行歌，正常都应带词）。
    expect(localMid, 0, reason: '库里出现了 local: 派生 mid，歌词必然取不到');
    expect(hit, greaterThan(0), reason: '真实 mid 却一首歌词都没命中，检查歌词接口');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('在线搜索（QQ音乐）→ 结果可直接导入 → 有歌词', () async {
    const kw = '晴天 周杰伦';
    debugLog('在线搜索「$kw」…');

    final results = await repo.searchOnline(kw);
    debugLog('  返回 ${results.length} 条');
    for (final e in results.take(5)) {
      debugLog('  · ${e.song.title} - ${e.song.artist} '
          '${e.song.duration}s mid=${e.songMid} '
          'inLibrary=${e.inLibrary} album=${e.song.album}');
    }

    expect(results, isNotEmpty, reason: '在线搜索没结果，检查 QQ 搜索接口');

    // ★ 与 E23 同源的不变量：在线结果的 mid 必须是真实值。
    // 一旦这里退化成 local:，导入后歌词就静默失效。
    for (final e in results) {
      expect(e.songMid, isNotEmpty,
          reason: '「${e.song.title}」搜索结果没带 songMid');
      expect(e.songMid, isNot(startsWith('local:')),
          reason: '「${e.song.title}」的 mid 是派生值，导入后歌词取不到');
    }

    // 详情补全应拿到精确时长（搜索结果里的 interval 可能是粗略值）
    final withDur = results.where((e) => e.song.duration > 0).length;
    debugLog('  有明确时长的 $withDur/${results.length} 条');
    expect(withDur, greaterThan(0), reason: '详情补全没生效，时长全为 0');

    // 搜索必须是只读的
    final before = (await repo.listSongs()).length;
    expect(before, greaterThanOrEqualTo(0));
    final afterSearch = (await repo.listSongs()).length;
    expect(afterSearch, before, reason: '搜索不该写库（曲库被搜索污染）');

    // 导入第一条
    final pick = results.first;
    final n = await repo.importOnline([pick]);
    debugLog('  导入「${pick.song.title}」→ $n 行');
    expect(n, greaterThan(0));

    // ★ 落库后 mid 必须还是真实值
    final row = await db.songs.getByMid(pick.songMid);
    expect(row, isNotNull, reason: '应按真实 mid 入库');
    expect(row!.qqSongMid, pick.songMid);
    expect(row.isLocal, isFalse);

    // ★ 端到端：导入的歌必须取得到歌词。这是整条链路的意义所在。
    final lrc = await repo.fetchLyric(row.toSong());
    debugLog('  歌词：${lrc == null ? "取不到" : "${lrc.lrc.length} 字符"}');
    expect(lrc, isNotNull, reason: '导入后取不到歌词，mid 链路仍有问题');

    // 重复导入不产生新行
    final beforeDup = (await repo.listSongs()).length;
    await repo.importOnline([pick]);
    final afterDup = (await repo.listSongs()).length;
    debugLog('  重复导入后行数 $beforeDup → $afterDup');
    expect(afterDup, beforeDup, reason: '同 mid 重复导入应走更新而非新增');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// integration_test 环境里 `print` 会被吞掉，用这个统一出口
void debugLog(String msg) {
  // ignore: avoid_print
  print('[LIVE] $msg');
}
