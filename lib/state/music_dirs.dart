/// 「歌曲目录」偏好：本地扫描范围 + 下载落点（两项都通过 SAF 选择）。
///
/// ## 为什么单开一个模块
/// 这一组状态有三个自己独有的麻烦，跟音质/主题那种「存个值」的偏好不一样：
///   1. 存的 tree uri **可能失效**——用户能在系统设置里撤销授权，选中的目录
///      也可能被卸载/改名。所以每次启动都要问一次原生「还在不在」，
///      不能信本地存的那串字符串。
///   2. 只有 Android 有这件事，其它平台要退化成一个能显示、能解释的状态。
///   3. 拉起选择器是异步且可被中断的（界面切换、用户取消）。
/// 这三件事混进 AppState 只会让它更胖，所以照 [OnlineSearchBox] /
/// [GuessForYouBox] 的老例子拆出来（组合式拆分，**不是** part 文件）。
///
/// ## 两个目录为什么彻底分开
/// 「本地」是**扫描范围**（只读语义：从这里把手机里已有的歌找出来），
/// 「下载」是**写入位置**。混成一个的话，用户把下载目录设成 `/Music`，
/// 下次扫描就会把自己刚下的歌当成本机自带歌曲再收一遍——两批数据
/// 从此分不清。所以两个键、两条授权、两份状态，互不回退。
library;

import 'package:audora_files/audora_files.dart';

import '../services/diag/diag_log.dart';
import '../services/settings/settings_store.dart';

/// 目录种类。顺序即设置页里的展示顺序。
enum MusicDirKind { local, download }

class MusicDirsBox {
  MusicDirsBox({
    required SettingsStore? Function() settings,
    required void Function() onChange,
    AudoraFiles? files,
  })  : _settings = settings,
        _onChange = onChange,
        _files = files ?? const AudoraFiles();

  final SettingsStore? Function() _settings;
  final void Function() _onChange;
  final AudoraFiles _files;

  MusicDirectory? _local;
  MusicDirectory? _download;

  /// 正在向原生核对授权（启动时那一瞬，UI 显示「检查中」）
  bool _checking = false;

  /// 最近一次核对/选择得到的提示文案。null = 没有要说的。
  ///
  /// 刻意只留最后一条而不是队列：这类提示的用途是「解释当前状态」，
  /// 攒成一串历史反而盖掉现在真正该看的那句。
  String? _note;

  MusicDirectory? get local => _local;
  MusicDirectory? get download => _download;
  bool get checking => _checking;
  String? get note => _note;

  /// 下载落点是否真的可用（第三阶段的下载按钮据此决定能不能按）。
  bool get downloadUsable => (_download?.usable) ?? false;

  /// 本地扫描的路径前缀；null = 不过滤，扫手机全部音频。
  String? get localScanPath => _local?.posixPath;

  // ── 启动核对 ─────────────────────────────────────────────

  /// 把存下来的两个 uri 核对一遍。在 main.dart 里随曲库加载一起 unawaited 调用。
  Future<void> restore() async {
    final store = _settings();
    final localUri = store?.localDirUri ?? '';
    final downloadUri = store?.downloadDirUri ?? '';
    if (localUri.isEmpty && downloadUri.isEmpty) return;

    if (!_files.isSupported) {
      _note = '当前平台不支持系统目录，已保存的选择在本机无效';
      _onChange();
      return;
    }

    _checking = true;
    _onChange();
    try {
      final (local, localFail) = await _describeSafely(localUri);
      final (download, downloadFail) = await _describeSafely(downloadUri);
      _local = local;
      _download = download;
      // 顺序有讲究：先说「授权失效/不可写」这种还能救的状态，最后才是
      // 「问都没问到」的硬失败。
      _note = _staleNote(local, localUri, MusicDirKind.local) ??
          _staleNote(download, downloadUri, MusicDirKind.download) ??
          localFail ??
          downloadFail;
    } finally {
      _checking = false;
      _onChange();
    }
  }

  /// 返回 `(目录, 失败文案)`。uri 为空时两者都为 null（不算失败）。
  Future<(MusicDirectory?, String?)> _describeSafely(String uri) async {
    if (uri.isEmpty) return (null, null);
    try {
      return (await _files.describe(uri), null);
    } on Object catch (e) {
      // 提供方挂了 / uri 已废。显示状态留空，但原因要留住，
      // 否则用户只看到「未设置」，完全不记得自己设置过。
      return (null, '目录检查失败：$e');
    }
  }

  String? _staleNote(
    MusicDirectory? dir,
    String savedUri,
    MusicDirKind kind,
  ) {
    if (savedUri.isEmpty || dir == null) return null;
    if (!dir.granted) {
      return '「${labelOf(kind)}」的授权已失效，需要重新选择';
    }
    if (kind == MusicDirKind.download && !dir.writable) {
      return '「${labelOf(kind)}」报告不可写，下载可能失败';
    }
    return null;
  }

  // ── 选择 / 清除 ──────────────────────────────────────────

  /// 拉起 SAF 选择器换一个新目录。返回 null = 成功（或用户取消，静默）；
  /// 返回文案 = 需要告诉用户的结果，由 UI 用 SnackBar 呈现。
  ///
  /// ## 每一步都写诊断日志（2026-10-11）
  /// 「点了这一行什么也没发生」是这台魅族 21 上报过的真实故障，而那一次
  /// 原生只是回了一句「用户取消」（chooser 被系统秒关），界面上没有任何
  /// 痕迹。日志留痕后，同类问题在「我的 → 诊断日志」里一眼可见，不用再猜。
  Future<String?> pick(MusicDirKind kind) async {
    final store = _settings();
    if (store == null) return '设置存储未接入';
    // 先问能力，再依赖通道抛异常：Desktop/iOS 上「点了这一行」应当立刻有
    // 一句解释，而不是等一次必然失败的调用（那次调用在某些平台上根本
    // 不会有 MissingPluginException，而是永远不返回）。
    if (!_files.isSupported) {
      DiagLog.instance.i(DiagCategory.ui, '目录选择：本机不支持', {'dir': kind.name});
      return '当前平台不支持选择系统目录（仅 Android）';
    }

    final current = _of(kind);
    DiagLog.instance.d(
      DiagCategory.ui,
      '拉起系统目录选择器',
      {'dir': kind.name, 'initial': current?.uri ?? ''},
    );
    try {
      final picked = await _files.pickDirectory(
        reason: _pickerTitle(kind),
        initialUri: current?.uri,
      );
      if (picked == null) {
        // 用户取消，不是失败——但如果他根本没看见选择器，这条日志就是
        // 唯一能证明「原生回的是取消而不是界面没响应」的东西。
        DiagLog.instance.i(DiagCategory.ui, '目录选择：取消或未拉起', {'dir': kind.name});
        return null;
      }
      await _save(kind, picked.uri);
      // 内存状态直接收下这次选择：原生刚给的授权是**当下有效**的，
      // 而 persisted 标志只说明它能不能活到下次开机。不写这一步的话，
      // 「选完立刻用」这条路就断了（下载按钮仍然灰着）。
      if (kind == MusicDirKind.local) {
        _local = picked;
      } else {
        _download = picked;
      }
      _note = null;
      _onChange();
      DiagLog.instance.i(
        DiagCategory.ui,
        '目录已设置：${picked.name}',
        {
          'dir': kind.name,
          'posix': picked.posixPath ?? '',
          'granted': picked.granted,
          'writable': picked.writable,
          'persisted': picked.persisted,
        },
      );
      return _pickWarning(kind, picked);
    } on DirectoryPlatformUnsupported {
      return '当前平台不支持选择系统目录（仅 Android）';
    } on Object catch (e) {
      DiagLog.instance.e(DiagCategory.ui, '目录选择失败：$e', {'dir': kind.name});
      return '选择目录失败：$e';
    }
  }

  /// 取消这个目录：顺手把系统授权交回去，不留一条没人认领的持久化权限。
  Future<String?> clear(MusicDirKind kind) async {
    final uri = _of(kind)?.uri ?? '';
    await _save(kind, '');
    if (kind == MusicDirKind.local) {
      _local = null;
    } else {
      _download = null;
    }
    _note = null;
    _onChange();
    if (uri.isEmpty) return null;
    DiagLog.instance.i(DiagCategory.ui, '已清除目录设置', {'dir': kind.name});
    try {
      await _files.release(uri);
    } on Object {
      // 释放失败不值得报错：偏好已经清掉了，残留的授权在系统里看得见，
      // 用户真要收回去能在系统设置里做。这里抛出去只会让他以为没清掉。
    }
    return null;
  }

  /// 这一项当前有没有值。UI 用它决定「直接去选」还是「先问换/清」，
  /// 而不是去比对 trailing 的文案——文案是会改的，判断不该挂在上面。
  bool isSet(MusicDirKind kind) => _of(kind) != null;

  MusicDirectory? _of(MusicDirKind kind) =>
      kind == MusicDirKind.local ? _local : _download;

  Future<void> _save(MusicDirKind kind, String uri) async {
    final store = _settings();
    if (store == null) return;
    if (kind == MusicDirKind.local) {
      await store.setLocalDirUri(uri);
    } else {
      await store.setDownloadDirUri(uri);
    }
  }

  /// 选完之后需要提醒、但不必拒绝这次选择的情况。
  ///
  /// 不持久化的授权是真能用的（这次进程内），只是重启会掉。直接拒掉
  /// 会让用户卡在「选了又说不对」，不如收下 + 说清楚。
  String? _pickWarning(MusicDirKind kind, MusicDirectory dir) {
    if (!dir.persisted) {
      return '已选择「${dir.name}」，但该提供方不支持持久授权，重启后需重选';
    }
    if (kind == MusicDirKind.download && !dir.writable) {
      return '已选择「${dir.name}」，但系统报告它不可创建文件，下载可能失败';
    }
    if (kind == MusicDirKind.local && dir.posixPath == null) {
      return '已选择「${dir.name}」，该提供方没有本地路径，扫描范围仍按全盘';
    }
    return null;
  }

  // ── 给 UI 的文案 ─────────────────────────────────────────

  static String labelOf(MusicDirKind kind) =>
      kind == MusicDirKind.local ? '本地目录' : '下载目录';

  static String _pickerTitle(MusicDirKind kind) =>
      kind == MusicDirKind.local ? '选择要扫描的音乐文件夹' : '选择下载歌曲存放位置';

  /// 设置页右侧那一小串字。三种状态要分得开：没设、失效、可用。
  String trailingOf(MusicDirKind kind) {
    if (_checking) return '检查中…';
    final dir = _of(kind);
    if (dir == null) return kind == MusicDirKind.local ? '未设置（全盘）' : '未设置';
    if (!dir.granted) return '需重新授权';
    if (kind == MusicDirKind.download && !dir.writable) return '${dir.name} · 只读';
    return dir.name;
  }

  /// 设置页副标题：把这一项到底管什么说清楚。
  String subtitleOf(MusicDirKind kind) {
    final dir = _of(kind);
    switch (kind) {
      case MusicDirKind.local:
        return dir == null
            ? '扫描手机自带歌曲；不选就是全部音频'
            : '只扫 ${dir.posixPath ?? dir.name}';
      case MusicDirKind.download:
        return dir == null ? '下载前先选一个存放位置' : '下载到 ${dir.name}';
    }
  }
}
