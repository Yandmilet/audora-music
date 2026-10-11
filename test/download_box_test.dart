/// 播放页下载（DownloadBox）的状态机测试。
///
/// ## 为什么这些必须测
/// 下载是全流程里最容易「看起来成功、其实留下垃圾」的一段：解析失败要能说
/// 清原因、取消要把半成品清掉、成功后必须落一条 download 记录（否则下次
/// 启动按钮又变回「下载」，而文件其实已经在手机里了）。这几条都发生在
/// 用户看不见的异步链路上，只能靠断言行为。
///
/// ## 两个假件
/// - 平台通道：[_FakeFiles]（[AudoraFiles] 的方法都可覆写）
/// - 解析结果：直接注入一个返回 [DownloadTarget] 的函数——所以这里不需要
///   真的 AudioPlayer（它会起 2 秒周期的看门狗 Timer，单测里必炸）
/// 数据库用真内存库：下载完成要落 `local_audio`，那是这条链路的一部分。
library;

import 'dart:async';

import 'package:audora_files/audora_files.dart';
import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/dao/local_audio_dao.dart';
import 'package:audora_music/data/db/schema.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/services/settings/settings_store.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/state/download.dart';
import 'package:audora_music/state/music_dirs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audora_music/services/bilibili/bili_dto.dart'
    show audioQualityLabel;

int _dbSeq = 0;

class _FakeFiles extends AudoraFiles {
  _FakeFiles();

  final List<Map<String, Object?>> started = [];
  final List<String> canceled = [];
  final List<String> deleted = [];
  String nextTaskId = 't1';
  Object? startError;
  MusicDirectory? nextPick;

  @override
  bool get isSupported => true;

  @override
  Future<String> startDownload({
    required String url,
    required String destUri,
    required String fileName,
    Map<String, String> headers = const {},
    String mime = 'application/octet-stream',
  }) async {
    started.add({
      'url': url,
      'destUri': destUri,
      'fileName': fileName,
      'headers': headers,
      'mime': mime,
    });
    if (startError != null) throw startError!;
    return nextTaskId;
  }

  @override
  Future<void> cancelDownload(String taskId) async => canceled.add(taskId);

  @override
  Future<void> deleteFile(String uri) async => deleted.add(uri);

  @override
  Future<MusicDirectory?> pickDirectory({
    String? reason,
    String? initialUri,
  }) async =>
      nextPick;

  @override
  Future<MusicDirectory?> describe(String uri) async => null;

  @override
  Future<List<MusicDirectory>> listDirectories() async => const [];

  @override
  Future<void> release(String uri) async {}

  @override
  Future<List<AudioFileEntry>> scanAudio({String? pathPrefix}) async =>
      const [];
}

const _dlDir = MusicDirectory(
  uri: 'content://com.android.externalstorage.documents/tree/primary%3AAudora',
  name: 'Audora',
  posixPath: '/storage/emulated/0/Audora',
  granted: true,
  exists: true,
  writable: true,
  persisted: true,
);

final _song = Song(
  id: 1,
  title: '晴天',
  artist: '周杰伦 / 费玉清', // 带 '/'：文件名清洗正好被考验到
  album: '叶惠美',
  duration: 269,
  coverSeed: 3,
  source: AudioSource(
    bvid: 'BV1',
    cid: 2,
    qualityLabel: '192Kbps',
    qualityId: 30280,
    matchScore: 0.9,
    auto: true,
    durationDelta: 1,
    uploader: 'u',
  ),
);

class _Harness {
  _Harness({
    DownloadTarget? target,
    MusicDirectory? dir,

    /// 覆盖「解析下载地址」这一步（造异常、造挂住都用它）。
    Future<DownloadTarget> Function(Song, int)? resolveFn,

    /// 两个等待上限。单测里传短值，让「超时」这条路真的能在测试里跑到。
    Duration resolveTimeout = const Duration(seconds: 30),
    Duration stallTimeout = const Duration(seconds: 30),
  }) : files = _FakeFiles() {
    progress = StreamController<DownloadUpdate>();
    if (dir != null) files.nextPick = dir;
    box = DownloadBox(
      repo: () => _repo,
      resolve: resolveFn ??
          (_, __) async =>
              target ?? (url: null, qualityId: 0, mime: 'audio/mp4', error: '未配置'),
      streamHeaders: () => const {'Referer': 'https://www.bilibili.com'},
      dirs: () => dirs,
      downloadQuality: () => QualityPreference.medium,
      downloaded: () => downloaded,
      reloadDownloaded: () async {
        downloaded = _repo == null
            ? const []
            : await _repo!.localAudioOf(LocalAudioKind.download);
      },
      onChange: () => changes++,
      files: files,
      progress: progress.stream,
      resolveTimeout: resolveTimeout,
      stallTimeout: stallTimeout,
    );
    dirs = MusicDirsBox(
      settings: () => _store,
      onChange: () {},
      files: files,
    );
  }

  late final DownloadBox box;
  late final MusicDirsBox dirs;
  late _FakeFiles files;
  late StreamController<DownloadUpdate> progress;
  List<LocalAudioEntry> downloaded = const [];
  int changes = 0;

  /// 直接 await 一次事件处理完（含落库）。
  ///
  /// 刻意不走 StreamController：sqflite 在单测里是 isolate 异步完成的，
  /// 「推进去再等几个零延迟」会撞到 tearDown 关库之后，报 database_closed。
  /// 见 DownloadBox.handleUpdate 的注释。
  Future<void> emit(DownloadUpdate u) => box.handleUpdate(u);
}

AppDatabase? _db;
LibraryRepository? _repo;
SettingsStore? _store;

Future<void> _setUpDb() async {
  _db = await AppDatabase.open(
    path: 'file:dl${_dbSeq++}?mode=memory&cache=shared',
  );
  // local_audio.song_id 带外键：下载记录必须指向一首真在曲库里的歌。
  // 先按 _song 的 id 插一行，否则落库那步会被 SQLite 直接拒掉。
  await _db!.db.insert(Tables.song, {
    'id': 1,
    'qq_song_mid': 'S-QINGTIAN',
    'title': '晴天',
    'artists': '周杰伦 / 费玉清',
    'album': '叶惠美',
    'album_mid': 'A1',
    'duration_ms': 269000,
    'cover_seed': 3,
    'created_at': 1000,
    'updated_at': 1000,
  });
  _repo = LibraryRepository(
    db: _db!,
    engine: MatchEngine(BiliAudioSourceAdapter(BiliApi(BiliApiClient()))),
    metadata: QQMusicMetadataAdapter(QQMusicProvider()),
  );
  SharedPreferences.setMockInitialValues({});
  _store = SettingsStore.fromPrefs(await SharedPreferences.getInstance());
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await _setUpDb();
  });

  tearDown(() async {
    _repo = null;
    _store = null;
    await _db?.close();
    _db = null;
  });

  group('按下去之前先把话说清楚', () {
    test('没设下载目录 → 一句指路的话，不发任何下载', () async {
      final h = _Harness(
        target: (url: 'https://x/a.m4a', qualityId: 30232, mime: 'audio/mp4', error: null),
      );
      addTearDown(h.box.dispose);

      final msg = await h.box.start(_song);

      expect(msg, contains('下载目录'));
      expect(h.files.started, isEmpty);
    });

    test('数据层未接入 / 歌没有 id 都如实说，不静默', () async {
      final h = _Harness(dir: _dlDir);
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      final noRepo = DownloadBox(
        repo: () => null,
        resolve: (_, __) async =>
            (url: 'u', qualityId: 0, mime: 'audio/mp4', error: null),
        streamHeaders: () => const {},
        dirs: () => h.dirs,
        downloadQuality: () => QualityPreference.medium,
        downloaded: () => const [],
        reloadDownloaded: () async {},
        onChange: () {},
        files: _FakeFiles(),
        progress: StreamController<DownloadUpdate>().stream,
      );
      addTearDown(noRepo.dispose);
      expect(await noRepo.start(_song), '数据层未接入');
    });

    test('解析给失败原因时，那句原因原样递到用户面前', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (
          url: null,
          qualityId: 0,
          mime: 'audio/mp4',
          error: '这个音源没有可下载的音频流',
        ),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      expect(await h.box.start(_song), '这个音源没有可下载的音频流');
      expect(h.files.started, isEmpty);
      // 失败后按钮要回到可以重按的状态，不能卡在「解析地址」
      expect(h.box.uiOf(_song).running, isFalse);
    });
  });

  group('三态按钮', () {
    Future<_Harness> started() async {
      final h = _Harness(
        dir: _dlDir,
        target: (
          url: 'https://cdn/a.m4a',
          qualityId: 30232,
          mime: 'audio/mp4',
          error: null,
        ),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);
      final msg = await h.box.start(_song);
      expect(msg, isNull);
      return h;
    }

    test('发起时带的参数一条都不能少（URL / 目录 / 文件名 / 请求头 / MIME）',
        () async {
      final h = await started();
      final call = h.files.started.single;
      expect(call['url'], 'https://cdn/a.m4a');
      expect(call['destUri'], _dlDir.uri);
      expect(call['headers'], {'Referer': 'https://www.bilibili.com'},
          reason: 'B站 CDN 少 Referer 就是 403');
      // 歌手名里的 '/' 必须被换掉，否则 SAF 创建文档会失败
      expect(call['fileName'], '晴天 - 周杰伦 费玉清.m4a');
    });

    test('下载中显示百分比，按第二下是取消', () async {
      final h = await started();
      expect(h.box.uiOf(_song).running, isTrue);

      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.running,
        done: 42,
        total: 100,
      ));
      expect(h.box.uiOf(_song).label, '42%');
      expect(h.box.uiOf(_song).percent, 42);

      await h.box.cancel();
      expect(h.files.canceled, ['t1']);
    });

    test('没有 Content-Length 时显示「下载中」而不是假百分比', () async {
      final h = await started();
      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.running,
        done: 5 * 1024 * 1024,
        total: 0,
      ));
      final ui = h.box.uiOf(_song);
      expect(ui.label, '下载中');
      expect(ui.percent, isNull);
    });

    test('取消回推后按钮复位', () async {
      final h = await started();
      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.canceled,
      ));
      final ui = h.box.uiOf(_song);
      expect(ui.running, isFalse);
      expect(ui.done, isFalse);
      expect(ui.label, '下载');
    });

    test('失败后按钮变成「重试」，重试能真的再发一次', () async {
      final h = await started();
      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.failed,
        error: '源站返回 403',
      ));
      expect(h.box.uiOf(_song).label, '重试');

      await h.box.resetFailed();
      await h.box.start(_song);
      expect(h.files.started, hasLength(2));
    });

    test('一首在下时，另一首歌的按钮是不可按的', () async {
      final h = await started();
      const other = Song(
        id: 2,
        title: '搁浅',
        artist: '周杰伦',
        duration: 240,
        coverSeed: 4,
      );
      expect(h.box.uiOf(other).enabled, isFalse,
          reason: '原生是单线程串行，按了也只是排队，不如先不让按');
    });
  });

  group('完成与移除', () {
    test('成功后落一条 download 记录，按钮立刻变「已下载」', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (
          url: 'https://cdn/a.m4a',
          qualityId: 30280,
          mime: 'audio/mp4',
          error: null,
        ),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);
      await h.box.start(_song);

      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.done,
        done: 6000000,
        total: 6000000,
        uri: 'content://…/document/primary:Audora/晴天.m4a',
        name: '晴天.m4a',
        size: 6000000,
      ));

      final rows = await _repo!.localAudioOf(LocalAudioKind.download);
      expect(rows, hasLength(1));
      expect(rows.single.songId, 1);
      expect(rows.single.kind, LocalAudioKind.download);
      expect(rows.single.qualityId, 30280);
      expect(rows.single.durationMs, 269 * 1000);

      expect(h.box.isDownloaded(_song), isTrue);
      final ui = h.box.uiOf(_song);
      expect(ui.done, isTrue);
      expect(ui.label, '已下载');
      expect(audioQualityLabel(30280), '192Kbps');
    });

    test('过期任务的事件不回灌（上一首的 done 不能算到这一头上）', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (
          url: 'https://cdn/a.m4a',
          qualityId: 0,
          mime: 'audio/mp4',
          error: null,
        ),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);
      await h.box.start(_song);
      // 先让它以 canceled 结束
      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.canceled,
      ));
      // 迟到的 done（同一个 taskId 的重复/乱序事件）
      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.done,
        uri: 'late-uri',
        size: 10,
      ));
      expect(await _repo!.localAudioOf(LocalAudioKind.download), isEmpty,
          reason: '已经取消的任务不该再往清单里塞一条');
    });

    test('移除 = 删文件 + 删记录，两步都做了按钮才复位', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (
          url: 'https://cdn/a.m4a',
          qualityId: 0,
          mime: 'audio/mp4',
          error: null,
        ),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);
      await h.box.start(_song);
      await h.emit(const DownloadUpdate(
        taskId: 't1',
        status: DownloadStatus.done,
        uri: 'content://doc/1',
        size: 100,
      ));
      expect(h.box.isDownloaded(_song), isTrue);

      final msg = await h.box.remove(_song);
      expect(msg, isNull);
      expect(h.files.deleted, ['content://doc/1']);
      expect(h.box.isDownloaded(_song), isFalse);
      expect(await _repo!.localAudioOf(LocalAudioKind.download), isEmpty);
    });
  });

  // ── 真机反馈：「下载功能失效，一直处于下载中状态」──────────────
  //
  // 旧实现有三条路会把状态永久挂在「下载中」：解析抛异常（start 里没 try）、
  // 解析无限等待（没超时）、取消只等原生回推（回推一丢就永远挂着）。
  // 这里把三条出口各自钉住：**任何情况都必须回到可点的状态**。
  group('永久「下载中」的出口', () {
    final ok = (url: 'https://cdn/x.m4s', qualityId: 30280, mime: 'audio/mp4', error: null);

    test('解析地址抛异常 → 回文案并落回空闲（不再挂住）', () async {
      final h = _Harness(
        dir: _dlDir,
        resolveFn: (_, __) async => throw StateError('解析器炸了'),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      final msg = await h.box.start(_song);

      expect(msg, contains('解析下载地址失败'));
      expect(h.box.uiOf(_song).running, isFalse,
          reason: '异常之后按钮必须回到「下载」，不能永远转圈');
      expect(h.box.uiOf(_song).label, '下载');
    });

    test('解析地址挂住 → 到点判超时，且期间显示「准备中」不是「下载中」', () async {
      final gate = Completer<DownloadTarget>();
      final h = _Harness(
        dir: _dlDir,
        resolveTimeout: const Duration(milliseconds: 40),
        resolveFn: (_, __) => gate.future,
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      final started = h.box.start(_song);
      // 解析阶段：说清楚卡在哪一步，用户才知道该不该等
      expect(h.box.uiOf(_song).label, '准备中');

      final msg = await started;
      expect(msg, contains('超时'));
      expect(h.box.uiOf(_song).running, isFalse);
      gate.complete(ok); // 让上面那个 completer 不悬空
    });

    test('解析阶段点取消有出口（旧行为：返回 null 且状态永久挂着）', () async {
      final gate = Completer<DownloadTarget>();
      final h = _Harness(
        dir: _dlDir,
        resolveTimeout: const Duration(seconds: 30),
        resolveFn: (_, __) => gate.future,
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      final started = h.box.start(_song);
      expect(h.box.uiOf(_song).running, isTrue);

      final msg = await h.box.cancel();
      expect(msg, isNotNull, reason: '取消必须说一句，不能静默');
      expect(h.box.uiOf(_song).running, isFalse);
      expect(h.files.canceled, isEmpty, reason: '还没交给原生，无需去取消原生任务');
      gate.complete(ok);
      await started;
    });

    test('拿到任务后原生不回推 → 看门狗判掉线，按钮变「重试」', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (url: 'https://cdn/x.m4s', qualityId: 30280, mime: 'audio/mp4', error: null),
        stallTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      expect(await h.box.start(_song), isNull, reason: '受理阶段不该报错');
      expect(h.box.uiOf(_song).label, '下载中');

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(h.box.uiOf(_song).label, '重试',
          reason: '一条进度都没收到时不能永远「下载中」');
      expect(h.files.canceled, ['t1'], reason: '顺手让原生停掉那条僵尸任务');
    });

    test('进度正常回推会喂狗，不会因为慢半拍被误判掉线', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (url: 'https://cdn/x.m4s', qualityId: 30280, mime: 'audio/mp4', error: null),
        stallTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      await h.box.start(_song);
      await h.emit(const DownloadUpdate(
          taskId: 't1', status: DownloadStatus.running, done: 1, total: 10));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await h.emit(const DownloadUpdate(
          taskId: 't1', status: DownloadStatus.running, done: 6, total: 10));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(h.box.uiOf(_song).label, '60%', reason: '还在正常前进');
      expect(h.box.uiOf(_song).running, isTrue);
    });

    test('已受理后点取消：本地立刻空闲，不依赖 canceled 回推', () async {
      final h = _Harness(
        dir: _dlDir,
        target: (url: 'https://cdn/x.m4s', qualityId: 30280, mime: 'audio/mp4', error: null),
      );
      addTearDown(h.box.dispose);
      await h.dirs.pick(MusicDirKind.download);

      await h.box.start(_song);
      final msg = await h.box.cancel();

      expect(msg, '已取消下载');
      expect(h.files.canceled, ['t1']);
      expect(h.box.uiOf(_song).running, isFalse,
          reason: '原生那条 canceled 回推即使丢了，界面也不该停在下载中');
    });
  });
}
