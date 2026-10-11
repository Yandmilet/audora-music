/// SongDao 的两个数据层修复的回归测试。
///
///   1. `getAllExcluding` 不再接受原始子查询字符串（注入 sink）→
///      改为 `ExcludeScope` 枚举，拼接点在 DAO 内部唯一且全为常量
///   2. `search()` 的 LIKE 转义 `%` / `_` / 转义符本身，
///      让通配符按字面量匹配
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/dao/song_dao.dart' show ExcludeScope;
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
  });

  tearDown(() async => db.close());

  Future<int> addSong(String title, {String artist = '歌手', String album = '专辑'}) {
    return db.songs.upsert(SongRow.fromSong(
      Song(
        title: title,
        artist: artist,
        album: album,
        duration: 200,
        coverSeed: 1,
      ),
      qqSongMid: SongRow.deriveMid(title, artist),
    ));
  }

  Set<String> titlesOf(List<SongRow> rows) =>
      rows.map((r) => r.title).toSet();

  // ═══════════════════════════════════════════════════════════════
  // 1. 排除口径用枚举，注入 sink 关闭
  // ═══════════════════════════════════════════════════════════════
  group('getAllExcluding 的排除口径', () {
    test('anyBinding：有任何绑定记录就排除（含 REVIEW）', () async {
      await addSong('甲');
      final b = await addSong('乙');
      await addSong('丙');

      // binding 对 bvid 有外键，必须先有对应视频行
      await db.videos.upsert(const VideoRow(
        bvid: 'BV1',
        cid: 1,
        title: 'v',
        fetchedAt: 1,
      ));
      await db.bindings.upsert(BindingRow(
        songId: b,
        bvid: 'BV1',
        isActive: false, // REVIEW：只存候选、不激活
        matchScore: 0.7,
        confidence: MatchConfidence.review,
        matchType: MatchType.manualBound,
        matchedAt: 1,
      ));

      expect(titlesOf(await db.songs.getAllExcluding(ExcludeScope.anyBinding)),
          {'甲', '丙'});
    });

    test('activeBinding：只排除已激活的（REVIEW 仍留在队列里）', () async {
      await addSong('甲');
      final b = await addSong('乙');
      await addSong('丙');

      await db.videos.upsert(const VideoRow(
        bvid: 'BV1',
        cid: 1,
        title: 'v',
        fetchedAt: 1,
      ));
      await db.bindings.upsert(BindingRow(
        songId: b,
        bvid: 'BV1',
        isActive: false,
        matchScore: 0.7,
        confidence: MatchConfidence.review,
        matchType: MatchType.manualBound,
        matchedAt: 1,
      ));

      // 与 anyBinding 的关键差异：REVIEW 不算「已处理」
      expect(titlesOf(await db.songs.getAllExcluding(ExcludeScope.activeBinding)),
          {'甲', '乙', '丙'});
    });

    test('没有任何绑定时两种口径都返回全部', () async {
      await addSong('甲');
      await addSong('乙');

      expect(titlesOf(await db.songs.getAllExcluding(ExcludeScope.anyBinding)),
          {'甲', '乙'});
      expect(titlesOf(await db.songs.getAllExcluding(ExcludeScope.activeBinding)),
          {'甲', '乙'});
    });

    test('同���首歌多条候选绑定不会影响排除结果（DISTINCT 生效）', () async {
      await addSong('甲');
      final b = await addSong('乙');

      // 同一首歌挂 3 条候选绑定
      for (var i = 0; i < 3; i++) {
        await db.videos.upsert(VideoRow(
          bvid: 'BV$i',
          cid: 1,
          title: 'v$i',
          fetchedAt: 1,
        ));
        await db.bindings.upsert(BindingRow(
          songId: b,
          bvid: 'BV$i',
          isActive: false,
          matchScore: 0.7,
          confidence: MatchConfidence.review,
          matchType: MatchType.autoMatched,
          matchedAt: 1,
        ));
      }

      expect(titlesOf(await db.songs.getAllExcluding(ExcludeScope.anyBinding)),
          {'甲'});
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 2. LIKE 通配符转义
  // ═══════════════════════════════════════════════════════════════
  group('search 的 LIKE 通配符按字面量匹配', () {
    setUp(() async {
      await addSong('100%纯棉');
      await addSong('a_b 测试');
      await addSong('axb 测试');
      await addSong('普通歌');
    });

    test('搜 % 只命中字面含 % 的歌，不返回全部', () async {
      final got = await db.songs.search('%');
      expect(titlesOf(got), {'100%纯棉'},
          reason: '未转义时 % 会当通配符，把整库都匹配出来');
      expect(got.length, lessThan(4));
    });

    test('搜 _ 不把单字符通配符当字面量', () async {
      final got = await db.songs.search('_');
      expect(titlesOf(got), {'a_b 测试'},
          reason: '未转义时 _ 会匹配任意单字符，axb 也会被算命中');
      expect(titlesOf(got).contains('axb 测试'), isFalse);
    });

    test('搜 a_b 精确命中，不含 axb', () async {
      final got = await db.songs.search('a_b');
      expect(titlesOf(got), {'a_b 测试'});
    });

    test('搜转义符自身不会被用来还原通配符', () async {
      // 搜 r'\'  必须按字面量匹配反斜杠，不应变成「任意字符」
      final got = await db.songs.search(r'\');
      // 库里没有任何标题含反斜杠 → 必须一条都不命中
      expect(got, isEmpty,
          reason: '转义符本身若未转义，会把后续字符变成通配符');
    });

    test(r'搜 \% 不会被当成「任意字符」', () async {
      final got = await db.songs.search(r'\%');
      expect(got, isEmpty,
          reason: r'\% 若被还原成 % 就会匹配整库');
    });

    test('普通关键词不受影响（回归）', () async {
      expect(titlesOf(await db.songs.search('纯棉')), {'100%纯棉'});
      expect(titlesOf(await db.songs.search('普通')), {'普通歌'});
      expect(titlesOf(await db.songs.search('测试')), {'a_b 测试', 'axb 测试'});
    });

    test('空关键词返回全部（保持原行为）', () async {
      final got = await db.songs.search('   ');
      expect(got.length, 4);
    });
  });
}