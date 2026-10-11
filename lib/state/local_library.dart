/// 本机音频清单（自带扫描 + app 下载）的状态与动作。
///
/// ## 拆出来管的是三件事
///   1. **权限**：MediaStore 不给权限就是查不到，而「查不到」和「这台手机
///      没有歌」必须分开说（后者会让人以为功能坏了）。
///   2. **换血式扫描**：一次扫描 = 一个时间戳，写进去再裁掉没再出现的。
///      实现细节在 `LocalAudioDao` 的注释里，这里只负责把时刻传对。
///   3. **两份清单互相隔离**：`local` 与 `download` 各自一份列表、各自计数，
///      UI 上是两个入口，永不合并展示。
///
/// ## 扫描结果为空时**不裁剪**
/// 「这次一条都没扫到」有两种真相：手机真的没歌，或者权限/提供方出了
/// 问题（MediaStore 在某些 ROM 上被禁用时就是返回空游标而不报错）。
/// 直接裁剪会把用户已有的清单清空，而且看起来像功能正常。所以空结果
/// 一律保留旧清单 + 给一句提示——宁可留一份可能过期的列表，也不要
/// 无声地把东西删光。
library;

import 'package:audora_files/audora_files.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/db/dao/local_audio_dao.dart';
import '../data/repository/library_repository.dart';
import '../models/models.dart';
import '../services/bilibili/bili_dto.dart' show audioQualityLabel;
import '../services/metadata/metadata_provider.dart' show BatchQuery;
import '../services/qqmusic/qqmusic_dto.dart' show QQSongMeta;

/// 本机音频条目 → 领域里的 [Song]。
///
/// 为什么映射而不是给本机文件另立一套播放链路：队列、上一首/下一首、
/// 通知栏 MediaItem、迷你播放条、进度条全都吃 `Song`。另起一套等于把
/// 这些 UI 全抄一遍，而且迟早分叉。差异收在一个地方——[AudioSource.sourceType]
/// 是 `local`，解析层据此短路（见 SourceResolver.resolve）。
///
/// 两个映射细节：
/// - `id` 只在下载条目上有值（回指曲库那首歌），收藏 / 播放统计 / 音量
///   记忆就都能接上；纯扫描条目没有对应歌曲，留 null。
/// - 封面走「有 mid 就拼真图，没有就渐变」：本机文件本身不带 albumMid，
///   但 [LocalLibraryBox] 会按 标题+歌手+时长 去元数据源换一次身份并缓存
///   （见 `song_mid` / `album_mid` 两列）。换到了这里就有 [Song.coverUrl]，
///   换不到（或断网）就是 null，UI 层的渐变占位自然露出来。
Song localEntryToSong(LocalAudioEntry e) => Song(
      id: e.songId,
      title: e.title.isEmpty ? '未命名文件' : e.title,
      artist: e.displayArtist,
      album: e.album,
      duration: e.durationSec,
      sourceStatus: SourceStatus.ok,
      source: AudioSource.localFile(
        uri: e.uri,
        qualityLabel: e.qualityId == 0
            ? '本地文件'
            : '${audioQualityLabel(e.qualityId)} · 本地',
        qualityId: e.qualityId,
      ),
      coverSeed: e.title.hashCode & 0xffff,
      coverUrl: QQSongMeta.coverUrlFor(e.albumMid),
      albumMid: e.albumMid.isEmpty ? null : e.albumMid,
    );

class LocalLibraryBox {
  LocalLibraryBox({
    required LibraryRepository? Function() repo,
    required String? Function() scanPathPrefix,
    required void Function() onChange,
    AudoraFiles? files,
  })  : _repo = repo,
        _scanPathPrefix = scanPathPrefix,
        _onChange = onChange,
        _files = files ?? const AudoraFiles();

  final LibraryRepository? Function() _repo;
  final String? Function() _scanPathPrefix;
  final void Function() _onChange;
  final AudoraFiles _files;

  List<LocalAudioEntry> _local = const [];
  List<LocalAudioEntry> _downloaded = const [];
  bool _scanning = false;

  /// 最近一次扫描成功落库的时刻（秒）。0 = 从没成功扫过。
  int _lastScanAt = 0;

  /// 扫描的失败/异常文案。由 UI 用 SnackBar 呈现，读完即清。
  String? _note;

  List<LocalAudioEntry> get localTracks => _local;
  List<LocalAudioEntry> get downloadedTracks => _downloaded;
  bool get scanning => _scanning;
  String? get scanNote => _note;
  int get lastScanAt => _lastScanAt;
  int get localCount => _local.length;
  int get downloadCount => _downloaded.length;

  /// 读两份清单（不动原生、不发请求）。曲库加载完之后调一次。
  Future<void> load() async {
    final repo = _repo();
    if (repo == null) return;
    _local = await repo.localAudioOf(LocalAudioKind.local);
    _downloaded = await repo.localAudioOf(LocalAudioKind.download);
    _onChange();
  }

  /// 扫一次手机自带音频。返回 null = 正常；返回文案 = 需要告诉用户的事。
  ///
  /// 文案分两类：失败（没权限 / 原生报错）与「扫到了 0 首」——后者不是
  /// 失败，但一定要说，否则用户会以为按钮没反应。
  Future<String?> scan() async {
    final repo = _repo();
    if (repo == null) return '数据层未接入';
    if (_scanning) return null; // 重入静默：按钮此刻应该已经变成转圈

    _scanning = true;
    _note = null;
    _onChange();
    try {
      final denied = await _ensureAudioPermission();
      if (denied != null) return denied;

      final List<AudioFileEntry> found;
      try {
        found = await _files.scanAudio(pathPrefix: _scanPathPrefix());
      } on PlatformException catch (e) {
        if (e.code == 'need_permission') {
          return '没有音频读取权限，允许后才能扫描手机音乐';
        }
        return '扫描失败：${e.message ?? e.code}';
      }

      if (found.isEmpty) {
        // 保留旧清单（见文件头的理由），也不写 lastScanAt——那会被
        // 界面读成「刚刚扫过、确实没有」，而真相是我们不确定。
        return '没扫到音频文件；如果手机里确实有歌，检查一下扫描目录是否选得太窄';
      }

      final stamp = await repo.recordLocalAudio([
        for (final e in found)
          LocalAudioEntry(
            kind: LocalAudioKind.local,
            uri: e.uri,
            path: e.path ?? '',
            title: e.title,
            artist: e.artist,
            album: e.album,
            durationMs: e.durationMs,
            sizeBytes: e.sizeBytes,
            mtimeSec: e.dateAddedSec,
            // firstSeen / lastSeen 不在这里给：同一次扫描必须共用一个时刻，
            // 由 repository 一次取好盖上去（见 recordLocalAudio）。
          ),
      ]);
      await repo.pruneLocalAudio(LocalAudioKind.local, stamp);
      _lastScanAt = stamp;
      await load();
      return null;
    } on DirectoryPlatformUnsupported {
      return '当前平台不支持扫描手机音乐（仅 Android）';
    } on Object catch (e) {
      return '扫描失败：$e';
    } finally {
      _scanning = false;
      _onChange();
    }
  }

  /// 下载清单里删一条记录（文件本身由调用方决定要不要一起删）。
  Future<void> forgetDownload(int id) async {
    final repo = _repo();
    if (repo == null || id <= 0) return;
    await repo.removeLocalAudio(id);
    await load();
  }

  // ── 线上身份补全（真实封面 + 歌词）──────────────────────────
  //
  // 本机文件没有 mid，而封面 URL 和歌词接口都只认 mid。所以要按
  // 「标题 + 歌手 + 时长」去元数据源换一次身份，换到就缓存进 local_audio：
  // 之后进列表不再请求，断网也能用缓存的 mid 拼 URL（图片本身有磁盘缓存）。
  // 换不到的继续走渐变占位——这就是「联网出真封面、不联网出渐变」的落地方式。

  /// 整批补全在跑（UI 可据此不再排队第二个触发点）。
  bool _metaSyncing = false;
  bool get metaSyncing => _metaSyncing;

  /// 连续多少首「请求异常」就认定现在不在线、收手。
  ///
  /// 不引插件判网（不为一个布尔值加一条原生依赖）：真断网时前几首就会
  /// 各自抛异常，够了三次没必要继续往下撞。阈值取 3 而不是 1，是为了
  /// 不让某一次偶发超时误判成断网、把整批补全提前掐掉。
  ///
  /// ⚠️ 收手发生在**分片边界**上：`resolveBatch` 一旦开跑就会把这一片串行
  /// 走完（它的结果是一次性返回的，中途抛异常会把已经解析到的那几首一起
  /// 丢掉）。所以分片默认只有 6——断网时一次进页面最多撞 6 下就停。
  static const int offlineAbortAfter = 3;

  /// 补全清单里缺失的线上身份。返回这一轮真正补到的条数。
  ///
  /// [limit] 是**本轮最多处理多少首**（不是最多补到多少首），[chunk] 是每片
  /// 大小：一片跑完就刷一次清单，也让断网早停有落点。
  ///
  /// ## 为什么分片跑、每片刷一次清单
  /// 元数据源的批量解析是**串行 + 每首间隔 400ms**（风控要求，见
  /// `QQMusicProvider.resolveBatch`）。60 首就是半分钟——卡在进页面的
  /// loading 上不可接受。分片跑完一片就 `load()` 一次，用户看到的是封面
  /// 一首一首变真，而不是转圈等整批。
  ///
  /// ## 失败分两种，处理方式相反
  /// - 「三重校验不通过」= 这个源上确实没有这首歌 → 标 `resolved_at`，
  ///   冷却期内别再打请求。
  /// - 「请求异常」= 可能是断网/超时 → **不标**，下次进页面还会试。
  Future<int> syncMissingMeta({int limit = 60, int chunk = 6}) async {
    final repo = _repo();
    if (repo == null || _metaSyncing) return 0;

    _metaSyncing = true;
    _onChange();
    var done = 0;
    try {
      // 先做零成本的那一半：下载条目回指的曲库歌往往已经有真 mid
      done += await repo.backfillLocalFromSongs();
      var lastRoundLooksOffline = false;
      // 用「已处理条数」而不是「已补到条数」当上界：一轮里如果谁都补不到
      // （全被拒），done 会一直不动，拿 done 当循环界就是个死循环。
      var tried = 0;
      while (!lastRoundLooksOffline && tried < limit) {
        final pending = await repo.localAudioUnresolved(limit: chunk);
        if (pending.isEmpty) break;
        tried += pending.length;
        final r = await _resolveByBatch(repo, pending);
        done += r.resolved;
        lastRoundLooksOffline = r.looksOffline;
        await load(); // 封面一首一首变真
        if (pending.length < chunk) break;
      }
    } on Object {
      // 补全是展示增强：任何意外都不该把「本机清单」这条路弄挂
    } finally {
      _metaSyncing = false;
      _onChange();
    }
    return done;
  }

  /// 单曲补全，给「点开本机歌就要有词」用——不能等整批轮到自己。
  Future<bool> resolveOne(LocalAudioEntry e) async {
    final repo = _repo();
    if (repo == null || e.title.isEmpty) return false;
    if (e.songMid.isNotEmpty) return true;
    if (_metaSyncing) return false; // 整批在跑，它会顺手把这首带上

    _metaSyncing = true;
    try {
      final r = await _resolveByBatch(repo, [e]);
      await load();
      return r.resolved > 0;
    } on Object {
      return false;
    } finally {
      _metaSyncing = false;
      _onChange();
    }
  }

  /// 一批条目走同一个解析出口，成功写 mid、失败按类型决定要不要冷却。
  Future<({int resolved, bool looksOffline})> _resolveByBatch(
    LibraryRepository repo,
    List<LocalAudioEntry> entries,
  ) async {
    final result = await repo.metadata.resolveBatch(
      [
        for (final e in entries)
          BatchQuery(
            title: e.title,
            artist: e.artist,
            durationSec: e.durationSec,
            refId: e.uri, // 回写靠 uri 对齐，它才是本机文件的稳定标识
          ),
      ],
      withLyricCredits: false, // 只要身份，歌词等真播放时再取
    );

    var resolved = 0;
    var networkErrors = 0;
    for (final s in result.successes) {
      await repo.resolveLocalAudio(
        s.query.refId,
        songMid: s.sourceId,
        albumMid: s.coverSourceId,
      );
      resolved++;
      networkErrors = 0;
    }
    for (final r in result.rejections) {
      // '请求异常' 是 resolveBatch 给异常项的前缀（它自己 catch 掉单首异常，
      // 换成返回带原因的 rejection）。这个前缀是两层的约定，改动要一起改。
      final isNetworkError = r.reason.startsWith('请求异常');
      if (!isNetworkError) {
        await repo.markLocalAudioAttempted(r.query.refId);
        networkErrors = 0;
        continue;
      }
      networkErrors++;
      if (networkErrors >= offlineAbortAfter) {
        return (resolved: resolved, looksOffline: true);
      }
    }
    return (resolved: resolved, looksOffline: false);
  }

  /// 按 uri 找清单里的条目（uri 是本机文件的稳定标识，id 重扫会变）。
  LocalAudioEntry? entryByUri(String uri) {
    for (final list in [_local, _downloaded]) {
      for (final e in list) {
        if (e.uri == uri) return e;
      }
    }
    return null;
  }

  /// 某个 uri 换到的 songMid（取歌词的备胎身份）；没有则 null。
  String? songMidByUri(String uri) {
    final mid = entryByUri(uri)?.songMid;
    return (mid == null || mid.isEmpty) ? null : mid;
  }

  /// 申请音频权限。已授予就零成本返回 null。
  Future<String?> _ensureAudioPermission() async {
    final status = await Permission.audio.status;
    if (status.isGranted) return null;
    final asked = await Permission.audio.request();
    if (asked.isGranted) return null;
    // 永久拒绝与临时拒绝要给不同的话：前者再点一次也不会有系统弹窗，
    // 不说「去设置里开」就是死路一条。
    return asked.isPermanentlyDenied
        ? '音频权限被永久拒绝，请到系统设置里为 Audora 打开「音乐」访问权限'
        : '需要音频权限才能扫描手机里的歌曲';
  }
}
