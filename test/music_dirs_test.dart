/// 「歌曲目录」（本地扫描范围 / 下载落点）这两项偏好的行为测试。
///
/// ## 为什么值得单独测
/// 这一组状态的难点不在「存了个字符串」，而在**字符串不代表能力**：
/// 用户能在系统设置里撤销 SAF 授权、提供方可能给不了持久化权限、非 Android
/// 根本没有这个通道。三种情况都得落到不同的话术上，而不是统一显示「未设置」
/// ——那会让人完全不记得自己设置过什么。
///
/// 平台通道用 [_FakeFiles] 假实现（[AudoraFiles] 的方法都可覆写），
/// 因此这里跑的是真·Dart 逻辑，不需要设备。原生那半边的正确性由
/// `flutter build apk` 的编译 + 真机冒烟负责。
library;

import 'package:audora_files/audora_files.dart';
import 'package:audora_music/services/settings/settings_store.dart';
import 'package:audora_music/state/music_dirs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _music = 'content://com.android.externalstorage.documents/tree/primary%3AMusic';
const _dl = 'content://com.android.externalstorage.documents/tree/primary%3AAudora';

class _FakeFiles extends AudoraFiles {
  _FakeFiles({
    this.supported = true,
    this.nextPick,
    this.pickError,
    this.describeFor,
    this.describeError,
  });

  final bool supported;

  /// pickDirectory 的返回值（null = 用户取消）
  final MusicDirectory? nextPick;
  final Object? pickError;

  /// describe 的返回值 / 抛出的异常
  final MusicDirectory? Function(String uri)? describeFor;
  final Object? describeError;

  final List<String?> pickInitial = [];
  final List<String> described = [];
  final List<String> released = [];

  @override
  bool get isSupported => supported;

  @override
  Future<MusicDirectory?> pickDirectory({
    String? reason,
    String? initialUri,
  }) async {
    pickInitial.add(initialUri);
    if (pickError != null) throw pickError!;
    return nextPick;
  }

  @override
  Future<MusicDirectory?> describe(String uri) async {
    described.add(uri);
    if (describeError != null) throw describeError!;
    return describeFor?.call(uri);
  }

  @override
  Future<List<MusicDirectory>> listDirectories() async => const [];

  @override
  Future<void> release(String uri) async => released.add(uri);
}

MusicDirectory _dir(
  String uri, {
  required String name,
  String? posix,
  bool granted = true,
  bool exists = true,
  bool writable = true,
  // 默认「能持久化」——那是绝大多数提供方的正常情况，
  // 特例（重启会掉）在需要的那条用例里单独造。
  bool persisted = true,
}) =>
    MusicDirectory(
      uri: uri,
      name: name,
      posixPath: posix,
      granted: granted,
      exists: exists,
      writable: writable,
      persisted: persisted,
    );

Future<SettingsStore> _store([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  return SettingsStore.fromPrefs(await SharedPreferences.getInstance());
}

Future<MusicDirsBox> _box(
  SettingsStore store,
  AudoraFiles files,
) async {
  var changed = 0;
  final box = MusicDirsBox(
    settings: () => store,
    onChange: () => changed++,
    files: files,
  );
  return box;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('未设置时的诚实状态', () {
    test('restore 什么都不问', () async {
      final files = _FakeFiles();
      final box = await _box(await _store(), files);

      await box.restore();

      expect(files.described, isEmpty, reason: '没存过就不该去打搅原生');
      expect(box.local, isNull);
      expect(box.download, isNull);
      expect(box.note, isNull);
    });

    test('两行的文案分得开：本地=全盘，下载=未设置', () async {
      final box = await _box(await _store(), _FakeFiles());
      await box.restore();

      expect(box.isSet(MusicDirKind.local), isFalse);
      expect(box.trailingOf(MusicDirKind.local), '未设置（全盘）');
      expect(box.trailingOf(MusicDirKind.download), '未设置');
      // 下载没目录时不能用（第三阶段的下载按钮据此置灰）
      expect(box.downloadUsable, isFalse);
      expect(box.localScanPath, isNull);
    });
  });

  group('启动核对：存过 ≠ 还能用', () {
    test('授权被用户在系统里撤销 → 文案是「需重新授权」而不是「未设置」',
        () async {
      final files = _FakeFiles(
        describeFor: (uri) => _dir(uri, name: 'Music', granted: false),
      );
      final box = await _box(
        await _store({'local_dir_uri': _music}),
        files,
      );

      await box.restore();

      expect(files.described, [_music]);
      expect(box.isSet(MusicDirKind.local), isTrue,
          reason: '要保留「用户选过」这个事实，才能显示失效原因');
      expect(box.trailingOf(MusicDirKind.local), '需重新授权');
      expect(box.note, contains('授权已失效'));
    });

    test('下载目录不可写 → 记下来，并给出可操作的提示', () async {
      final files = _FakeFiles(
        describeFor: (uri) => _dir(uri, name: 'Audora', writable: false),
      );
      final box = await _box(
        await _store({'download_dir_uri': _dl}),
        files,
      );

      await box.restore();

      expect(box.downloadUsable, isFalse);
      expect(box.trailingOf(MusicDirKind.download), 'Audora · 只读');
      expect(box.note, contains('不可写'));
    });

    test('可写的下载目录才算 usable；本地目录不看 writable', () async {
      final files = _FakeFiles(
        describeFor: (uri) => uri == _music
            ? _dir(uri, name: 'Music', writable: false, posix: '/x/Music')
            : _dir(uri, name: 'Audora', posix: '/x/Audora'),
      );
      final box = await _box(
        await _store({'local_dir_uri': _music, 'download_dir_uri': _dl}),
        files,
      );

      await box.restore();

      // 本地目录只是拿去过滤 MediaStore，只读完全够用
      expect(box.localScanPath, '/x/Music');
      expect(box.downloadUsable, isTrue);
    });

    test('原生问不出结果（提供方挂了）→ 留一句原因，不静默变未设置',
        () async {
      final files = _FakeFiles(describeError: Exception('provider died'));
      final box = await _box(
        await _store({'download_dir_uri': _dl}),
        files,
      );

      await box.restore();

      expect(box.note, contains('目录检查失败'));
      expect(box.isSet(MusicDirKind.download), isFalse);
    });

    test('非 Android 平台不去调用通道，只说明情况', () async {
      final files = _FakeFiles(supported: false);
      final box = await _box(
        await _store({'local_dir_uri': _music}),
        files,
      );

      await box.restore();

      expect(files.described, isEmpty);
      expect(box.note, contains('当前平台不支持'));
    });
  });

  group('选择与清除', () {
    test('选定后落盘，重启（新 store 读同一份 prefs）还能拿回来', () async {
      final store = await _store();
      final files = _FakeFiles(
        nextPick: _dir(_music, name: 'Music', posix: '/storage/emulated/0/Music'),
      );
      final box = await _box(store, files);

      expect(await box.pick(MusicDirKind.local), isNull, reason: '顺利时不该有提示');
      expect(store.localDirUri, _music);
      expect(box.localScanPath, '/storage/emulated/0/Music');

      // 重新「开机」：同一份 prefs + 一次核对
      final reopened = await _box(
        await _store({'local_dir_uri': _music}),
        _FakeFiles(
          describeFor: (u) => _dir(u, name: 'Music', posix: '/x'),
        ),
      );
      await reopened.restore();
      expect(reopened.trailingOf(MusicDirKind.local), 'Music');
    });

    test('换目录时选择器从上次的目录打开，而不是每次回到存储根', () async {
      final files = _FakeFiles(
        nextPick: _dir(_dl, name: 'Audora'),
        describeFor: (uri) => _dir(uri, name: 'Music', posix: '/x/Music'),
      );
      final box = await _box(await _store({'download_dir_uri': _music}), files);
      await box.restore();
      expect(files.pickInitial, isEmpty, reason: 'restore 不该拉起选择器');

      await box.pick(MusicDirKind.download);

      expect(files.pickInitial, [_music]);
    });

    test('用户取消 = 什么都不改、也不报错', () async {
      final files = _FakeFiles(nextPick: null);
      final store = await _store();
      final box = await _box(store, files);

      expect(await box.pick(MusicDirKind.download), isNull);
      expect(box.isSet(MusicDirKind.download), isFalse);
      expect(store.downloadDirUri, isEmpty);
    });

    test('提供方不支持持久授权：收下这次选择，但说清重启会掉', () async {
      // 刚选完那一刻：granted 恒真（系统确实给了授权），persisted 才是问题。
      final files = _FakeFiles(
        nextPick: const MusicDirectory(
          uri: _dl,
          name: 'Audora',
          granted: true,
          exists: true,
          writable: true,
          persisted: false,
        ),
      );
      final box = await _box(await _store(), files);

      final warn = await box.pick(MusicDirKind.download);

      expect(warn, contains('重启后需重选'));
      expect(box.isSet(MusicDirKind.download), isTrue,
          reason: '这次进程内它就是可用的，别把它踢回未设置');
      expect(box.downloadUsable, isTrue);
    });

    test('本地目录没有 posix 路径（网盘类提供方）→ 提示仍按全盘扫', () async {
      final files = _FakeFiles(
        nextPick: const MusicDirectory(
          uri: 'content://com.nextcloud.android.sso.documents/tree/remote',
          name: '网盘',
          granted: true,
          exists: true,
          writable: true,
          persisted: true,
        ),
      );
      final box = await _box(await _store(), files);

      final warn = await box.pick(MusicDirKind.local);

      expect(warn, contains('仍按全盘'));
      expect(box.localScanPath, isNull);
    });

    test('清除只清自己那一项，另一项不受影响；并把授权交还给系统', () async {
      final files = _FakeFiles(
        describeFor: (uri) => _dir(
          uri,
          name: uri == _music ? 'Music' : 'Audora',
          posix: uri == _music ? '/x/Music' : '/x/Audora',
        ),
      );
      final store = await _store({'local_dir_uri': _music, 'download_dir_uri': _dl});
      final box = await _box(store, files);
      await box.restore();
      expect(box.isSet(MusicDirKind.local), isTrue);

      await box.clear(MusicDirKind.local);

      expect(store.localDirUri, isEmpty);
      expect(box.isSet(MusicDirKind.local), isFalse);
      expect(box.isSet(MusicDirKind.download), isTrue,
          reason: '两个目录必须互不回退——混成一个就会把自己下载的歌再扫一遍');
      expect(files.released, [_music]);
    });

    test('非 Android 上点这一行 = 一句解释，不是崩溃也不是没反应', () async {
      final box = await _box(await _store(), _FakeFiles(supported: false));

      expect(await box.pick(MusicDirKind.download), contains('不支持'));
    });

    test('通道抛 PlatformException 时把原因带出来，不吞成「没反应」', () async {
      final box = await _box(
        await _store(),
        _FakeFiles(
          pickError: Exception('无法打开系统目录选择器'),
        ),
      );

      expect(await box.pick(MusicDirKind.local), contains('选择目录失败'));
    });
  });
}
