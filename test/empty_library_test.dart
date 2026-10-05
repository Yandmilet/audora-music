/// 空曲库契约测试。
///
/// ## 为什么单独写这个文件
/// 「库为空时该怎么办」这个决定被反复改过，而且**改错了不会报错**——
/// 早期版本用 `MockData.songs` 兜底，结果是：
///   - 首页显示 30 首假歌，用户以为已经导入了
///   - 搜索"能用"，但搜的是假数据，导入了真歌也看不出区别
///   - 排行榜/常听从假数据派生，"功能没实现"的观感全部来自这里
///
/// 这类「静默填假数据」的问题没有任何异常可抓，只能靠断言行为契约。
/// 所以这里把「空就是空」显式钉死。
library;

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:audora2/services/source/bili_audio_source_adapter.dart';
import 'package:audora2/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('未接入数据层（repo == null）：走 mock，供单测/预览', () {
    test('library 有内容，usingMock 为 true', () {
      final st = AppState();
      expect(st.usingMock, isTrue);
      expect(st.library, isNotEmpty);
      expect(st.libraryEmpty, isFalse);
      st.dispose();
    });

    test('未接入数据层时 qq 为 null（目录浏览如实不可用）', () {
      final st = AppState();
      expect(st.usingMock, isTrue);
      expect(st.qq, isNull, reason: 'mock 模式没有 QQ 接口，目录页要如实显示');
      st.dispose();
    });

    test('setQuery / commitSearch 不查本地库，只记录历史与关键词', () {
      // 曲库作为独立概念已删除：搜索只走 QQ 音乐在线。
      // mock 模式下 searchOnline 无数据层会直接返回，不会发网络请求。
      final st = AppState();
      st.setQuery('周杰伦');
      st.commitSearch('周杰伦');
      expect(st.query, '周杰伦');
      expect(st.history, contains('周杰伦'));
      st.dispose();
    });
  });

  group('已接入数据层但库为空：诚实空着，不填假数据', () {
    late AppDatabase db;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:emptycontract$seq?mode=memory&cache=shared',
      );
    });

    tearDown(() async => db.close());

    test('loadLibrary 后 library 仍为空，且不报错', () async {
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      expect(st.loadState, LibraryLoadState.ready);
      expect(st.library, isEmpty, reason: '空库不许回退 mock');
      expect(st.libraryEmpty, isTrue);
      st.dispose();
    });

    test('空库时 usingMock 仍为 false（语义不再混淆）', () async {
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      // 旧版把「库为空」也算 usingMock，导致真实空库被当成 mock 模式。
      // 现在 usingMock 只表示「没有数据层」。
      expect(st.usingMock, isFalse);
      st.dispose();
    });

    test('空库不影响目录浏览（qq 可用，浏览与本地曲库解耦）', () async {
      final st = AppState(repo: _repo(db), qqCatalog: QQMusicProvider());
      await st.loadLibrary();

      // 浏览优先的形态下，目录内容来自远端，与本地曲库是否为空无关。
      // 这是本次重构的核心解耦点：空库也能逛榜单/歌手/歌单。
      expect(st.libraryEmpty, isTrue);
      expect(st.qq, isNotNull);
      st.dispose();
    });

    test('空库时 queue 也为空、index 为 -1（不指向不存在的歌）', () async {
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      expect(st.queue, isEmpty);
      expect(st.index, -1);
      expect(st.current, isNull);
      st.dispose();
    });

    test('播放控制对空队列安全（不抛异常）', () async {
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      // 这些在真机上会被空状态按钮挡住，但代码路径必须安全——
      // 否则异步回调里触发一次就是崩溃
      expect(() => st.next(), returnsNormally);
      expect(() => st.previous(), returnsNormally);
      expect(() => st.jumpTo(0), returnsNormally);
      expect(() => st.shufflePlay(), returnsNormally);
      // togglePlay 是 async：必须 await，否则异常会在 await 之后才抛，
      // 而 returnsNormally 只覆盖同步段，等于没测。
      await expectLater(st.togglePlay(), completes);
      st.dispose();
    });

    test('dispose 之后 togglePlay 不炸（async 落点有 mounted 守卫）', () async {
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      // UI 把 togglePlay 当同步回调用（onPressed 里直接调不 await），
      // 页面销毁后回调才恢复执行，过去这里会抛 used after being disposed。
      final fut = st.togglePlay();
      st.dispose();
      await expectLater(fut, completes);
    });

    test('搜索历史初始为空（不预填 mock 的示例词）', () {
      final st = AppState(repo: _repo(db));
      expect(st.history, isEmpty);
      st.dispose();
    });
  });
}

/// 构造 Repository。空库路径不会触发网络，但构造需要 engine / qq。
LibraryRepository _repo(AppDatabase db) => LibraryRepository(
      db: db,
      engine: MatchEngine(BiliAudioSourceAdapter(BiliApi(BiliApiClient()))),
      metadata: QQMusicMetadataAdapter(QQMusicProvider()),
    );
