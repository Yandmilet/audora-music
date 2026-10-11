/// 播放页的「下载」：一次点击 → 一条 CDN 流 → 一个落到 SAF 目录的文件。
///
/// ## 状态为什么放在这里而不是 widget 里
/// 下载是**跨页面**的：用户在播放页点了下载，然后退到列表、切到「我的」、
/// 甚至把 app 压到后台，传输都该继续，进度也该在他回来时看得见。放在
/// widget 的 setState 里，一翻页就没了。
///
/// ## 三种可见状态（用户明确要求的那个按钮）
///   未下载 → 「下载」
///   进行中 → 百分比（原生按 1% 变化回推）
///   已完成 → 「已下载」，再点变成「移除」而不是重复下载
/// 失败也是一种状态，但只在**当前这一页**说清楚（SnackBar），不长期挂在
/// 按钮上——挂着一条旧错误会让人以为现在还在失败。
///
/// ## 「已下载」这件事的唯一真相是清单
/// 不另开一份 `Set<int> downloadedIds`：那会和 `local_audio` 表对不上
/// （用户在文件管理器里删了文件、或换了设备）。按钮状态每次都从
/// [downloaded]（LocalLibraryBox 的下载清单）现算。
library;

import 'dart:async';

import 'package:audora_files/audora_files.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;

import '../data/db/dao/local_audio_dao.dart';
import '../data/repository/library_repository.dart';
import '../models/models.dart';
import '../services/diag/diag_log.dart';
import '../services/settings/settings_store.dart';
import 'music_dirs.dart';

/// 播放页按钮要显示的东西。
class DownloadUi {
  const DownloadUi({
    required this.label,
    required this.done,
    this.running = false,
    this.percent,
    this.enabled = true,
  });

  final String label;

  /// 已经下载好了（图标用「已下载」那个）
  final bool done;
  final bool running;

  /// 0~100；null = 提供方没给总长，只能显示转圈
  final int? percent;

  /// false = 现在按不动（比如还没设下载目录）
  final bool enabled;
}

/// 一次「按下载音质解析」的结果：要么给出可下流的地址，要么给出原因。
///
/// 定义在这里而不是直接吃 `ResolveResult`：DownloadBox 因此不需要知道
/// 播放器与解析器的存在（测试也就不必造一个真的 AudioPlayer——它会起
/// 2 秒周期的看门狗 Timer，在单测里是要命的东西）。
typedef DownloadTarget = ({String? url, int qualityId, String mime, String? error});

class DownloadBox {
  DownloadBox({
    required LibraryRepository? Function() repo,
    required Future<DownloadTarget> Function(Song song, int ceiling) resolve,
    required Map<String, String> Function() streamHeaders,
    required MusicDirsBox Function() dirs,
    required QualityPreference Function() downloadQuality,
    required List<LocalAudioEntry> Function() downloaded,
    required Future<void> Function() reloadDownloaded,
    required void Function() onChange,
    AudoraFiles? files,
    Stream<DownloadUpdate>? progress,

    /// 「解析下载地址」这一步的耐心上限。
    ///
    /// 必须限时：B站接口有 30 次/分钟的全局限流，一次 playurl 可能在
    /// RateLimiter 的队列里排队几十秒甚至更久；不限时 = 按钮一直「下载中」
    /// 而没有任何人在干活（2026-10-11 真机反馈就是这个状态）。
    this.resolveTimeout = const Duration(seconds: 90),

    /// 已经拿到 taskId 之后，「连续多久没有任何进度」算掉线。
    ///
    /// 判「静默」而不是判「总时长」：一条 60MB 的 Hi-Res 下多久都该被允许，
    /// 但**超过这个时间一个字都没回**基本就是原生把进度丢了（引擎 detach、
    /// 通道没人接），不能让界面无限期等下去。
    this.stallTimeout = const Duration(seconds: 60),

    /// 「把任务交给原生」这一步的耐心上限。
    ///
    /// 原生是**立即**回 taskId 的（真正的拷贝在后台线程），所以这里给的是
    /// 一个很紧的额度。以前这段没有超时：通道没人应答（插件 detach、引擎
    /// 切换）时 `await` 就永久挂着，`_current` 停在「准备中」，而看门狗是
    /// 拿到 taskId 之后才起的——等于没有任何出口（2026-10-11 排查时发现的
    /// 同类空档，顺手一起堵上）。
    this.submitTimeout = const Duration(seconds: 15),
  })  : _repo = repo,
        _resolve = resolve,
        _streamHeaders = streamHeaders,
        _dirs = dirs,
        _downloadQuality = downloadQuality,
        _downloaded = downloaded,
        _reloadDownloaded = reloadDownloaded,
        _onChange = onChange,
        _globalProgress = progress == null,
        _files = files ?? const AudoraFiles() {
    // 进度是原生按任务回推的广播流；订阅归本对象自己管（见 dispose）。
    // 注入自定义流（测试）时不去碰全局 MethodChannel——那条通道要
    // binding 先初始化，而且既然进度由外部喂，挂全局 handler 只是多余副作用。
    if (progress == null) DownloadUpdates.ensureAttached();
    _sub = (progress ?? DownloadUpdates.stream).listen(_onUpdate);
  }

  /// 进度是不是来自全局原生通道（false = 测试注入的流）。
  final bool _globalProgress;

  final LibraryRepository? Function() _repo;
  final Future<DownloadTarget> Function(Song, int) _resolve;
  final Map<String, String> Function() _streamHeaders;
  final MusicDirsBox Function() _dirs;
  final QualityPreference Function() _downloadQuality;
  final List<LocalAudioEntry> Function() _downloaded;
  final Future<void> Function() _reloadDownloaded;
  final void Function() _onChange;
  final AudoraFiles _files;
  final Duration resolveTimeout;
  final Duration stallTimeout;
  final Duration submitTimeout;

  /// songKey -> 在途任务。同一时刻只允许一首在下（原生也是单线程）。
  _Inflight? _current;

  /// 进度流的订阅句柄。dispose 时必须取消，否则回调会打到已死的对象上。
  late final StreamSubscription<DownloadUpdate> _sub;

  /// 掉线看门狗（见 [stallTimeout]）。任何一条进度事件、任何一次终态都要喂/停。
  Timer? _watchdog;

  void dispose() {
    _watchdog?.cancel();
    _watchdog = null;
    _sub.cancel();
  }

  // ── 查询 ────────────────────────────────────────────────

  LocalAudioEntry? fileOf(Song song) {
    final id = song.id;
    if (id == null) return null;
    for (final e in _downloaded()) {
      if (e.songId == id) return e;
    }
    return null;
  }

  bool isDownloaded(Song song) => fileOf(song) != null;

  /// 播放页那个按钮该显示成什么样。
  DownloadUi uiOf(Song song) {
    if (isDownloaded(song)) {
      return const DownloadUi(label: '已下载', done: true);
    }
    final t = _current;
    if (t != null && t.songKey == song.key) {
      if (t.failed) return const DownloadUi(label: '重试', done: false);
      return DownloadUi(
        // 没拿到 taskId 说明还在「解析地址」，写「准备中」而不是「下载中」——
        // 用户看到「下载中」却半天不动，第一反应是下载坏了；说清楚在哪一步，
        // 才知道那其实是接口在排队（点第二下取消现在也是有效的）。
        label: t.taskId == null
            ? '准备中'
            : (t.percent == null ? '下载中' : '${t.percent}%'),
        done: false,
        running: true,
        percent: t.percent,
      );
    }
    if (t != null) {
      // 别的歌正在下：这一首按了也是排队，不如先不让按
      return const DownloadUi(
        label: '下载',
        done: false,
        enabled: false,
      );
    }
    return const DownloadUi(label: '下载', done: false);
  }

  // ── 状态收尾 ────────────────────────────────────────────

  /// 清掉在途任务并通知 UI（**唯一**的出口，所有失败/取消分支都走这里）。
  ///
  /// 停看门狗和清状态绑在一起，是为了不再出现「状态清了、狗还在跑」
  /// 「狗停了、状态还挂着下载中」这种半边干净——真机上那个永久的
  /// 「下载中」就是某条失败路径没走统一出口留下的。
  void _clear() {
    _watchdog?.cancel();
    _watchdog = null;
    _current = null;
    _onChange();
  }

  /// 「一句都没开始」的出口：把原因写进诊断日志，再原样交回调用方弹 SnackBar。
  ///
  /// ## 为什么每条早退都必须留一行
  /// 用户那边看到的只是一句 SnackBar，划过去就没了；事后从电脑上判断
  /// 「到底死在哪一步」全靠这条日志。以前这些早退是**静默**的，于是真机日志
  /// 上「下载受理」之后一片空白，分不清是解析没回、还是解析回了个原因
  /// （2026-10-11 排查时就被这条坑了一轮）。
  /// 注意它**不清状态**：拒绝另一首歌的请求时，不能顺手把在途任务抹掉。
  String _refuse(String why, Song song, {String stage = ''}) {
    DiagLog.instance.w(
      DiagCategory.playback,
      '下载未开始${stage.isEmpty ? '' : '（$stage）'}：$why',
      {'event': 'download_refused', 'song': song.key, 'stage': stage},
    );
    return why;
  }

  /// 喂狗：从现在开始再等 [stallTimeout]，超时没进度就判失败。
  void _feedWatchdog() {
    _watchdog?.cancel();
    final t = _current;
    final taskId = t?.taskId;
    final songKey = t?.songKey;
    if (t == null || taskId == null || songKey == null) return;
    _watchdog = Timer(stallTimeout, () => _onStall(songKey, taskId));
  }

  void _onStall(String songKey, String taskId) {
    final t = _current;
    if (t == null || t.taskId != taskId) return; // 已经结束或换人了
    _watchdog = null;
    _current = t.copyWith(failed: true, percent: null);
    _onChange();
    DiagLog.instance.e(
      DiagCategory.playback,
      '下载 $taskId 连续 ${stallTimeout.inSeconds}s 没有任何进度，判失败',
      {'event': 'download_stall', 'taskId': taskId, 'song': songKey},
    );
    // 顺手让原生把那条僵尸任务停掉（它自己会删半成品）。失败不打扰用户：
    // 界面上已经是「重试」了，这里再报一次只会重复。
    unawaited(() async {
      try {
        await _files.cancelDownload(taskId);
      } on Object {
        // 任务其实早就结束了（no_task）——正合预期
      }
    }());
  }

  // ── 动作 ────────────────────────────────────────────────

  /// 开始下载。返回 null = 已受理；返回文案 = 一句都没开始的原因。
  ///
  /// ## 每一条路径都必须落到「有结果」
  /// 旧实现只在 `_files.startDownload` 外面包了 try，而**解析地址**那一步
  /// 既没有 try 也没有超时：它一抛异常，`_current` 就永久挂着，按钮停在
  /// 「下载中」再也点不动（用户 2026-10-11 报的正是这个）。现在解析、发起
  /// 两段各自有 try/timeout，异常与超时一律清状态并回一句人话。
  Future<String?> start(Song song) async {
    final repo = _repo();
    if (repo == null) return _refuse('数据层未接入', song);
    if (song.id == null) return _refuse('这首歌还没入库，先播一次再下载', song);
    if (_current != null) return _refuse('已经有一个下载在进行了', song);
    if (isDownloaded(song)) {
      // 已经是「已下载」了还按：不是错误，但也得在日志里留一句，
      // 否则真机上看到的又是「点了没反应」。
      DiagLog.instance.i(
        DiagCategory.playback,
        '下载已受理（其实早就下好了）：${song.title}',
        {'event': 'download_already_done', 'songId': song.id},
      );
      return null;
    }

    final dirs = _dirs();
    final dest = dirs.download;
    if (dest == null || !dest.usable) {
      return _refuse('先去「我的 → 歌曲目录 → 下载目录」选一个存放位置', song);
    }

    // 通道自检。进度回推是「下完了」这件事唯一的信源：它一丢，表现就是
    // 文件早就完整落盘、按钮却永远停在「下载中」（release 上真发生过，
    // 根因见 DownloadUpdates.ensureAttached 的注释）。这里顺手再试一次
    // 挂载（覆盖 binding 晚于本对象构造的情形），仍挂不上就把这句话留在
    // 诊断日志里——下次真机直接看到根因，不用再看门狗超时反推。
    if (_globalProgress && _files.isSupported && !DownloadUpdates.ensureAttached()) {
      DiagLog.instance.e(
        DiagCategory.playback,
        '下载进度通道未能挂载：原生回推会全部丢失，按钮会卡在「下载中」',
        {'event': 'download_channel_not_attached'},
      );
    }

    _current = _Inflight(songKey: song.key, stage: '解析地址');
    _onChange();
    DiagLog.instance.i(
      DiagCategory.playback,
      '下载受理：${song.title}',
      {'event': 'download_start', 'songId': song.id, 'dest': dest.name},
    );

    final DownloadTarget target;
    try {
      target = await _resolve(song, _downloadQuality().id).timeout(resolveTimeout);
    } on TimeoutException {
      _clear();
      DiagLog.instance.e(
        DiagCategory.playback,
        '下载解析地址超时（${resolveTimeout.inSeconds}s）：${song.title}',
        {'event': 'download_resolve_timeout', 'songId': song.id},
      );
      return '解析下载地址超时（接口在限流排队），稍后再试';
    } on Object catch (e) {
      _clear();
      DiagLog.instance.e(
        DiagCategory.playback,
        '下载解析地址异常：$e',
        {'event': 'download_resolve_fail', 'songId': song.id},
      );
      return '解析下载地址失败：$e';
    }

    if (target.url == null || target.url!.isEmpty) {
      // 这条分支以前**只弹 SnackBar 不写日志**：真机上「受理」之后一片空白，
      // 谁也不知道解析是返回了原因还是根本没回（2026-10-11 排查时被坑了一次）。
      _clear();
      return _refuse(target.error ?? '拿不到下载地址', song, stage: '解析地址');
    }

    final name = _fileName(song, target.mime);
    try {
      final taskId = await _files
          .startDownload(
            url: target.url!,
            destUri: dest.uri,
            fileName: name,
            headers: _streamHeaders(),
            mime: target.mime,
          )
          .timeout(submitTimeout);
      _current = _Inflight(
        songKey: song.key,
        taskId: taskId,
        stage: '传输',
        qualityId: target.qualityId,
        song: song,
      );
      _feedWatchdog();
      _onChange();
      DiagLog.instance.i(
        DiagCategory.playback,
        '原生已接单：$taskId → $name',
        {'event': 'download_accepted', 'taskId': taskId, 'qualityId': target.qualityId},
      );
      return null;
    } on TimeoutException {
      _clear();
      return _refuse(
        '原生没有应答这次下载请求（${submitTimeout.inSeconds}s），稍后再试',
        song,
        stage: '发起',
      );
    } on DirectoryPlatformUnsupported {
      _clear();
      return _refuse('当前平台不支持下载到本机文件（仅 Android）', song, stage: '发起');
    } on Object catch (e) {
      _clear();
      DiagLog.instance.e(
        DiagCategory.playback,
        '发起下载失败：$e',
        {'event': 'download_submit_fail', 'song': song.title},
      );
      return '发起下载失败：$e';
    }
  }

  /// 清掉失败标记（点「重试」时先调）。
  ///
  /// 为什么失败要留一个标记而不是立刻清空回原样：立刻清空的话，用户看到的
  /// 是「点了没反应」；留着才能把按钮变成「重试」，一眼就知道刚才没成。
  Future<void> resetFailed() async {
    if (_current?.failed ?? false) _clear();
  }

  /// 取消一个在途任务。用户按第二下就是这个（按钮上写着百分比，点了该能停）。
  ///
  /// ## 本地先清，不等原生回 canceled
  /// 旧写法把清态完全交给原生的 canceled 回推——那条回推一旦丢（引擎
  /// detach、进度通道没人接、任务其实已经结束），按钮就永远停在「下载中」
  /// 且点不动。现在本地立刻落回空闲，原生那边只负责删半成品。
  Future<String?> cancel() async {
    final t = _current;
    if (t == null) return null;
    final taskId = t.taskId;
    if (taskId == null) {
      _clear();
      DiagLog.instance.i(
        DiagCategory.playback,
        '下载在解析阶段被取消',
        {'event': 'download_cancel_before_task'},
      );
      return '已取消（还没开始传输）';
    }
    _clear();
    try {
      await _files.cancelDownload(taskId);
    } on Object catch (e) {
      return '停止传输的请求没送出去：$e';
    }
    DiagLog.instance.i(
      DiagCategory.playback,
      '下载已取消：$taskId',
      {'event': 'download_canceled', 'taskId': taskId},
    );
    return '已取消下载';
  }

  /// 移除已下载：删文件 + 删记录。两步任何一步失败都要说出来。
  Future<String?> remove(Song song) async {
    final repo = _repo();
    final file = fileOf(song);
    if (repo == null || file == null) return null;
    try {
      await _files.deleteFile(file.uri);
    } on PlatformException catch (e) {
      // 文件已经被用户在文件管理器里删掉了：记录照样清掉，
      // 否则清单里永远挂着一首点不动的歌。
      if (e.code != 'delete_failed') return '删除文件失败：${e.message}';
    } on DirectoryPlatformUnsupported {
      return '当前平台不支持删除本机文件（仅 Android）';
    }
    await repo.removeLocalAudio(file.id ?? 0);
    await _reloadDownloaded();
    return null;
  }

  // ── 原生回推 ────────────────────────────────────────────

  /// 处理一条进度/结果事件。流回调走这里，测试也直接 await 这里。
  ///
  /// 为什么要单独暴露：done 分支要落库（sqflite 在真机与单测里都是
  /// **isolate 异步**完成），靠「等几个零延迟」去撞它是不可靠的——
  /// 单测里实测会撞出 tearDown 关库之后才回写的 `database_closed`。
  @visibleForTesting
  Future<void> handleUpdate(DownloadUpdate u) => _onUpdate(u);

  Future<void> _onUpdate(DownloadUpdate u) async {
    final t = _current;
    if (t == null || t.taskId != u.taskId) return; // 过期事件：任务已换人
    // 收到任何一条事件都说明原生还活着，但只有未结束的任务才需要继续等
    if (!u.isTerminal) {
      _feedWatchdog();
    } else {
      _watchdog?.cancel();
      _watchdog = null;
    }

    switch (u.status) {
      case DownloadStatus.running:
        _current = t.copyWith(percent: u.percent, failed: false);
        _onChange();
        return;
      case DownloadStatus.canceled:
        // 原生自己报的取消（引擎 detach 时它会把手上的任务全标取消）。
        // 这里以前什么都不写——于是日志上「受理」之后凭空消失，看着像卡死。
        DiagLog.instance.w(
          DiagCategory.playback,
          '下载被原生报为已取消：${u.taskId}',
          {'event': 'download_canceled_by_native', 'taskId': u.taskId},
        );
        _current = null;
        _onChange();
        return;
      case DownloadStatus.failed:
        // 留在「失败」态一小会儿，让按钮变成「重试」而不是无声变回原样
        _current = t.copyWith(failed: true, percent: null);
        _onChange();
        DiagLog.instance.e(
          DiagCategory.playback,
          '下载失败：${u.error ?? '未知原因'}',
          {'event': 'download_failed', 'taskId': u.taskId},
        );
        return;
      case DownloadStatus.done:
        final song = t.song;
        final uri = u.uri;
        _current = null;
        DiagLog.instance.i(
          DiagCategory.playback,
          '下载完成：${u.name ?? ''} ${(u.size / 1024 / 1024).toStringAsFixed(1)}MB',
          {'event': 'download_done', 'taskId': u.taskId, 'uri': uri ?? ''},
        );
        if (song != null && uri != null) {
          final repo = _repo();
          if (repo != null) {
            await repo.saveLocalAudio(
              LocalAudioEntry(
                kind: LocalAudioKind.download,
                uri: uri,
                title: song.title,
                artist: song.artist,
                album: song.album,
                durationMs: song.duration * 1000,
                sizeBytes: u.size,
                mtimeSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                songId: song.id,
                qualityId: t.qualityId,
              ),
            );
            await _reloadDownloaded();
          }
        }
        _onChange();
        return;
    }
  }

  /// 落盘文件名：`歌名 - 歌手.m4a`。
  ///
  /// 必须过一遍清洗：SAF 提供方对 `/`、`:`、尾部空格的处理各不相同，
  /// 一个非法字符会让 createDocument 静默返回 null（原生那边就会报
  /// 「目标目录不允许创建文件」，而真正的原因在文件名上）。
  static String _fileName(Song song, String mime) {
    final base = '${song.title} - ${song.artist}';
    final cleaned = base
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final cut = cleaned.length > 90 ? cleaned.substring(0, 90).trim() : cleaned;
    return '$cut${_extOf(mime)}';
  }

  static String _extOf(String mime) => switch (mime) {
        'audio/mpeg' => '.mp3',
        'audio/aac' => '.aac',
        'audio/ogg' => '.ogg',
        'audio/flac' => '.flac',
        _ => '.m4a', // B站 DASH 音频（audio/mp4）
      };
}

class _Inflight {
  const _Inflight({
    required this.songKey,
    this.taskId,
    this.stage = '',
    this.percent,
    this.failed = false,
    this.qualityId = 0,
    this.song,
  });

  final String songKey;
  final String? taskId;
  final String stage;
  final int? percent;
  final bool failed;
  final int qualityId;
  final Song? song;

  _Inflight copyWith({
    int? percent,
    bool? failed,
    String? stage,
  }) =>
      _Inflight(
        songKey: songKey,
        taskId: taskId,
        stage: stage ?? this.stage,
        percent: percent ?? this.percent,
        failed: failed ?? this.failed,
        qualityId: qualityId,
        song: song,
      );
}
