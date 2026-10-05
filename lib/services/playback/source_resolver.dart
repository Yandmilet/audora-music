/// 音源解析器 —— 「歌曲」到「一个能播的 URL」之间的全部脏活。
///
/// ## 为什么必须有这一层
/// 播放器（[AudioPlayerController]）只想要一个 URL 字符串。
/// 但拿到这个 URL 要经历：
///   1. 查库看有没有**未过期**的缓存 URL（有就直接用，省一次请求）
///   2. 没有 / 过期了 → 调 B站 playurl 接口拉流
///   3. 拉回来写库（含过期时间），供下次复用
///   4. 播放中途 403/404（URL 过期或视频被删）→ 判断是「过期」还是「真的没了」
///      过期就重拉；真的没了就标记 unavailable 并**自动重新匹配**换一首
///
/// 这些逻辑放在 UI 或播放器里都会把那一层弄脏，且没法单独测试。
///
/// ## 与 LibraryRepository 的分工
/// Repository 管「谁配谁」（绑定关系），Resolver 管「拿 URL 去播」。
/// 唯一的重叠点是自动重匹配——那是 Resolver 调 Repository，不是反过来。
library;

import 'dart:async';

import '../../data/db/dao/video_dao.dart';
import '../../data/repository/library_repository.dart';
import '../../models/models.dart';
import '../bilibili/bili_dto.dart' show audioQualityRank;
import '../bilibili/bili_exception.dart';
import '../diag/diag_log.dart';

import '../source/audio_source_provider.dart' show AudioSourceInfo;

/// 拉流函数的签名（通用化）。
///
/// 不同音频源的主键命名不同：B站叫 bvid/cid，YouTube 叫 videoId/index，
/// 网易云叫 trackId 无分P。这里统一成 sourceKey（主键）+ sourceSubKey（分P/轨道，String 化）。
///
/// 返回通用 [AudioSourceInfo]（不是 B站专属的 AudioStream）—— 这个类型定义在
/// audio_source_provider.dart 里，任何音频源的适配器（BiliAudioSourceAdapter 等）
/// 都必须把自己的流格式转成它再返回。
///
/// 单测里传个返回固定 AudioSourceInfo 的 lambda 即可验证缓存/失效/自动重匹配，
/// 不需要搭整套网络栈。
typedef AudioStreamFetcher = Future<AudioSourceInfo?> Function(
  String sourceKey,
  String sourceSubKey, {
  /// 音质上限偏好（0 = 不限制）。由 SourceResolver 透传用户设置。
  int qualityCeiling,
});

/// 音源子键修正函数的签名：用详情接口取回该 sourceKey 的真实 sourceSubKey。
///
/// 仅某些源需要它（B站搜索接口不返回 cid，绕过详情落库的行 cid=0 会让
/// playurl 每播必挂）。其他源（YouTube Music / 网易云）不需要这个修复路径
/// 时适配器可以传 null。
///
/// 返回 String?（修正后的 sourceSubKey）—— null 表示修不了 / 无需修。
typedef SourceSubKeyRepairer = Future<String?> Function(String sourceKey);

/// 解析结果：要么拿到 URL，要么带着原因失败。
class ResolveResult {
  /// 可播放的音频直链（CDN 拉流时必须带 [SourceResolver.sourceHeaders]）
  final String? url;

  /// 实际命中的音质（源内部标识，落库用）
  final int qualityId;

  /// 码率（bytes/s），界面可展示
  final int bandwidth;

  /// 实际命中的 sourceKey（主键，可能因自动重匹配而与入参不同）
  final String sourceKey;

  /// 实际命中的 sourceSubKey（分P/轨道 String 化，可能因 cid 自愈而变化）
  final String sourceSubKey;

  /// URL 过期时间（秒级时间戳）
  final int expireAt;

  /// true 表示走了本地缓存，没发网络请求
  final bool fromCache;

  /// true 表示发生了「自动重新匹配」（原音源失效，已换到新的）
  final bool rematched;

  /// 失败原因（url 为 null 时非空）
  final String? error;

  const ResolveResult({
    this.url,
    this.qualityId = 0,
    this.bandwidth = 0,
    required this.sourceKey,
    required this.sourceSubKey,
    this.expireAt = 0,
    this.fromCache = false,
    this.rematched = false,
    this.error,
  });

  bool get ok => url != null && url!.isNotEmpty;

  @override
  String toString() => ok
      ? 'ResolveResult($sourceKey/$sourceSubKey, q=$qualityId, '
          '${fromCache ? "cache" : "net"}${rematched ? ", rematched" : ""})'
      : 'ResolveResult(failed: $error)';
}

class SourceResolver {
  SourceResolver({
    required this.videos,
    required this.api,
    required this.repo,
    required this.sourceHeaders,
    this.repairSourceSubKey,
    this.qualityCeiling = 0,
  });

  /// 音质上限偏好（0 = 不限制）。
  ///
  /// ## 放在这里而不是 API 客户端里
  /// 播放偏好是**用户设置**，不是接口参数。客户端不该知道用户选了什么；
  /// 由 Resolver 在拉流时把它交给 fetcher。
  ///
  /// 可变：用户在设置里改了音质，不需要重建 Resolver 与整个播放链路，
  /// 改这个值即可，**下一次拉流**生效（不打断正在播的）。
  ///
  /// 注意语义是**上限**而非「强制」：偏好档位下没有可用流时会放宽到全部，
  /// 宁可音质差一点也不能静默无声。
  int qualityCeiling;

  /// CDN 拉流需要带的请求头（每个音频源的头不同：B站要 Referer，其他源可能不需要）。
  ///
  /// 由装配层传入 —— 生产环境传音频源适配器的 [AudioSourceProvider.requiredHeaders]，
  /// 单测可传空 Map 或自定义头。播放器（AudioPlayerController）拉流时读这个值，
  /// 不再硬编码 `SourceResolver.audioHeaders`。
  final Map<String, String> sourceHeaders;

  /// 只依赖 VideoDao 而不是整个 AppDatabase：
  /// 本类用到的只有「读/写视频行的音频 URL 字段」这一件事，
  /// 把整个数据库塞进来会让单测必须建真库、也让依赖关系失真。
  final VideoDao videos;

  /// 拉流函数。生产环境传 `adapter.fetchAudioStream`（适配器包装后的签名），
  /// 单测传返回固定 AudioSourceInfo 的 lambda。
  final AudioStreamFetcher api;

  /// 音源失效时用它重新匹配。
  ///
  /// 声明为可空 + 由外部注入，是为了让单测能只测「拉流 + 缓存」路径
  /// 而不必拖动整个匹配引擎和网络栈。
  final LibraryRepository? repo;

  /// 音源子键修正函数（-400 自愈路径，B站专属）。
  ///
  /// ## 为什么必须有它（2026-09-30 真机日志确诊）
  /// playurl 返回 -400「请求错误」时，九成是 video 行的 cid 坏了
  /// （搜索接口不返回 cid，绕过详情落库的行 cid=0），对该 bvid
  /// **每播必挂、永不自愈**。此时花一次详情请求修正 cid 再重试，
  /// 成本远小于整首重匹配；误伤面几乎为零——cid 本来就没变的话，
  /// 重试一次 playurl 也无害。
  ///
  /// 非 B站源（YouTube Music / 网易云等）不需要这个修复路径，传入 null 即可。
  final SourceSubKeyRepairer? repairSourceSubKey;

  /// playurl 返回的 URL 有效期。官方文档写 120 分钟，
  /// 这里按 **100 分钟**落库，多留 20 分钟缓冲——
  /// 客户端与服务器时钟有偏差时，按满 120 分钟算会在边缘踩 403。
  static const _urlTtl = Duration(minutes: 100);

  /// 并发去重：同一首歌同时被请求两次时，只发一次网络请求。
  ///
  /// 场景：用户连点两下播放、或「播放」与「预加载下一首」同时触发。
  final Map<String, Future<ResolveResult>> _inflight = {};

  /// 解析一首歌的可播放 URL。
  ///
  /// [allowRematched] = true 时，若判定音源真的失效（视频被删/权限关闭），
  /// 会自动调用匹配引擎换一个音源。递归深度限制为 1，避免死循环。
  Future<ResolveResult> resolve(
    Song song, {
    bool forceRefresh = false,
    bool allowRematched = true,
  }) async {
    final src = song.source;
    // 步骤 7：优先读通用字段，空时兜底 .bvid/.cid（双写期兼容）
    if (src == null || (src.sourceKey.isEmpty && src.bvid.isEmpty)) {
      return const ResolveResult(sourceKey: '', sourceSubKey: '', error: '这首歌还没有匹配到音源');
    }

    final sourceKey = src.sourceKey.isNotEmpty ? src.sourceKey : src.bvid;
    final sourceSubKey = src.sourceSubKey.isNotEmpty ? src.sourceSubKey : src.cid.toString();
    final key = '$sourceKey/$sourceSubKey';
    final existing = _inflight[key];
    if (existing != null) return existing;

    final fut = _resolveInner(
      song,
      sourceKey: sourceKey,
      sourceSubKey: sourceSubKey,
      forceRefresh: forceRefresh,
      allowRematched: allowRematched,
    );
    _inflight[key] = fut;
    try {
      return await fut;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<ResolveResult> _resolveInner(
    Song song, {
    required String sourceKey,
    required String sourceSubKey,
    required bool forceRefresh,
    required bool allowRematched,
  }) async {
    final cidInt = int.tryParse(sourceSubKey) ?? 0;

    // ── 1. 先看缓存 ─────────────────────────────────────
    if (!forceRefresh) {
      final row = await videos.getByBvid(sourceKey);
      // ⚠️ 缓存还必须「符合当前音质上限」才算命中。
      // URL 缓存有效期 100 分钟，若只看有效期，用户把偏好从「自动最高」
      // 调到「省流 64K」后，接下来 100 分钟里播的仍是之前缓存的 192K 流
      // ——设置看起来完全没生效（音质筛选最容易被误判成空壳的地方）。
      if (row != null &&
          row.isAudioUrlValid &&
          row.cid == cidInt &&
          _cacheMatchesCeiling(row.audioQualityId)) {
        // 缓存命中率直接决定配额消耗：每次没命中就要打一次 playurl
        DiagLog.instance.i(
          DiagCategory.playback,
          '命中缓存 URL：$sourceKey',
          {
            'event': 'resolve',
            'sourceKey': sourceKey,
            'sourceSubKey': sourceSubKey,
            'fromCache': true,
            'qualityId': row.audioQualityId ?? 0,
          },
        );
        return ResolveResult(
          url: row.audioUrl,
          qualityId: row.audioQualityId ?? 0,
          bandwidth: row.audioBitrate ?? 0,
          sourceKey: sourceKey,
          sourceSubKey: sourceSubKey,
          expireAt: row.audioUrlExpireAt ?? 0,
          fromCache: true,
        );
      }
    }

    // ── 2. 拉流 ────────────────────────────────────────
    try {
      final stream = await api(sourceKey, sourceSubKey,
          qualityCeiling: qualityCeiling);
      if (stream == null) {
        // 接口正常但拿不到 audio 流：视频被删 / 充电专属 / 番剧。
        // 这里也要 await：_handleGone 内部会写库并可能抛出，
        // 不 await 的话异常会脱离下面的 catch 块。
        return await _handleGone(song, sourceKey, sourceSubKey,
            '视频无可用音频流', allowRematched: allowRematched);
      }

      final expireAt =
          DateTime.now().add(_urlTtl).millisecondsSinceEpoch ~/ 1000;
      await videos.updateAudioStream(
        sourceKey,
        url: stream.url,
        expireAt: expireAt,
        qualityId: stream.qualityId,
        bitrate: stream.bandwidth,
        // cid 必须一起落库：行不存在要补插时，缺了 cid 会记成 0，
        // 下次读缓存时 `row.cid == src.cid` 判定失败，缓存永远命中不了。
        cid: cidInt,
      );

      DiagLog.instance.i(
        DiagCategory.playback,
        '拉流成功：$sourceKey q=${stream.qualityId}',
        {
          'event': 'resolve',
          'sourceKey': sourceKey,
          'sourceSubKey': sourceSubKey,
          'fromCache': false,
          'qualityId': stream.qualityId,
          'bandwidth': stream.bandwidth,
          'ceiling': qualityCeiling,
        },
      );
      return ResolveResult(
        url: stream.url,
        qualityId: stream.qualityId,
        bandwidth: stream.bandwidth,
        sourceKey: sourceKey,
        sourceSubKey: sourceSubKey,
        expireAt: expireAt,
      );
    } on BiliApiException catch (e) {
      // -404 视频不存在 / -403 权限不足 → 音源真的没了
      if (e.isNotFound || e.isForbidden) {
        DiagLog.instance.w(
          DiagCategory.playback,
          '音源失效，准备重匹配：$sourceKey（${e.code}）',
          {'event': 'resolve', 'sourceKey': sourceKey, 'code': e.code},
        );
        return await _handleGone(song, sourceKey, sourceSubKey,
            '音源已失效（${e.code}）', allowRematched: allowRematched);
      }

      // ── -400「请求错误」自愈 ──────────────────────────────
      // playurl 的 -400 几乎总是 video 行 cid 坏了（搜索接口不返回
      // cid，绕过详情落库的行 cid=0），对该 bvid 每播必挂。
      // 先花一次详情请求修 cid，拿到不同 cid 就地重试拉流。
      // 只修一次：修完仍失败就走通用失败文案，不在这里循环。
      if (e.code == -400 && allowRematched) {
        final repaired = await _repairSourceSubKeyAndRetry(song, sourceKey, sourceSubKey);
        if (repaired != null) return repaired;
      }

      DiagLog.instance.w(
        DiagCategory.playback,
        '拉流失败：$sourceKey（${e.code}）',
        {'event': 'resolve', 'sourceKey': sourceKey, 'code': e.code},
      );
      return ResolveResult(sourceKey: sourceKey, sourceSubKey: sourceSubKey, error: '拉流失败：${e.message}');
    } catch (e) {
      DiagLog.instance.w(
        DiagCategory.playback,
        '拉流异常：$sourceKey $e',
        {'event': 'resolve', 'sourceKey': sourceKey},
      );
      return ResolveResult(sourceKey: sourceKey, sourceSubKey: sourceSubKey, error: '拉流失败：$e');
    }
  }

  /// -400 自愈：修正 sourceSubKey（cid）并用新值重拉一次。
  ///
  /// 返回 null 表示「修不了 / 修了没用」（无 repairSourceSubKey、详情不可达、
  /// cid 本来就对、或重试仍失败），调用方继续走原有失败路径。
  /// 成功时返回带新 sourceSubKey 的 [ResolveResult]——调用方（播放器）会用
  /// `source.copyWith(cid: int.parse(res.sourceSubKey))` 就地纠正内存里的音源，
  /// 无需重查库。
  Future<ResolveResult?> _repairSourceSubKeyAndRetry(
    Song song, String sourceKey, String sourceSubKey) async {
    if (repairSourceSubKey == null) return null;

    final fixedSubKey = await repairSourceSubKey!(sourceKey);
    final curCid = int.tryParse(sourceSubKey) ?? 0;
    final fixedCid = int.tryParse(fixedSubKey ?? '') ?? 0;
    if (fixedSubKey == null || fixedCid <= 0 || fixedCid == curCid) {
      return null;
    }

    DiagLog.instance.w(
      DiagCategory.playback,
      'playurl -400 自愈：$sourceKey cid $curCid → $fixedCid',
      {
        'event': 'resolve',
        'sourceKey': sourceKey,
        'oldSubKey': sourceSubKey,
        'newSubKey': fixedSubKey,
      },
    );

    try {
      final stream =
          await api(sourceKey, fixedSubKey, qualityCeiling: qualityCeiling);
      if (stream == null) return null;

      final expireAt =
          DateTime.now().add(_urlTtl).millisecondsSinceEpoch ~/ 1000;
      await videos.updateAudioStream(
        sourceKey,
        url: stream.url,
        expireAt: expireAt,
        qualityId: stream.qualityId,
        bitrate: stream.bandwidth,
        // 修正后的 cid 必须随 URL 一起落库，否则下次缓存判定仍然失配
        cid: fixedCid,
      );

      DiagLog.instance.i(
        DiagCategory.playback,
        '拉流成功（cid 自愈后）：$sourceKey q=${stream.qualityId}',
        {
          'event': 'resolve',
          'sourceKey': sourceKey,
          'sourceSubKey': fixedSubKey,
          'fromCache': false,
          'qualityId': stream.qualityId,
          'bandwidth': stream.bandwidth,
        },
      );
      return ResolveResult(
        url: stream.url,
        qualityId: stream.qualityId,
        bandwidth: stream.bandwidth,
        sourceKey: sourceKey,
        sourceSubKey: fixedSubKey,
        expireAt: expireAt,
      );
    } catch (_) {
      // 自愈重试也失败：交给上层按普通失败处理，不在这里无限循环
      return null;
    }
  }

  /// 音源确实失效时的处理：标记不可用 → 自动重新匹配 → 用新音源再解析一次。
  ///
  /// ⚠️ 递归只允许一层（`allowRematched: false`）。若新匹配出来的音源仍然
  /// 拉不到流，直接返回失败给用户，不再往下换——否则遇到「整个匹配器坏了」
  /// 的情况会在多首歌之间连环重匹配，把限流配额瞬间打光。
  /// 缓存的 URL 是否仍符合当前音质上限偏好。
  ///
  /// - 没设上限（0）→ 一律算命中，缓存什么都不用管
  /// - 缓存没记音质（null / 0）→ 无法判断是否超限，重拉一次（代价只是一个请求）
  /// - 缓存音质档位高于上限 → 不命中，重拉并按新上限挑流
  bool _cacheMatchesCeiling(int? cachedQualityId) {
    if (qualityCeiling <= 0) return true;
    final q = cachedQualityId ?? 0;
    if (q <= 0) return false;
    return audioQualityRank(q) <= audioQualityRank(qualityCeiling);
  }

  Future<ResolveResult> _handleGone(
    Song song,
    String sourceKey,
    String sourceSubKey,
    String reason, {
    required bool allowRematched,
  }) async {
    await videos.markUnavailable(sourceKey, reason);
    final songId = song.id;
    if (!allowRematched || songId == null) {
      return ResolveResult(sourceKey: sourceKey, sourceSubKey: sourceSubKey, error: reason);
    }

    try {
      final r = await repo!.matchOne(songId);
      if (!r.isBound || r.best == null) {
        return ResolveResult(
          sourceKey: sourceKey,
          sourceSubKey: sourceSubKey,
          error: '$reason，且重新匹配未找到替代音源',
        );
      }

      // 用新绑定的音源再解析一次。
      final fresh = await repo!.getSong(songId);
      if (fresh == null || fresh.song.source == null) {
        return ResolveResult(sourceKey: sourceKey, sourceSubKey: sourceSubKey, error: '$reason，重匹配结果无音源');
      }

      // ⚠️ 这里必须 await：若直接 return `_resolveInner(...)` 而不 await，
      // 其内部抛出的异常会绕过本函数的 try/catch，变成未捕获异步异常，
      // 表现为「点了播放没反应，也没有任何提示」。
      final freshSrc = fresh.song.source!;
      final retry = await _resolveInner(
        fresh.song,
        sourceKey: freshSrc.sourceKey.isNotEmpty ? freshSrc.sourceKey : freshSrc.bvid,
        sourceSubKey: freshSrc.sourceSubKey.isNotEmpty ? freshSrc.sourceSubKey : freshSrc.cid.toString(),
        forceRefresh: true,
        allowRematched: false,
      );
      return ResolveResult(
        url: retry.url,
        qualityId: retry.qualityId,
        bandwidth: retry.bandwidth,
        sourceKey: retry.sourceKey,
        sourceSubKey: retry.sourceSubKey,
        expireAt: retry.expireAt,
        rematched: true,
        error: retry.error,
      );
    } catch (e) {
      return ResolveResult(sourceKey: sourceKey, sourceSubKey: sourceSubKey, error: '$reason，重匹配异常：$e');
    }
  }

  /// 播放器报错时的入口：判断这次失败是不是「URL 过期」。
  ///
  /// ExoPlayer 对 403 的报错文本不统一（有时是 `Source error`，
  /// 有时带 `Response code: 403`），所以这里用宽松匹配，
  /// 并且**先尝试强制重拉一次 URL**——重拉代价小（一个 HTTP 请求），
  /// 而误判成「音源已死」会白白丢掉一个正确匹配。
  Future<ResolveResult> resolveAfterPlaybackError(Song song) async {
    return resolve(song, forceRefresh: true, allowRematched: true);
  }
}
