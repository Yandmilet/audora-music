/// 数据层单元测试：三表 CRUD、事务不变式、JSON 明细往返。
///
/// 用 `sqflite_common_ffi` 把 sqlite 跑在内存里，**不碰真机文件、不碰网络**。
/// 这样每次 `flutter test` 都能验证表结构与 SQL 逻辑，成本近乎为零。
library;

import 'dart:convert';

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/dao/song_dao.dart' show ExcludeScope;
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/data/db/schema.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/match/match_scorer.dart';
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

  SongRow row(String title, {String artist = '测试歌手', int durSec = 200}) =>
      SongRow.fromSong(
        Song(
          title: title,
          artist: artist,
          album: '专辑',
          duration: durSec,
          releaseDate: DateTime(2020, 1, 1),
          coverSeed: 1,
        ),
        qqSongMid: SongRow.deriveMid(title, artist),
      );

  group('SongDao', () {
    test('插入与读取', () async {
      final id = await db.songs.upsert(row('秘密'));
      expect(id, greaterThan(0));

      final got = await db.songs.getById(id);
      expect(got, isNotNull);
      expect(got!.title, '秘密');
      // duration_ms 是毫秒，domain 是秒 —— 验证往返一致
      expect(got.durationMs, 200000);
      expect(got.toSong().duration, 200);
    });

    test('全新建表包含 lyric_slope 列且默认 1.0（v10）', () async {
      final cols = await db.db.rawQuery('PRAGMA table_info(${Tables.song})');
      final slopeCols =
          cols.where((c) => c['name'] == 'lyric_slope').toList();
      expect(slopeCols, hasLength(1), reason: 'kCreateSongTable 必须含新列');
      // PRAGMA table_info 的 dflt_value 按 SQL 表达式文本返回
      expect(slopeCols.first['dflt_value'], '1.0');

      final id = await db.songs.upsert(row('斜率歌'));
      final got = await db.songs.getById(id);
      expect(got!.lyricSlope, 1.0);
      expect(got.toSong().lyricSlope, 1.0);
    });

    test('updateLyricCalibration 写入平移与斜率，缺省列不被覆盖', () async {
      final id = await db.songs.upsert(row('校准歌'));

      await db.songs
          .updateLyricCalibration(id, offsetMs: -15000, slope: 1.05);
      var got = await db.songs.getById(id);
      expect(got!.lyricOffsetMs, -15000);
      expect(got.lyricSlope, closeTo(1.05, 1e-9));

      // 只改 offset 时 slope 保持
      await db.songs.updateLyricCalibration(id, offsetMs: 300);
      got = await db.songs.getById(id);
      expect(got!.lyricOffsetMs, 300);
      expect(got.lyricSlope, closeTo(1.05, 1e-9));
    });

    test('批量 upsert 冲突时保留用户已校准的 offset / slope', () async {
      final ids = await db.songs.upsertAll([row('批量校准')]);
      await db.songs
          .updateLyricCalibration(ids.single, offsetMs: 900, slope: 1.02);

      // 同一首歌再次批量导入：校准数据不能被静默抹掉
      await db.songs.upsertAll([row('批量校准')]);
      final got = await db.songs.getById(ids.single);
      expect(got!.lyricOffsetMs, 900);
      expect(got.lyricSlope, closeTo(1.02, 1e-9));
    });

    test('同 mid 重复插入走更新而非新增，且保留 created_at', () async {
      final id1 = await db.songs.upsert(row('秘密'));
      final before = await db.songs.getById(id1);

      // 等一下确保时间戳可能变化
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final id2 = await db.songs.upsert(row('秘密', durSec: 210));

      expect(id2, id1, reason: '应更新同一行');
      expect(await db.songs.count(), 1);

      final after = await db.songs.getById(id2);
      expect(after!.durationMs, 210000, reason: '字段应被更新');
      expect(after.createdAt, before!.createdAt, reason: 'created_at 必须保留');
      expect(after.updatedAt, greaterThanOrEqualTo(before.updatedAt));
    });

    test('批量 upsert 走事务', () async {
      final ids = await db.songs.upsertAll([
        row('A'),
        row('B'),
        row('C'),
      ]);
      expect(ids.length, 3);
      expect(await db.songs.count(), 3);
    });

    test('模糊搜索命中标题 / 歌手 / 专辑', () async {
      await db.songs.upsert(row('秘密', artist: '白浩寅'));
      await db.songs.upsert(row('起风了', artist: '买辣椒也用券'));

      expect((await db.songs.search('秘密')).length, 1);
      expect((await db.songs.search('白浩寅')).length, 1);
      expect((await db.songs.search('不存在的歌')).length, 0);
    });

    test('local: 前缀标记手动录入', () async {
      final id = await db.songs.upsert(row('手工录入'));
      final r = await db.songs.getById(id);
      expect(r!.isLocal, isTrue);
    });

    test('delete 级联清掉绑定', () async {
      final songId = await db.songs.upsert(row('秘密'));
      await db.videos.upsert(const VideoRow(
        bvid: 'BV1',
        cid: 100,
        title: '秘密',
        fetchedAt: 1,
      ));
      await db.bindings.upsert(BindingRow(
        songId: songId,
        bvid: 'BV1',
        matchScore: 0.9,
        confidence: MatchConfidence.auto,
        matchType: MatchType.autoMatched,
        matchedAt: 1,
      ));

      await db.songs.delete(songId);
      // 外键 CASCADE 生效的前提是 onConfigure 里开了 PRAGMA foreign_keys
      expect(await db.bindings.count(), 0);
    });
  });

  group('VideoDao', () {
    test('upsert 与读取', () async {
      await db.videos.upsert(const VideoRow(
        bvid: 'BV1',
        cid: 784756939,
        title: '白浩寅 - 秘密',
        author: '白浩寅',
        durationMs: 226000,
        typename: '音乐',
        playCount: 500000,
        fetchedAt: 1700000000,
      ));

      final v = await db.videos.getByBvid('BV1');
      expect(v, isNotNull);
      expect(v!.cid, 784756939, reason: 'cid 必须存住，playurl 必需');
      expect(v.durationMs, 226000);
    });

    test('同名 bvid 重复 upsert 覆盖', () async {
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'A', fetchedAt: 1));
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'B', fetchedAt: 2));
      expect(await db.videos.count(), 1);
      expect((await db.videos.getByBvid('BV1'))!.title, 'B');
    });

    test('简介截断到 500 字', () async {
      final longDesc = 'X' * 800;
      await db.videos.upsert(VideoRow(
        bvid: 'BV1',
        cid: 1,
        title: 'A',
        description: longDesc,
        fetchedAt: 1,
      ));
      final v = await db.videos.getByBvid('BV1');
      expect(v!.description!.length, 500);
    });

    test('音频 URL 有效期判定（留 5 分钟安全边际）', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // 还有 10 分钟到期 → 可用
      await db.videos.upsert(VideoRow(
        bvid: 'BVvalid',
        cid: 1,
        title: 'A',
        fetchedAt: 1,
        audioUrl: 'https://example.com/a.m4s',
        audioUrlExpireAt: now + 600,
      ));
      expect(await db.videos.getValidAudioUrl('BVvalid'), isNotNull);

      // 只剩 2 分钟 → 在安全边际内，应视为过期
      await db.videos.upsert(VideoRow(
        bvid: 'BVstale',
        cid: 1,
        title: 'A',
        fetchedAt: 1,
        audioUrl: 'https://example.com/b.m4s',
        audioUrlExpireAt: now + 120,
      ));
      expect(await db.videos.getValidAudioUrl('BVstale'), isNull);
    });

    test('markUnavailable 清掉 URL 便于触发重新拉流', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db.videos.upsert(VideoRow(
        bvid: 'BV1',
        cid: 1,
        title: 'A',
        fetchedAt: 1,
        audioUrl: 'https://example.com/a.m4s',
        audioUrlExpireAt: now + 3600,
      ));
      await db.videos.markUnavailable('BV1', 'HTTP 403');

      final v = await db.videos.getByBvid('BV1');
      expect(v!.available, isFalse);
      expect(v.audioUrl, isNull);
      expect(v.unavailableReason, 'HTTP 403');
    });
  });

  group('BindingDao — 激活唯一性（最关键的不变式）', () {
    late int songId;

    setUp(() async {
      songId = await db.songs.upsert(row('秘密'));
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'A', fetchedAt: 1));
      await db.videos.upsert(const VideoRow(bvid: 'BV2', cid: 2, title: 'B', fetchedAt: 1));
    });

    ScoredCandidate cand(String bvid, double score) => ScoredCandidate(
          video: VideoCandidate(bvid: bvid, title: 'A', durationSec: 200),
          total: score,
          detail: const ScoreDetail(
            s1TitleArtist: 1,
            s2Duration: 1,
            s3Uploader: 0.5,
            s4Publish: 1,
            s5Category: 0.6,
            s6Format: 0.8,
          ),
          confidence: MatchScorer.grade(score),
        );

    test('保存 AUTO 匹配后只有一条激活', () async {
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.95));

      final active = await db.bindings.getActive(songId);
      expect(active, isNotNull);
      expect(active!.bvid, 'BV1');
      expect(active.isActive, isTrue);
      expect(active.confidence, MatchConfidence.auto);
    });

    test('切换激活音源：旧的不再激活，新的唯一激活', () async {
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.95));
      await db.bindings.saveMatch(songId: songId, scored: cand('BV2', 0.90));

      final all = await db.bindings.getCandidates(songId);
      final actives = all.where((b) => b.isActive).toList();
      expect(actives.length, 1, reason: '激活音源必须唯一');
      expect(actives.first.bvid, 'BV2');
    });

    test('REVIEW 级不激活', () async {
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.70));
      expect(await db.bindings.getActive(songId), isNull);
      expect((await db.bindings.getCandidates(songId)).length, 1);
    });

    test('同 (song, bvid) 重复写不产生新行', () async {
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.95));
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.80));
      expect(await db.bindings.count(), 1);
    });

    test('人工绑定记录 match_type 与 note（调参样本）', () async {
      await db.bindings.bindManually(
        songId: songId,
        bvid: 'BV1',
        score: 0.78,
        matchType: MatchType.userSelected,
        note: '用户从候选中改选',
      );
      final active = await db.bindings.getActive(songId);
      expect(active!.matchType, MatchType.userSelected);
      expect(active.note, '用户从候选中改选');
      expect(active.isActive, isTrue);
    });

    test('getFailedBvids 只返回已标记不可用的', () async {
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.95));
      await db.videos.markUnavailable('BV1', '403');
      final failed = await db.bindings.getFailedBvids(songId);
      expect(failed, {'BV1'});
    });

    test('stats 按置信度汇总', () async {
      await db.bindings.saveMatch(songId: songId, scored: cand('BV1', 0.95));
      await db.bindings.saveMatch(songId: songId, scored: cand('BV2', 0.70));
      final s = await db.bindings.stats();
      expect(s['AUTO'], 1);
      expect(s['REVIEW'], 1);
    });
  });

  group('BindingRow — score_detail JSON 往返', () {
    test('六维明细序列化后可完整解析回来', () async {
      const detail = ScoreDetail(
        s1TitleArtist: 1.0,
        s2Duration: 0.92,
        s3Uploader: 0.55,
        s4Publish: 0.75,
        s5Category: 0.6,
        s6Format: 0.8,
      );
      final json = BindingRow.detailToJson(detail);
      expect(json, contains('"s1":1.0'));
      expect(json, contains('"s2":0.92'));

      final back = BindingRow.fromMap({
        'song_id': 1,
        'bvid': 'BV1',
        'match_score': 0.9,
        'confidence': 'AUTO',
        'score_detail': json,
        'match_type': 'AUTO_MATCHED',
        'matched_at': 1,
      }).parsedDetail;

      expect(back, isNotNull);
      expect(back!.s1TitleArtist, 1.0);
      expect(back.s2Duration, 0.92);
      expect(back.s3Uploader, 0.55);
      expect(back.s4Publish, 0.75);
      expect(back.s5Category, 0.6);
      expect(back.s6Format, 0.8);
    });

    test('score_detail 为空时不崩', () async {
      final row = BindingRow.fromMap({
        'song_id': 1,
        'bvid': 'BV1',
        'match_score': 0.5,
        'confidence': 'REVIEW',
        'match_type': 'AUTO_MATCHED',
        'matched_at': 1,
      });
      expect(row.parsedDetail, isNull);
    });

    test('损坏的 JSON 不抛异常（只返回 null）', () async {
      final row = BindingRow.fromMap({
        'song_id': 1,
        'bvid': 'BV1',
        'match_score': 0.5,
        'confidence': 'REVIEW',
        'score_detail': '{"s1":not_a_number}',
        'match_type': 'AUTO_MATCHED',
        'matched_at': 1,
      });
      expect(row.parsedDetail, isNull);
    });
  });

  group('AppDatabase', () {
    test('wipe 清空所有表', () async {
      final songId = await db.songs.upsert(row('秘密'));
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'A', fetchedAt: 1));
      await db.bindings.upsert(BindingRow(
        songId: songId,
        bvid: 'BV1',
        matchScore: 0.9,
        confidence: MatchConfidence.auto,
        matchType: MatchType.autoMatched,
        matchedAt: 1,
      ));

      await db.wipe();
      expect(await db.songs.count(), 0);
      expect(await db.videos.count(), 0);
      expect(await db.bindings.count(), 0);
    });
  });

  group('BindingDao.getActiveFor — 批量激活绑定（N+1 修复）', () {
    test('只返回激活行，key 为 song_id；未激活/未绑定的歌不出现', () async {
      final s1 = await db.songs.upsert(row('A'));
      final s2 = await db.songs.upsert(row('B'));
      final s3 = await db.songs.upsert(row('C'));
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'A', fetchedAt: 1));
      await db.videos.upsert(const VideoRow(bvid: 'BV2', cid: 2, title: 'B', fetchedAt: 1));
      await db.bindings.upsert(BindingRow(
        songId: s1, bvid: 'BV1', isActive: true,
        matchScore: 0.9, confidence: MatchConfidence.auto,
        matchType: MatchType.autoMatched, matchedAt: 1,
      ));
      // s2 有绑定但未激活（REVIEW 候选）
      await db.bindings.upsert(BindingRow(
        songId: s2, bvid: 'BV2', isActive: false,
        matchScore: 0.7, confidence: MatchConfidence.review,
        matchType: MatchType.manualBound, matchedAt: 1,
      ));

      final map = await db.bindings.getActiveFor([s1, s2, s3]);
      expect(map.keys, {s1}, reason: '只有 s1 有激活绑定');
      expect(map[s1]!.bvid, 'BV1');
      expect(map[s1]!.isActive, isTrue);
    });

    test('入参去重、空入参返回空 Map，与逐条 getActive 结果一致', () async {
      final s1 = await db.songs.upsert(row('A'));
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'A', fetchedAt: 1));
      await db.bindings.upsert(BindingRow(
        songId: s1, bvid: 'BV1', isActive: true,
        matchScore: 0.9, confidence: MatchConfidence.auto,
        matchType: MatchType.autoMatched, matchedAt: 1,
      ));

      expect(await db.bindings.getActiveFor([]), isEmpty);
      final dup = await db.bindings.getActiveFor([s1, s1, s1]);
      expect(dup.length, 1);

      // 与逐条查询的语义对齐（批量版的正确性基准）
      final single = await db.bindings.getActive(s1);
      expect(dup[s1]!.bvid, single!.bvid);
    });
  });

  group('SongDao.getAllExcluding — 排除子查询下推（漏歌修复）', () {
    test('两种排除口径：「有任何绑定」vs「有激活绑定」', () async {
      final s1 = await db.songs.upsert(row('A'));
      final s2 = await db.songs.upsert(row('B'));
      await db.songs.upsert(row('C'));
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'A', fetchedAt: 1));
      // s1：激活绑定；s2：仅 REVIEW 候选（未激活）
      await db.bindings.upsert(BindingRow(
        songId: s1, bvid: 'BV1', isActive: true,
        matchScore: 0.9, confidence: MatchConfidence.auto,
        matchType: MatchType.autoMatched, matchedAt: 1,
      ));
      await db.bindings.upsert(BindingRow(
        songId: s2, bvid: 'BV1', isActive: false,
        matchScore: 0.7, confidence: MatchConfidence.review,
        matchType: MatchType.manualBound, matchedAt: 1,
      ));

      Set<String> titles(List<SongRow> rows) =>
          rows.map((r) => r.title).toSet();
      // unmatchedQueue 口径：有任何绑定记录就排除
      expect(
        titles(await db.songs.getAllExcluding(ExcludeScope.anyBinding)),
        {'C'},
      );
      // 批量匹配口径：只排除有激活音源的（REVIEW 也要重跑）
      expect(
        titles(await db.songs.getAllExcluding(ExcludeScope.activeBinding)),
        {'B', 'C'},
      );
      // 一条绑定都没有 → 两种口径都返回全部（NOT IN 空集语义）
      await db.db.delete('song_source_binding');
      expect(
        titles(await db.songs.getAllExcluding(ExcludeScope.anyBinding)),
        {'A', 'B', 'C'},
      );
      expect(
        titles(await db.songs.getAllExcluding(ExcludeScope.activeBinding)),
        {'A', 'B', 'C'},
      );
    });

    test('库远大于 limit 时不会被扫描窗口截断（旧写法会静默漏歌）', () async {
      // 造 20 首、绑定最新的 10 首；limit=3 的旧写法只扫前 12 首、
      // 滤掉 10 首激活后只剩 2 首 —— 第 3 首永远进不了队列。
      // created_at 是秒级时间戳，同批插入会撞值 → ORDER BY 结果不确定，
      // 所以每行显式传入递增的 now 保证排序可断言。
      String titleOf(int i) => '歌${i.toString().padLeft(2, '0')}';
      final songs = List.generate(20, (i) {
        final s = Song(
          title: titleOf(i),
          artist: '测试歌手',
          album: '专辑',
          duration: 200,
          releaseDate: DateTime(2020, 1, 1),
          coverSeed: 1,
        );
        return SongRow.fromSong(
          s,
          qqSongMid: SongRow.deriveMid(s.title, s.artist),
          now: 1700000000 + i,
        );
      });
      final ids = await db.songs.upsertAll(songs);
      await db.videos.upsert(const VideoRow(bvid: 'BV1', cid: 1, title: 'v', fetchedAt: 1));
      // created_at DESC：ids 的尾部是最新插入的 10 首
      final newest10 = ids.sublist(ids.length - 10);
      for (final sid in newest10) {
        await db.bindings.upsert(BindingRow(
          songId: sid, bvid: 'BV1', isActive: true,
          matchScore: 0.9, confidence: MatchConfidence.auto,
          matchType: MatchType.autoMatched, matchedAt: 1,
        ));
      }

      final got = await db.songs.getAllExcluding(
        ExcludeScope.activeBinding,
        limit: 3,
      );
      expect(got.length, 3, reason: '库里还有 10 首未激活的歌，不应因扫描窗口截断而拿不满');
      // 按 created_at DESC 取「最新的 3 首未激活」，即未绑定的前 10 首中最新 3 首
      final expected = ids.take(10).toList().reversed.take(3).toSet();
      expect(got.map((r) => r.id).toSet(), expected);
    });
  });

  group('MatchSampleDao — Golden Dataset 数据闭环', () {
    Song songOf(String title) => Song(
          title: title,
          artist: '测试歌手',
          album: '专辑',
          duration: 200,
          releaseDate: DateTime(2020, 1, 1),
          coverSeed: 1,
        );

    ScoredCandidate cand(String bvid, {double total = 0.9}) => ScoredCandidate(
          video: VideoCandidate(
            bvid: bvid,
            title: '测试歌手 - 歌$bvid',
            durationSec: 200,
            pubdate: 1580000000,
          ),
          total: total,
          detail: const ScoreDetail(
            s1TitleArtist: 0.9,
            s2Duration: 0.9,
            s3Uploader: 0.5,
            s4Publish: 0.5,
            s5Category: 0.5,
            s6Format: 0.5,
          ),
          confidence: MatchConfidence.auto,
        );

    Future<int> seed(String title) async {
      final songId = await db.songs.upsert(row(title));
      await db.matchSamples.insertMatchSample(
        songId: songId,
        song: songOf(title),
        result: MatchResult(
          best: cand('BVbest', total: 0.9),
          runnerUps: [cand('BVother', total: 0.8)],
        ),
        allCandidates: [cand('BVbest', total: 0.9), cand('BVother', total: 0.8)],
      );
      return songId;
    }

    Future<List<Map<String, Object?>>> sampleRows(int songId) =>
        db.matchSamples.db.query(
          Tables.matchSample,
          where: 'song_id = ?',
          whereArgs: [songId],
          orderBy: 'id',
        );

    test('快照落库，candidates_json / best_detail 是合法 JSON 且可往返', () async {
      final songId = await seed('秘密');
      final r = (await sampleRows(songId)).single;

      expect(r['best_bvid'], 'BVbest');
      expect(r['best_confidence'], 'auto');
      expect(r['margin'], closeTo(0.1, 1e-9));

      final cands = jsonDecode(r['candidates_json'] as String) as List;
      expect(cands.length, 2);
      expect(cands[0]['bvid'], 'BVbest');
      expect((cands[0]['detail'] as Map)['s1'], 0.9);

      final bestDetail = jsonDecode(r['best_detail'] as String) as Map;
      expect(bestDetail['s2'], 0.9);
    });

    test('markUserChoice：选回 best → accept（覆盖隐式接受后仍一致）', () async {
      final songId = await seed('A');
      await db.matchSamples.markAccepted(songId, 'BVbest'); // AUTO 隐式接受
      await db.matchSamples.markUserChoice(songId, 'BVbest');

      final r = (await sampleRows(songId)).single;
      expect(r['user_decision'], 'accept');
      expect(r['decision_bvid'], 'BVbest');
    });

    test('markUserChoice：改选别的 → reject + decision_bvid 记用户选择', () async {
      // 关键场景：AUTO 绑定时 markAccepted 已落 'accept'，用户事后改选
      // 必须能覆盖那次隐式接受（负样本通道，不能被 WHERE IS NULL 挡掉）。
      final songId = await seed('B');
      await db.matchSamples.markAccepted(songId, 'BVbest');
      await db.matchSamples.markUserChoice(songId, 'BVother');

      final r = (await sampleRows(songId)).single;
      expect(r['user_decision'], 'reject');
      expect(r['decision_bvid'], 'BVother');
    });

    test('同一首歌多条快照：markUserChoice 只覆盖最新一条', () async {
      final songId = await seed('C');
      // 同 ms 内连插两条也可靠（ORDER BY created_at DESC, id DESC 的 id 兜底）
      await db.matchSamples.insertMatchSample(
        songId: songId,
        song: songOf('C'),
        result: MatchResult(
          best: cand('BVnew', total: 0.7),
          runnerUps: [cand('BVlow', total: 0.6)],
        ),
        allCandidates: [cand('BVnew', total: 0.7), cand('BVlow', total: 0.6)],
      );
      await db.matchSamples.markUserChoice(songId, 'BVlow');

      final rows = await sampleRows(songId);
      expect(rows.length, 2);
      expect(rows.last['user_decision'], 'reject', reason: '最新一条被覆盖');
      expect(rows.last['decision_bvid'], 'BVlow');
      expect(rows.first['user_decision'], isNull, reason: '旧快照不动');
    });

    test('无快照时 markUserChoice / markAccepted 静默无操作', () async {
      final songId = await db.songs.upsert(row('D'));
      await db.matchSamples.markUserChoice(songId, 'BVx');
      await db.matchSamples.markAccepted(songId, 'BVx');
      expect(await db.matchSamples.db.query(Tables.matchSample), isEmpty);
    });

    test('summary：被推翻的 AUTO 不计入 auto_correct', () async {
      final a = await seed('E');
      await db.matchSamples.markAccepted(a, 'BVbest');
      final b = await seed('F');
      await db.matchSamples.markUserChoice(b, 'BVother'); // 负样本
      await seed('G'); // 未决策

      final s = await db.matchSamples.summary();
      expect(s['total'], 3);
      expect(s['auto_total'], 3);
      expect(s['auto_correct'], 1);
      expect(s['decisions_total'], 2);
      expect(s['decisions_correct'], 1);
    });
  });
}
