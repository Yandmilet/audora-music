/// 歌词译文：语种判定、时间轴对齐、以及「只有非华语歌才去补译文」这条规则。
///
/// ## 为什么单独测
/// 译文是**第二条数据源**拼上来的，天然有「拼错」的风险：
/// 语种判反（中文歌白跑一趟 / 外语歌没译文）、时间轴串行（译文跟着错的原文）、
/// 头部创作者行占掉对齐名额。这三种错误都不会报错，只会安静地显示错内容，
/// 只能靠断言锁住。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:audora2/data/db/app_database.dart';
import 'package:audora2/data/db/rows.dart';
import 'package:audora2/data/repository/library_repository.dart';
import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_api.dart';
import 'package:audora2/services/bilibili/bili_api_client.dart';
import 'package:audora2/services/lyric/lrc_parser.dart';
import 'package:audora2/services/lyric/lyric_translation.dart';
import 'package:audora2/services/match/match_engine.dart';
import 'package:audora2/services/metadata/qqmusic_metadata_adapter.dart';
import 'package:audora2/services/netease/netease_provider.dart';
import 'package:audora2/services/qqmusic/qqmusic_dto.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:audora2/services/source/bili_audio_source_adapter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('looksNonChinese', () {
    test('英文歌词判为非华语', () {
      expect(
        looksNonChinese([
          "It's been a long day without you my friend",
          'And I will tell you all about it when I see you again',
        ]),
        isTrue,
      );
    });

    test('日文歌词（含汉字但有假名）判为非华语', () {
      // ★ 这条守住的是「只看汉字比例会误判」的坑：
      // 日文歌的汉字占比很高，但有假名就必须算外语
      expect(
        looksNonChinese(['夢ならばどれほどよかったでしょう', '胸に残り離れない']),
        isTrue,
      );
    });

    test('韩文歌词判为非华语', () {
      expect(looksNonChinese(['보고 싶다 이렇게 말해도']), isTrue);
    });

    test('中文歌词判为华语', () {
      expect(
        looksNonChinese(['这一路上走走停停', '顺着少年漂流的痕迹']),
        isFalse,
      );
    });

    test('空内容不算非华语（保守，避免无谓请求）', () {
      expect(looksNonChinese([]), isFalse);
      expect(looksNonChinese(['', '  ']), isFalse);
    });
  });

  group('attachTranslation 时间轴对齐', () {
    const main = '[00:01.00]Hello\n[00:05.00]World\n[00:09.00]Again';

    test('时间完全对得上时逐行挂译文', () {
      final p = attachTranslation(
        parseLrc(main),
        '[00:01.00]你好\n[00:05.00]世界\n[00:09.00]再次',
      );
      expect(p.lines.map((l) => l.translation).toList(),
          ['你好', '世界', '再次']);
      expect(p.hasTranslation, isTrue);
    });

    test('容差内的偏移（1.2s）仍然对齐', () {
      final p = attachTranslation(
        parseLrc(main),
        '[00:02.20]你好\n[00:06.00]世界',
      );
      expect(p.lines[0].translation, '你好');
      expect(p.lines[1].translation, '世界');
      expect(p.lines[2].translation, isNull, reason: '译文用完了');
    });

    test('超出容差的不硬凑', () {
      final p = attachTranslation(
        parseLrc(main),
        '[00:20.00]你好',
        tolerance: const Duration(milliseconds: 1500),
      );
      expect(p.lines.any((l) => l.translation != null), isFalse);
    });

    test('译文轨头部的创作者行被过滤，不会占掉第一句', () {
      final p = attachTranslation(
        parseLrc('[00:10.00]Hello\n[00:14.00]World'),
        '[00:00.000] 作词 : 米津玄師\n'
            '[00:00.200] 作曲 : 米津玄師\n'
            '[00:10.10]你好\n'
            '[00:14.10]世界',
      );
      expect(p.lines[0].translation, '你好',
          reason: '创作者行必须在对齐前剔除，否则首句挂到"作词"上');
      expect(p.lines[1].translation, '世界');
    });

    test('译文与原文相同时不显示（避免中文歌被误配时重复两行）', () {
      final p = attachTranslation(
        parseLrc('[00:01.00]同一句话'),
        '[00:01.00]同一句话',
      );
      expect(p.lines[0].translation, isNull);
      expect(p.hasTranslation, isFalse);
    });

    test('译文把两句原文合成一句时，挂给时间更接近的那行', () {
      // ★ 真实案例（See You Again）：网易把
      //   Damn who knew / All the planes we flew 合成一条译文。
      //   中间那行的偏差（1.2s）也在容差内，但它**不该**抢走属于下一行的译文。
      final p = attachTranslation(
        parseLrc(
          '[00:40.27]Damn who knew\n'
          '[00:41.70]All the planes we flew\n'
          '[00:43.28]Good things we been through\n'
          '[00:45.08]That I’d be standing right here',
        ),
        '[00:39.92]谁会了解我们经历过怎样的旅程\n'
            '[00:42.90]谁会了解我们见证过怎样的美好\n'
            '[00:44.61]我都会在这里',
      );
      expect(p.lines[0].translation, '谁会了解我们经历过怎样的旅程');
      expect(p.lines[1].translation, isNull);
      expect(p.lines[2].translation, '谁会了解我们见证过怎样的美好');
      expect(p.lines[3].translation, '我都会在这里');
    });

    test('标题行与词曲行不抢走第一句译文', () {
      // ★ 真实案例（Lemon）：网易首句译文在 0.851s，QQ 的 0s 是
      //   "Lemon - 米津玄師" 标题行。没有这条守卫，第一句日文就没有译文。
      final p = attachTranslation(
        parseLrc(
          '[00:00.00]Lemon - 米津玄師\n'
          '[00:00.53]词：米津玄師\n'
          '[00:01.54]夢ならば\n'
          '[00:02.88]どれほどよかったでしょう',
        ),
        '[00:00.851]如果这一切都是梦境该有多好\n'
            '[00:06.65]至今仍能与你在梦中相遇',
      );
      expect(p.lines[0].translation, isNull);
      expect(p.lines[1].translation, isNull);
      expect(p.lines[2].translation, '如果这一切都是梦境该有多好');
      expect(p.lines[3].translation, isNull);
    });

    test('演唱者提示行（Charlie Puth：）不挂译文', () {
      final p = attachTranslation(
        parseLrc('[00:09.16]Charlie Puth：\n[00:10.99]It’s been a long day'),
        '[00:10.44]没有老友你的陪伴 日子真是漫长',
      );
      expect(p.lines[0].translation, isNull);
      expect(p.lines[1].translation, '没有老友你的陪伴 日子真是漫长');
    });

    test('译文为空 / 缺失时原样返回', () {
      final base = parseLrc(main);
      expect(attachTranslation(base, null).lines.length, 3);
      expect(attachTranslation(base, '   ').hasTranslation, isFalse);
      expect(attachTranslation(base, '没有时间标签的纯文本').hasTranslation, isFalse);
    });

    test('原文为空时不处理', () {
      expect(attachTranslation(ParsedLyric.empty, '[00:01.00]x').isEmpty,
          isTrue);
    });
  });

  group('NeteaseProvider 取译文', () {
    test('搜索命中后返回 tlyric，且译文为空串时视为无译文', () async {
      final adapter = _FakeAdapter({
        '/api/search/get/web': jsonEncode({
          'code': 200,
          'result': {
            'songs': [
              {
                'id': 536622304,
                'name': 'Lemon',
                'artists': [
                  {'name': '米津玄師'}
                ],
              }
            ]
          },
        }),
        '/api/song/lyric': jsonEncode({
          'code': 200,
          'lrc': {'lyric': '[00:00.851]夢ならば'},
          'tlyric': {'lyric': '[00:00.851]如果这一切都是梦境'},
        }),
      });
      final dio = Dio()..httpClientAdapter = adapter;

      final ne = NeteaseProvider(dio: dio);
      final t = await ne.fetchTranslationLrc(
        title: 'Lemon',
        artist: '米津玄師',
      );
      // 搜索 + 歌词两步都走到了（path 是完整 URL，按后缀断言）
      expect(
        adapter.visited.any((p) => p.endsWith('/api/search/get/web')),
        isTrue,
      );
      expect(
        adapter.visited.any((p) => p.endsWith('/api/song/lyric')),
        isTrue,
      );
      expect(t, contains('如果这一切都是梦境'));
    });

    test('搜索结果对不上（歌名不同）则不采信，返回 null', () async {
      final dio = Dio()..httpClientAdapter = _FakeAdapter({
        '/api/search/get/web': jsonEncode({
          'code': 200,
          'result': {
            'songs': [
              {
                'id': 1,
                'name': '完全不相干的另一首歌',
                'artists': [
                  {'name': '别人'}
                ],
              }
            ]
          },
        }),
      });
      final ne = NeteaseProvider(dio: dio);
      expect(
        await ne.fetchTranslationLrc(title: 'Lemon', artist: '米津玄師'),
        isNull,
      );
    });

    test('歌手名带重音（Céline Dion）也能匹配上', () async {
      // 真实差异：网易写 "Céline Dion"，QQ 写 "Celine Dion"。
      // contains 判不中，必须靠 fuzzy 兜住。
      final dio = Dio()..httpClientAdapter = _FakeAdapter({
        '/api/search/get/web': jsonEncode({
          'code': 200,
          'result': {
            'songs': [
              {
                'id': 99,
                'name': 'My Heart Will Go On',
                'artists': [
                  {'name': 'Céline Dion'}
                ],
              }
            ]
          },
        }),
        '/api/song/lyric': jsonEncode({
          'code': 200,
          'tlyric': {'lyric': '[00:20.28]每一个夜晚，在我的梦里'},
        }),
      });
      final ne = NeteaseProvider(dio: dio);
      expect(
        await ne.fetchTranslationLrc(
          title: 'My Heart Will Go On',
          artist: 'Celine Dion',
        ),
        contains('每一个夜晚'),
      );
    });

    test('歌词接口异常时静默返回 null', () async {
      final dio = Dio()..httpClientAdapter = _ThrowingAdapter();
      final ne = NeteaseProvider(dio: dio);
      expect(
        await ne.fetchTranslationLrc(title: 'x', artist: 'y'),
        isNull,
      );
    });
  });

  group('Repository：只有非华语歌才补译文', () {
    late AppDatabase db;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:lyrictrans$seq?mode=memory&cache=shared',
      );
    });

    tearDown(() async => db.close());

    Future<LyricBundle?> runFetch({
      required String mid,
      required String title,
      required String artist,
      required String lrc,
      _StubNetease? ne,
    }) async {
      final id = await db.songs.upsert(SongRow.fromSong(
        Song(title: title, artist: artist, duration: 200, coverSeed: 0),
        qqSongMid: mid,
        now: 1000,
      ));
      final repo = LibraryRepository(
        db: db,
        engine: _NoopEngine(),
        metadata: QQMusicMetadataAdapter(_StubQQ(lrc)),
        netease: ne,
      );
      final song = (await db.songs.getById(id))!.toSong();
      return repo.fetchLyric(song);
    }

    test('英文歌会去网易补译文，并标记来源', () async {
      final ne = _StubNetease('[00:01.00]你好');
      final b = await runFetch(
        mid: 'realMid',
        title: 'See You Again',
        artist: 'Wiz Khalifa',
        lrc: "[00:01.00]It's been a long day",
        ne: ne,
      );
      expect(b!.translation, '[00:01.00]你好');
      expect(b.translationSource, 'netease');
      expect(ne.calls, 1);
    });

    test('中文歌不打网易（省两次无用请求）', () async {
      final ne = _StubNetease('[00:01.00]这一路上走走停停');
      final b = await runFetch(
        mid: 'realMid',
        title: '起风了',
        artist: '买辣椒也用券',
        lrc: '[00:01.00]这一路上走走停停\n[00:05.00]顺着少年漂流的痕迹',
        ne: ne,
      );
      expect(b!.translation, isNull);
      expect(ne.calls, 0,
          reason: '中文歌的译文就是原文自己，请求网易纯属浪费');
    });

    test('QQ 自带译文时优先用 QQ，不再请求网易', () async {
      final ne = _StubNetease('[00:01.00]备用');
      final id = await db.songs.upsert(SongRow.fromSong(
        const Song(
          title: 'Some Song',
          artist: 'Someone',
          duration: 100,
          coverSeed: 0,
        ),
        qqSongMid: 'realMid',
        now: 1000,
      ));
      final repo = LibraryRepository(
        db: db,
        engine: _NoopEngine(),
        metadata: QQMusicMetadataAdapter(
          _StubQQ('[00:01.00]Hello', trans: '[00:01.00]你好'),
        ),
        netease: ne,
      );
      final song = (await db.songs.getById(id))!.toSong();
      final b = await repo.fetchLyric(song);

      expect(b!.translation, '[00:01.00]你好');
      expect(b.translationSource, 'qq');
      expect(ne.calls, 0);
    });

    test('未注入网易源时功能降级（只有原文，不报错）', () async {
      final b = await runFetch(
        mid: 'realMid',
        title: 'Dynamite',
        artist: 'BTS',
        lrc: '[00:01.00]Cause I I I',
      );
      expect(b, isNotNull);
      expect(b!.translation, isNull);
    });
  });
}

// ── 桩 ───────────────────────────────────────────────────

class _NoopEngine extends MatchEngine {
  _NoopEngine() : super(BiliAudioSourceAdapter(BiliApi(BiliApiClient())));
}

class _StubQQ extends QQMusicProvider {
  _StubQQ(this.lrc, {this.trans}) : super(dio: Dio());

  final String lrc;
  final String? trans;

  @override
  Future<QQLyric?> fetchLyric(String songMid) async =>
      QQLyric(lrc: lrc, trans: trans, credits: QQCredits.empty);
}

class _StubNetease extends NeteaseProvider {
  _StubNetease(this.trans) : super(dio: Dio());

  final String? trans;
  int calls = 0;

  @override
  Future<String?> fetchTranslationLrc({
    required String title,
    required String artist,
  }) async {
    calls++;
    return trans;
  }
}

/// 按 path 返回固定响应体的 Dio 适配器（测试不走真实网络）
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, String> routes;
  final List<String> visited = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    visited.add(options.path);
    // ⚠️ 用绝对 URL 调 dio.get 时 options.path 是**完整 URL**，
    // 不是 "/api/xxx"。按后缀匹配才是稳的。
    var body = '{}';
    for (final e in routes.entries) {
      if (options.path.endsWith(e.key)) {
        body = e.value;
        break;
      }
    }
    return ResponseBody.fromString(body, 200, headers: const {});
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionTimeout(
      timeout: const Duration(seconds: 1),
      requestOptions: options,
    );
  }

  @override
  void close({bool force = false}) {}
}
