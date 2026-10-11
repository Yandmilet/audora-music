/// 收藏的「唯一真相」回归测试。
///
/// ## 真机缺陷（2026-10-11 用户反馈 + 现场复现）
/// 「我的」页收藏卡片写着 **1 首**，点进去却是**暂无内容**。
/// 用 adb 在魅族 21 上复现确认过。
///
/// ## 根因是两套口径
/// 计数走内存里的红心集合，列表走 `library.where(isLiked)`，而 `library`
/// 只是曲库**最近 500 行**的窗口（[AppState.loadLibrary] 里的
/// `listSongs(limit: 500)`）。在一首窗口外的歌（榜单点进来的新歌、
/// 本机下载/扫描的歌）上点心 → 计数 +1，可列表按窗口筛就是空。
/// 更要命的是红心按 `title|artist` 记，重启后能不能对上全看那首歌在不在窗口里。
///
/// ## 现在锁住的契约
/// 1. 计数 = 数据库 `liked_song` 行数，与曲库窗口无关；
/// 2. 列表 = 现查数据库（按收藏时间倒序），窗口外的老收藏照样列得出来；
/// 3. 红心按 song_id 判，同一首歌的不同对象（队列里的 vs 曲库里的）结论一致；
/// 4. 没有 song 行的本机文件**不做假收藏**：给一句提示，计数不动。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/data/repository/library_repository.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora_music/services/qqmusic/qqmusic_provider.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// AppState 曲库窗口大小（与 loadLibrary 里的 limit 一致）。
const _window = 500;

int _dbSeq = 0;

Song _song(String title, String artist, {int? id, int duration = 200}) =>
    Song(id: id, title: title, artist: artist, duration: duration, coverSeed: 0);

Future<AppDatabase> _openDb(String tag) async {
  final seq = _dbSeq++;
  return AppDatabase.open(path: 'file:likedtruth$tag$seq?mode=memory&cache=shared');
}

LibraryRepository _repo(AppDatabase db) => LibraryRepository(
      db: db,
      engine: MatchEngine(BiliAudioSourceAdapter(BiliApi(BiliApiClient()))),
      metadata: QQMusicMetadataAdapter(QQMusicProvider()),
    );

/// 塞进 [count] 首歌（created_at 递增），返回按插入顺序的 song_id。
Future<List<int>> _seedSongs(AppDatabase db, int count) async {
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    out.add(await db.songs.upsert(
      SongRow.fromSong(
        _song('歌$i', '歌手$i'),
        qqSongMid: 'mid$i',
        now: 1000 + i,
      ),
    ));
  }
  return out;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('曲库窗口外的收藏', () {
    test('计数与列表都看得见（旧实现在这里裂开）', () async {
      final db = await _openDb('window');
      final ids = await _seedSongs(db, _window + 2);
      // 最老的两首落在「最近 500 行」窗口之外
      await db.liked.like(ids.first, now: 9000);

      final st = AppState(repo: _repo(db));
      await st.loadLibrary();
      expect(st.library.length, _window,
          reason: '前提：曲库确实只装了窗口内的歌');
      expect(st.library.where(st.isLiked), isEmpty,
          reason: '前提：这条收藏在窗口外——旧口径正是据此数收藏，才出现「1 首 / 空列表」');

      expect(st.likedCount, 1, reason: '计数来自数据库，不受曲库窗口限制');
      final list = await st.likedSongsList();
      expect(list.map((s) => s.title), ['歌0']);
      expect(st.isLiked(list.first), isTrue,
          reason: '列表里那一行的红心必须也是亮的');

      st.dispose();
      await db.close();
    });

    test('按收藏时间倒序，最近收藏排在前', () async {
      final db = await _openDb('order');
      final ids = await _seedSongs(db, 3);
      await db.liked.like(ids[0], now: 1000);
      await db.liked.like(ids[2], now: 3000);
      await db.liked.like(ids[1], now: 2000);

      final st = AppState(repo: _repo(db));
      expect(
        (await st.likedSongsList()).map((s) => s.title).toList(),
        ['歌2', '歌1', '歌0'],
      );

      st.dispose();
      await db.close();
    });
  });

  group('点心 / 取消', () {
    test('计数随操作即时变化，且真的落库', () async {
      final db = await _openDb('toggle');
      await _seedSongs(db, 1);

      final st = AppState(repo: _repo(db));
      await st.loadLibrary();
      final inLibrary = st.library.single;

      await st.toggleLike(inLibrary);
      expect(st.likedCount, 1);
      expect(await db.liked.count(), 1, reason: '内存与库不能只改一边');

      await st.toggleLike(inLibrary);
      expect(st.likedCount, 0);
      expect(await db.liked.count(), 0);

      st.dispose();
      await db.close();
    });

    test('同一首歌的另一个对象（队列里那份）红心结论一致', () async {
      // 队列里的 Song 与曲库里的 Song 常常是**两个实例**（持久化、刷新
      // 都会换对象），按 id 判才不会出现「这里亮着那里不亮」。
      final db = await _openDb('twoobjects');
      final ids = await _seedSongs(db, 1);
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      final fresh = _song('歌0', '歌手0', id: ids.first);
      expect(st.isLiked(fresh), isFalse);
      await st.toggleLike(fresh);
      expect(st.isLiked(st.library.single), isTrue);
      expect((await st.likedSongsList()).single.title, '歌0');

      st.dispose();
      await db.close();
    });

    test('没入库的本机文件点心：如实提示，不产生假收藏', () async {
      final db = await _openDb('localfile');
      final st = AppState(repo: _repo(db));
      await st.loadLibrary();

      // localEntryToSong 对纯扫描条目给的就是 id == null
      final local = _song('本机歌曲', '某歌手');
      await st.toggleLike(local);

      expect(st.isLiked(local), isFalse, reason: '不落库的红心不该亮着');
      expect(st.likedCount, 0, reason: '假收藏不该进计数');
      expect(st.toast, contains('还没入库'));
      expect(await db.liked.count(), 0);

      st.dispose();
      await db.close();
    });
  });

  test('数据层未接入（mock 预览）时仍走内存集合，UI 有内容可看', () async {
    final st = AppState();
    expect(st.likedCount, greaterThan(0), reason: 'mock 模式给几个演示红心');
    expect(st.library.where(st.isLiked).length, st.likedCount,
        reason: 'mock 模式下计数与列表同源（都在内存里）');
    expect((await st.likedSongsList()).length, st.likedCount);
    st.dispose();
  });
}
