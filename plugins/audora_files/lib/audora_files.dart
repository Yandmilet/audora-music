/// `audora/files` 平台通道的 Dart 侧封装。
///
/// 只做三件事：把原生返回的 Map 变成 [MusicDirectory]、把「不是 Android」
/// 和「原生没实现」区分开、以及给测试留一个可注入的通道。
///
/// ## 为什么每个方法都要挡 [MissingPluginException]
/// 这个插件只有 Android 实现。桌面（开发时跑 Windows 看 UI）与未来可能的
/// iOS 上调用会抛 MissingPluginException——那不该是红屏崩溃，而是一个
/// 「本机不支持」的正常状态：设置页照样显示这一行，副标题说清不支持。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 一个 SAF 目录（tree uri）的快照。
class MusicDirectory {
  const MusicDirectory({
    required this.uri,
    required this.name,
    this.posixPath,
    this.granted = false,
    this.exists = false,
    this.writable = false,
    this.persisted = false,
  });

  /// `content://com.android.externalstorage.documents/tree/primary%3AMusic`
  final String uri;

  /// 给用户看的名字（`Music` / `Download`）
  final String name;

  /// 对应的真实路径（`/storage/emulated/0/Music`）。非外部存储提供方为 null，
  /// 此时没法按目录过滤 MediaStore，只能降级成「扫全盘」。
  final String? posixPath;

  /// 当前是否仍持有读+写授权（用户在系统设置里撤销就是 false）
  final bool granted;

  final bool exists;

  /// 提供方声明支持在此创建文件（下载能不能落到这个目录）
  final bool writable;

  /// 授权是否已持久化（重启后仍有效）。只有刚选完那一刻是精确值。
  final bool persisted;

  /// 能不能实际用来存东西
  bool get usable => granted && exists && writable;

  factory MusicDirectory.fromMap(Map<Object?, Object?> m) => MusicDirectory(
        uri: (m['uri'] ?? '') as String,
        name: ((m['name'] ?? '') as String).isEmpty
            ? '已选目录'
            : m['name'] as String,
        posixPath: m['posixPath'] as String?,
        granted: (m['granted'] as bool?) ?? false,
        exists: (m['exists'] as bool?) ?? false,
        writable: (m['writable'] as bool?) ?? false,
        persisted: (m['persisted'] as bool?) ?? ((m['granted'] as bool?) ?? false),
      );

  @override
  String toString() => 'MusicDirectory($name, $uri, usable=$usable)';
}

/// MediaStore 里的一条音频。字段刻意贴近原生返回值，不做领域加工——
/// 领域模型在 app 侧（`LocalTrack`），插件只负责「把系统给的搬过来」。
class AudioFileEntry {
  const AudioFileEntry({
    required this.mediaId,
    required this.uri,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.sizeBytes,
    required this.dateAddedSec,
    this.path,
  });

  /// MediaStore 行号。它同时是 `uri` 的一部分，设备重启后仍指向同一条记录
  /// （除非用户手动删除或清空媒体库）。
  final int mediaId;

  /// `content://media/external/audio/media/<id>` —— 播放用这个，
  /// 不要拿 [path] 去 open 文件：分区存储下那条路径可能没有读权限。
  final String uri;

  final String? path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int sizeBytes;

  /// MediaStore 的 `DATE_ADDED`（秒）。注意它常被导入工具写成任意值，
  /// 只能当参考，不能当「这首歌什么时候进的手机」的真相。
  final int dateAddedSec;

  factory AudioFileEntry.fromMap(Map<Object?, Object?> m) => AudioFileEntry(
        mediaId: (m['mediaId'] as num?)?.toInt() ?? 0,
        uri: (m['uri'] ?? '') as String,
        path: m['path'] as String?,
        title: (m['title'] ?? '') as String,
        artist: (m['artist'] ?? '') as String,
        album: (m['album'] ?? '') as String,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
        dateAddedSec: (m['dateAddedSec'] as num?)?.toInt() ?? 0,
      );
}

/// 下载任务的四个终态/中间态。
enum DownloadStatus { running, done, failed, canceled }

/// 一条下载进度/结果。
class DownloadUpdate {
  const DownloadUpdate({
    required this.taskId,
    required this.status,
    this.done = 0,
    this.total = 0,
    this.uri,
    this.name,
    this.size = 0,
    this.error,
  });

  final String taskId;
  final DownloadStatus status;
  final int done;
  final int total;

  /// 完成后回指的文档 uri（只有 done 才有）
  final String? uri;

  /// 提供方实际落盘的文件名（重名时会变，比如「晴天 (1).m4a」）
  final String? name;
  final int size;

  /// 失败原因
  final String? error;

  bool get isTerminal => status != DownloadStatus.running;

  /// 0~100；提供方没给 Content-Length 时为 null（界面就该显示转圈而不是百分比）。
  int? get percent =>
      total > 0 ? (done * 100 / total).round().clamp(0, 100) : null;

  factory DownloadUpdate.fromMap(Map<Object?, Object?> m) => DownloadUpdate(
        taskId: (m['taskId'] ?? '') as String,
        status: switch (m['status']) {
          'done' => DownloadStatus.done,
          'failed' => DownloadStatus.failed,
          'canceled' => DownloadStatus.canceled,
          _ => DownloadStatus.running,
        },
        done: (m['done'] as num?)?.toInt() ?? 0,
        total: (m['total'] as num?)?.toInt() ?? 0,
        uri: m['uri'] as String?,
        name: m['name'] as String?,
        size: (m['size'] as num?)?.toInt() ?? 0,
        error: m['error'] as String?,
      );
}

/// 下载进度的单订阅广播。
///
/// ## 为什么是 Stream 而不是直接把回调注册到 MethodChannel 上
/// MethodChannel 的 handler 是**全局唯一**的：谁后注册谁覆盖前一个。
/// 直接让 DownloadBox 去 setMethodCallHandler，两个 AppState 交替存活时
/// （界面重建、测试并行）就会出现「进度推给了一个已经不该存在的盒子」。
/// 这里把它收成一个广播流，订阅者各自持有可取消的 StreamSubscription，
/// 生命周期回到对象自己身上；测试也能塞进自己的 controller。
class DownloadUpdates {
  DownloadUpdates._();

  static final StreamController<DownloadUpdate> _ctl =
      StreamController<DownloadUpdate>.broadcast();

  static Stream<DownloadUpdate> get stream => _ctl.stream;

  static bool _attached = false;

  /// binding 是否已经初始化到「能在通道上注册 handler」。
  ///
  /// **不要用 `BindingBase.debugBindingType()` 来判**：那个值是在
  /// `assert(() { ... return true; }())` 里赋的（flutter 的
  /// `BindingBase.initInstances`），而 release 包会把 assert 整块剥掉——
  /// 于是它在**任何 release 构建里都恒返回 null**，哪怕 binding 早就初始化
  /// 好了。上一版正是拿它当守卫，结果 release 装机后这条通道的 handler
  /// 一次都没挂上：原生每条进度/完成都被 MissingPluginException 吃掉，
  /// 界面停在「下载中」，而文件其实几秒就完整落盘了
  /// （2026-10-11 真机：三次下载全部 8,095,489 字节写完却零回推）。
  ///
  /// `ServicesBinding.instance` 三种模式都成立：真没有 binding 时 debug 抛
  /// FlutterError、release 走 `instance!` 抛 TypeError，两者都是 Object。
  static bool get _bindingReady {
    try {
      ServicesBinding.instance;
      return true;
    } on Object {
      return false;
    }
  }

  /// 把原生通道接到广播流上。幂等——重复调用不会装第二个 handler。
  ///
  /// 返回 true = handler 现在挂在这条通道上（本次挂的，或之前就挂好了）。
  /// **没有 binding 时返回 false 且不记 `_attached`**：纯 Dart 单测（构造一个
  /// AppState 看看状态、不起界面）就是这种情况，那里本来也不会有原生进度事件；
  /// 等 binding 出现后下一次调用还会再试，不会被一次「太早」永久否掉。
  static bool ensureAttached() {
    if (_attached) return true;
    if (!_bindingReady) return false;
    _attached = true;
    AudoraFiles.setProgressHandler((u) {
      if (!_ctl.isClosed) _ctl.add(u);
    });
    return true;
  }
}

/// 平台不支持（非 Android）。与「用户取消」「授权失效」区分开，
/// UI 才能给出各自该给的话。
class DirectoryPlatformUnsupported implements Exception {
  const DirectoryPlatformUnsupported();

  @override
  String toString() => '当前平台不支持选择系统目录（仅 Android 可用）';
}

class AudoraFiles {
  const AudoraFiles({MethodChannel? channel})
      : _channel = channel ?? methodChannel;

  /// 暴露出去给测试挂 mock handler 用。
  static const MethodChannel methodChannel = MethodChannel('audora/files');

  final MethodChannel _channel;

  /// 当前平台是否有这个能力（只有 Android）。
  ///
  /// 故意做成**实例** getter 而不是静态：测试里要能造一个
  /// 「假装在 Android 上」的假插件，否则所有分支都得靠条件导入绕。
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 拉起系统目录选择器。用户取消返回 null。
  ///
  /// [initialUri] 让选择器从上次的目录打开；传过期 uri 时原生侧会退化到
  /// 存储根（部分厂商 ROM 对非法 initialUri 会直接崩在选择器里）。
  Future<MusicDirectory?> pickDirectory({
    String? reason,
    String? initialUri,
  }) async {
    final raw = await _invoke<Map<Object?, Object?>>(
      'pickDirectory',
      {'reason': reason, 'initialUri': initialUri},
    );
    if (raw == null) return null;
    return MusicDirectory.fromMap(raw);
  }

  /// 复查一个已存的 uri 还能不能用。原生返回 null 表示 uri 不合法。
  Future<MusicDirectory?> describe(String uri) async {
    if (uri.isEmpty) return null;
    final raw = await _invoke<Map<Object?, Object?>>(
      'describeDirectory',
      {'uri': uri},
    );
    return raw == null ? null : MusicDirectory.fromMap(raw);
  }

  /// 系统当前真正持有持久化授权的目录。
  ///
  /// 设置里存的 uri 与这里的差集，就是「用户在系统设置里撤销了授权」——
  /// 这个事实只能问系统，本地存的那份字符串说明不了任何事。
  Future<List<MusicDirectory>> listDirectories() async {
    final raw = await _invoke<List<Object?>>(
      'listDirectories',
      const <String, Object?>{},
    );
    if (raw == null) return const [];
    return [
      for (final e in raw)
        if (e is Map<Object?, Object?>) MusicDirectory.fromMap(e),
    ];
  }

  Future<void> release(String uri) =>
      _invoke<Object?>('releaseDirectory', {'uri': uri});

  /// 扫描手机自带音频（MediaStore）。
  ///
  /// [pathPrefix] 来自「本地目录」设置（SAF tree uri 换算出来的真实路径）。
  /// 传 null 就是不设限、扫全盘。缺权限时原生抛 `PlatformException`
  /// （code `need_permission`），由上层翻译成用户看得懂的话——
  /// 不能返回空列表了事，那等于把「没被允许看」谎报成「没有歌」。
  Future<List<AudioFileEntry>> scanAudio({String? pathPrefix}) async {
    final raw = await _invoke<List<Object?>>(
      'audioTracks',
      {'pathPrefix': pathPrefix},
    );
    if (raw == null) return const [];
    return [
      for (final e in raw)
        if (e is Map<Object?, Object?>) AudioFileEntry.fromMap(e),
    ];
  }

  /// 统一挡 MissingPluginException。
  ///
  /// 注意只挡「插件没实现」这一种。PlatformException（选择器打不开、
  /// 界面被切走）必须往上抛，让调用方把原因显示出来——吞掉的错误在
  /// 用户那边就变成「点了没反应」，比报错更难查。
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const DirectoryPlatformUnsupported();
    } on PlatformException {
      rethrow;
    }
  }

  // ── 下载 ─────────────────────────────────────────────────

  /// 原生 → Dart 的进度通道。
  static const MethodChannel progressChannel =
      MethodChannel('audora/files/progress');

  /// 注册（或注销）进度回调。
  ///
  /// 传 null 注销。同一时刻只允许一个订阅者——下载状态由单一的
  /// `DownloadBox` 统一持有，多个监听者各存一份进度必然对不上。
  static void setProgressHandler(void Function(DownloadUpdate update)? handler) {
    if (handler == null) {
      progressChannel.setMethodCallHandler(null);
      return;
    }
    progressChannel.setMethodCallHandler((call) async {
      if (call.method != 'download') return null;
      final args = call.arguments;
      if (args is Map<Object?, Object?>) {
        handler(DownloadUpdate.fromMap(args));
      }
      return null;
    });
  }

  /// 起一个下载任务，立刻返回 taskId（拷贝在原生后台线程继续）。
  ///
  /// [headers] 是拉流必需的请求头（B站要 Referer / UA）——由 Dart 侧的源
  /// 适配器给，原生不硬编码任何平台的头。
  Future<String> startDownload({
    required String url,
    required String destUri,
    required String fileName,
    Map<String, String> headers = const {},
    String mime = 'application/octet-stream',
  }) async {
    final raw = await _invoke<Map<Object?, Object?>>('startDownload', {
      'url': url,
      'destUri': destUri,
      'fileName': fileName,
      'headers': headers,
      'mime': mime,
    });
    final id = raw?['taskId'] as String?;
    if (id == null || id.isEmpty) {
      throw const DownloadFailure('原生没有返回任务号');
    }
    return id;
  }

  /// 取消一个在途任务。任务已经结束时原生报 no_task，这里吞掉——
  /// 调用方要的效果（别再往下写）已经达到了。
  Future<void> cancelDownload(String taskId) async {
    try {
      await _invoke<Object?>('cancelDownload', {'taskId': taskId});
    } on PlatformException catch (e) {
      if (e.code == 'no_task') return;
      rethrow;
    }
  }

  /// 删掉一个下载文件。失败要抛出去：文件没删掉却说「已移除」，
  /// 用户下次在文件管理器里看见它只会更困惑。
  Future<void> deleteFile(String uri) =>
      _invoke<Object?>('deleteFile', {'uri': uri});
}

/// 下载发起阶段的失败（还没开始传字节）。
class DownloadFailure implements Exception {
  const DownloadFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
