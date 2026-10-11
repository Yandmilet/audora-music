/// 「收藏」列表左侧小封面必须是**真实专辑封面**。
///
/// ## 缺陷原状（2026-10-09 用户反馈）
/// 「我的」页 → 收藏 的歌曲列表，左侧 46px 小封面显示的是
/// [CoverArt] 的**渐变占位块**（几张固定配色的气泡图），完全不是真实封面。
///
/// 根因在当时 `mine_screen.dart` 的 `_SongListPage`：
///
/// ```dart
/// leading: CoverArt(seed: s.coverSeed, size: 46, radius: Tokens.rSm)
/// ```
///
/// [CoverArt] 是**纯本地绘制**的占位图（渐变 + 两个圆点），它不接受 URL
/// 参数——写在这里等于把真实封面这条路整个放弃了。
/// 同一个 App 的搜索页、播放队列、迷你播放器早已换成 [SongCover]
/// （真实图 + 占位兜底），只有列表页这一处还停在占位阶段。
///
/// 2026-10-11 这个列表页被提成公共的 `screens/song_list_page.dart`
/// （收藏 + 首页「最近听过」共用），本测试随之盯住 [SongListPage]。
///
/// ## 为什么这个缺陷不抛异常、也看不到报错
/// [CoverArt] 是完全合法的 widget，编译运行都正常，只是**内容不对**。
/// 而渐变占位看起来「不是裂图」，肉眼扫列表容易以为是主题配色。
/// 只有逐行和搜索页对比、或直接问用户才会发现。所以这里用 widget test
/// 把「这里的 leading 必须是 [SongCover]」钉死。
///
/// ## 本测试的断言口径
/// 1. **数据链可达**：`albumMid` → `coverUrl` 确实拼出了真实 QQ CDN 图。
///    这条断了的话，UI 换对组件也还是只有占位图。用内存 SQLite 走完整
///    Repository 链路验证，不靠手搓元数据。
/// 2. **组件形态**：列表的小封面是 [SongCover]，且 [CoverArt] 只以内部
///    兜底层的身份出现。
/// 3. **回退是正确行为**：`albumMid` 为空（mock/来源不明的歌）时
///    `coverUrl` 为 null，此时露出占位渐变**不是 bug**，一并锁住。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/rows.dart' as dbrow;
import 'package:audora_music/models/models.dart';
import 'package:audora_music/screens/mine_screen.dart';
import 'package:audora_music/services/qqmusic/qqmusic_dto.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:audora_music/widgets/common.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _dbSeq = 0;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('albumMid → coverUrl 拼装（UI 能拿到真封面的前提）', () {
    late AppDatabase db;

    setUp(() async {
      final seq = _dbSeq++;
      db = await AppDatabase.open(
        path: 'file:cover$seq?mode=memory&cache=shared',
      );
    });

    tearDown(() async => db.close());

    test('落库时带 albumMid → Song.coverUrl 是真实 QQ CDN 图', () async {
      // 用 QQSongMeta 这条真实入口入库（目录 / 搜索 / 按需匹配都是它），
      // 而不是手写 SongRow —— 要测的是「真实链路上封面 URL 会不会丢」。
      const meta = QQSongMeta(
        songMid: 'songMid001',
        title: '晴天',
        artists: ['周杰伦'],
        album: '叶惠美',
        albumMid: '003RMaRI1iFoYd',
        interval: 269,
      );

      await db.songs.upsert(dbrow.SongRow.fromSong(
        meta.toSong(),
        qqSongMid: meta.songMid,
        albumMid: meta.albumMid,
        now: 1000,
      ));

      final row = (await db.songs.getByMid('songMid001'))!;
      final song = row.toSong();

      // ★ 核心：读回的对象必须带真实封面 URL。
      // 为空时 UI 无论换成什么组件都只能显示占位渐变。
      expect(song.coverUrl, isNotNull,
          reason: 'albumMid 落库了，读回却拿不到封面 URL——'
              'SongRow.toSong 的拼装断了');
      expect(
          song.coverUrl,
          equals('https://y.gtimg.cn/music/photo_new/T002R300x300M000'
              '003RMaRI1iFoYd.jpg'),
          reason: '封面 URL 必须由 album_mid 按 QQ 音乐 CDN 规则拼出');
    });

    test('albumMid 为空 → coverUrl 为 null（UI 应回退渐变占位）', () async {
      await db.songs.upsert(dbrow.SongRow.fromSong(
        const Song(
          title: '老歌',
          artist: '老歌手',
          album: '',
          duration: 200,
          coverSeed: 3,
        ),
        qqSongMid: 'local:noalbum',
        now: 1000,
      ));

      final song = (await db.songs.getByMid('local:noalbum'))!.toSong();

      expect(song.coverUrl, isNull,
          reason: '没有 albumMid 时不该拼出一个必然 404 的 URL');
      // 兜底占位索引仍在——这是「回退到渐变」的正确姿势
      expect(song.coverSeed, 3);
    });
  });

  group('SongCover：真封面优先、占位兜底', () {
    testWidgets('coverUrl 有值 → 真的去加载网络图，占位只做兜底', (tester) async {
      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
        coverUrl:
            'https://y.gtimg.cn/music/photo_new/T002R300x300M000003RMaRI1iFoYd.jpg',
      );

      await tester.pumpWidget(const MaterialApp(
        home: RepaintBoundary(
          child: Center(child: SongCover(song: song, size: 46)),
        ),
      ));
      await tester.pump();

      expect(find.byType(CoverArt), findsOneWidget,
          reason: '占位兜底层必须在，否则网络图失败时是空白');
      expect(find.byType(CachedNetworkImage), findsOneWidget,
          reason: '有 coverUrl 就必须发起真实封面加载——'
              '少这一层就是「小封面不显示真实封面」本身');
    });

    testWidgets('coverUrl 为 null → 不建网络图，只剩渐变占位', (tester) async {
      const song = Song(
        title: '老歌',
        artist: '老歌手',
        album: '',
        duration: 200,
        coverSeed: 3,
      );

      await tester.pumpWidget(const MaterialApp(
        home: RepaintBoundary(
          child: Center(child: SongCover(song: song, size: 46)),
        ),
      ));
      await tester.pump();

      expect(find.byType(CoverArt), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNothing,
          reason: '没有 URL 时不该打一个必然 404 的请求');
    });
  });

  group('收藏列表的小封面组件形态', () {
    testWidgets('收藏列表每行 leading 是 SongCover（不是裸 CoverArt）',
        (tester) async {
      // repo = null → mock 模式，构造里会给每第 5 首点红心，
      // 所以「收藏」列表一定有内容，足以验证组件形态。
      final st = AppState();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MineScreen(st: st)),
      ));
      await tester.pumpAndSettle();

      // 「收藏」在「我的」页出现两次：数据卡的统计标签 + 入口卡标题。
      // 用**字号 14/w800** 的入口卡标题定位（统计标签是 11px），
      // 否则 findsOneWidget 会因为两个都命中而失败。
      final entry = find.widgetWithText(InkWell, '收藏');
      expect(entry, findsWidgets);
      await tester.tap(entry.first);
      await tester.pumpAndSettle();

      expect(find.byType(SongRow), findsWidgets);

      // ★ 回归断言：列表里必须有 SongCover。
      // 改回 `CoverArt(seed: s.coverSeed, ...)` 时这里一条都不剩。
      expect(find.byType(SongCover), findsWidgets,
          reason: '收藏列表的小封面必须是 SongCover——'
              '用裸 CoverArt 会让真实封面永远不显示');

      await tester.pumpWidget(const SizedBox.shrink());
      st.dispose();
    });
  });
}
