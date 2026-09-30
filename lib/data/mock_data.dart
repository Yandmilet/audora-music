import '../models/models.dart';

/// 原型阶段的内置数据（**仅作数据库为空时的兜底**）。
///
/// 正式运行时曲库来自 `LibraryRepository`（QQ音乐元数据 + SQLite）；
/// 这里的数据只在两种情况下出现：
///   1. 首次安装、尚未导入曲库
///   2. 数据层未接入（单测 / 纯 UI 预览）
class MockData {
  /// 地区列表已挪到 [kRegions]（models.dart）——它是领域常量，
  /// 不该被归为「演示数据」。这里保留别名只为兼容旧引用。
  static const regions = kRegions;

  /// 主库 —— 30 首，覆盖中日韩欧美
  static final List<Song> songs = [
    // ---- 华语 ----
    Song(title: '起风了', artist: '买辣椒也用券', album: '起风了', duration: 325,
        lyricist: '米果', composer: '高橋優', arranger: '池窪俊也',
        genre: '流行', releaseDate: DateTime(2017, 12, 24), coverSeed: 0,
        source: _src('BV1Js411M7Zq', 0, 0.93, true, 2, '音乐搬运工', 1284000)),
    Song(title: '无名的人', artist: '毛不易', album: '平凡的一天', duration: 271,
        lyricist: '唐恬', composer: '钱雷', genre: '流行',
        releaseDate: DateTime(2018, 6, 26), coverSeed: 1,
        source: _src('BV1ft411o7aS', 3, 0.91, true, 1, '毛不易的坑', 892000)),
    Song(title: '消愁', artist: '毛不易', album: '平凡的一天', duration: 275,
        lyricist: '毛不易', composer: '毛不易', genre: '民谣',
        releaseDate: DateTime(2017, 8, 26), coverSeed: 2,
        source: _src('BV1ZW411u7XM', 1, 0.94, true, 0, '明日之子官方', 2310000)),
    Song(title: '夜曲', artist: '周杰伦', album: '十一月的萧邦', duration: 227,
        lyricist: '方文山', composer: '周杰伦', arranger: '林迈可',
        genre: 'R&B', releaseDate: DateTime(2005, 11, 1), coverSeed: 3,
        source: _src('BV1Wx411B7ky', 0, 0.96, true, 0, 'JayCn', 3102000)),
    Song(title: '青花瓷', artist: '周杰伦', album: '我很忙', duration: 239,
        lyricist: '方文山', composer: '周杰伦', genre: '中国风',
        releaseDate: DateTime(2007, 11, 2), coverSeed: 4,
        source: _src('BV1Gs411x7Yw', 2, 0.95, true, 1, 'JayCn', 2870000)),
    Song(title: '晴天', artist: '周杰伦', album: '叶惠美', duration: 269,
        lyricist: '周杰伦', composer: '周杰伦', genre: '流行',
        releaseDate: DateTime(2003, 7, 31), coverSeed: 5,
        source: _src('BV1yx411c7Wt', 0, 0.97, true, 0, 'JayCn', 4210000)),
    Song(title: '稻香', artist: '周杰伦', album: '魔杰座', duration: 223,
        lyricist: '周杰伦', composer: '周杰伦', genre: '流行',
        releaseDate: DateTime(2008, 10, 15), coverSeed: 6,
        source: _src('BV1Ex411k7Vh', 1, 0.95, true, 0, 'JayCn', 3380000)),
    Song(title: '后来', artist: '刘若英', album: '我等你', duration: 337,
        lyricist: '施人诚', composer: '玉城千春', genre: '流行',
        releaseDate: DateTime(1999, 12, 1), coverSeed: 7,
        source: _src('BV1Jx411q7Wv', 0, 0.92, true, 3, '华语老歌库', 1520000)),
    Song(title: '突然好想你', artist: '五月天', album: '后青春期的诗', duration: 336,
        lyricist: '阿信', composer: '阿信', genre: '摇滚',
        releaseDate: DateTime(2008, 10, 2), coverSeed: 8,
        source: _src('BV1mx411P7Xy', 4, 0.90, true, 2, '五月天资源站', 1870000)),
    Song(title: '干杯', artist: '五月天', album: '第二人生', duration: 310,
        lyricist: '阿信', composer: '阿信', genre: '摇滚',
        releaseDate: DateTime(2011, 12, 16), coverSeed: 9,
        source: _src('BV1Sx411a7Zc', 2, 0.89, true, 1, '五月天资源站', 980000)),
    Song(title: '海阔天空', artist: 'Beyond', album: '乐与怒', duration: 326,
        lyricist: '黄家驹', composer: '黄家驹', genre: '摇滚',
        releaseDate: DateTime(1993, 5, 1), coverSeed: 10,
        source: _src('BV1fx411R7Bq', 0, 0.94, true, 0, 'Beyond歌迷会', 2640000)),
    Song(title: '光辉岁月', artist: 'Beyond', album: '命运派对', duration: 293,
        lyricist: '黄家驹', composer: '黄家驹', genre: '摇滚',
        releaseDate: DateTime(1990, 9, 1), coverSeed: 11,
        source: _src('BV1cx411T7Dm', 1, 0.93, true, 2, 'Beyond歌迷会', 2130000)),
    Song(title: '富士山下', artist: '陈奕迅', album: 'What\'s Going On...?', duration: 255,
        lyricist: '林夕', composer: '泽日生', genre: '流行',
        releaseDate: DateTime(2006, 11, 1), coverSeed: 12,
        source: _src('BV1Gx411e7Kn', 0, 0.95, true, 0, 'Eason音乐馆', 1980000)),
    Song(title: '月亮代表我的心', artist: '邓丽君', album: '岛国之情歌第四集', duration: 206,
        lyricist: '孙仪', composer: '翁清溪', genre: '流行',
        releaseDate: DateTime(1977, 3, 1), coverSeed: 13,
        source: _src('BV1Dx411n7Ss', 3, 0.91, true, 4, '怀旧金曲', 1240000)),

    // ---- 同名异曲：待确认场景 ----
    Song(title: '起风了', artist: '吴青峰', album: '歌手2019', duration: 289,
        lyricist: '米果', composer: '高橋優', genre: '流行',
        releaseDate: DateTime(2019, 1, 11), coverSeed: 14,
        sourceStatus: SourceStatus.pending,
        source: _src('BV1Xt411z7Yw', 0, 0.68, false, -36, '综艺剪辑站', 420000)),

    // ---- 日本 ----
    Song(title: 'Lemon', artist: '米津玄師', album: 'BOOTLEG', duration: 256,
        lyricist: '米津玄師', composer: '米津玄師', genre: 'J-Pop',
        releaseDate: DateTime(2018, 3, 14), coverSeed: 15,
        source: _src('BV1oW411N7hL', 0, 0.96, true, 0, '米津玄師 Official', 5620000)),
    Song(title: 'Pretender', artist: 'Official髭男dism', album: 'Traveler', duration: 326,
        lyricist: '藤原聡', composer: '藤原聡', genre: 'J-Pop',
        releaseDate: DateTime(2019, 4, 17), coverSeed: 16,
        source: _src('BV1dJ411K7fR', 1, 0.94, true, 1, 'Official髭男dism', 2310000)),
    Song(title: '打上花火', artist: 'DAOKO × 米津玄師', album: '打上花火', duration: 290,
        lyricist: '米津玄師', composer: '米津玄師', genre: 'J-Pop',
        releaseDate: DateTime(2017, 8, 16), coverSeed: 17,
        source: _src('BV1px411H7Vc', 0, 0.93, true, 2, '动漫音乐社', 3120000)),
    Song(title: '残酷な天使のテーゼ', artist: '高橋洋子', album: 'Neon Genesis Evangelion', duration: 245,
        lyricist: '及川眠子', composer: '佐藤英敏', genre: '动漫',
        releaseDate: DateTime(1995, 10, 25), coverSeed: 18,
        source: _src('BV1Xx411g7Tp', 2, 0.92, true, 0, 'EVA资料库', 2760000)),
    Song(title: '紅蓮華', artist: 'LiSA', album: '鬼滅の刃', duration: 234,
        lyricist: 'LiSA', composer: '草野華余子', genre: '动漫',
        releaseDate: DateTime(2019, 4, 22), coverSeed: 19,
        source: _src('BV1zJ411T7wQ', 0, 0.95, true, 0, 'LiSA Official', 3480000)),
    Song(title: '夜に駆ける', artist: 'YOASOBI', album: 'THE BOOK', duration: 261,
        lyricist: 'Ayase', composer: 'Ayase', genre: 'J-Pop',
        releaseDate: DateTime(2019, 11, 16), coverSeed: 20,
        source: _src('BV1eJ411B7rK', 1, 0.96, true, 0, 'YOASOBI', 4890000)),

    // ---- 韩国 ----
    Song(title: 'Ditto', artist: 'NewJeans', album: 'OMG', duration: 185,
        lyricist: '闵熙珍', composer: '250', genre: 'K-Pop',
        releaseDate: DateTime(2022, 12, 19), coverSeed: 21,
        source: _src('BV1AP411B7mH', 0, 0.97, true, 0, 'HYBE LABELS', 6720000)),
    Song(title: 'Hype Boy', artist: 'NewJeans', album: 'NewJeans', duration: 179,
        lyricist: '闵熙珍', composer: '250', genre: 'K-Pop',
        releaseDate: DateTime(2022, 8, 1), coverSeed: 22,
        source: _src('BV1wG411b7Xc', 2, 0.95, true, 1, 'HYBE LABELS', 5410000)),
    Song(title: 'Dynamite', artist: 'BTS', album: 'Dynamite', duration: 199,
        lyricist: 'David Stewart', composer: 'David Stewart', genre: 'K-Pop',
        releaseDate: DateTime(2020, 8, 21), coverSeed: 23,
        source: _src('BV1iT4y1L7aK', 0, 0.98, true, 0, 'BIGHIT MUSIC', 8930000)),
    Song(title: 'How You Like That', artist: 'BLACKPINK', album: 'THE ALBUM', duration: 182,
        lyricist: 'TEDDY', composer: 'TEDDY', genre: 'K-Pop',
        releaseDate: DateTime(2020, 6, 26), coverSeed: 24,
        source: _src('BV1BK4y1x7Qm', 1, 0.96, true, 0, 'BLACKPINK', 7210000)),

    // ---- 欧美 ----
    Song(title: 'Blinding Lights', artist: 'The Weeknd', album: 'After Hours', duration: 200,
        lyricist: 'Abel Tesfaye', composer: 'Abel Tesfaye', genre: 'Synth-pop',
        releaseDate: DateTime(2019, 11, 29), coverSeed: 25,
        source: _src('BV1RJ411B7kR', 0, 0.98, true, 0, 'The Weeknd', 9540000)),
    Song(title: 'Shape of You', artist: 'Ed Sheeran', album: '÷', duration: 233,
        lyricist: 'Ed Sheeran', composer: 'Ed Sheeran', genre: 'Pop',
        releaseDate: DateTime(2017, 1, 6), coverSeed: 26,
        source: _src('BV1Ss411R7Tv', 3, 0.97, true, 0, 'Ed Sheeran', 8920000)),
    Song(title: 'Someone Like You', artist: 'Adele', album: '21', duration: 285,
        lyricist: 'Adele', composer: 'Adele', genre: 'Soul',
        releaseDate: DateTime(2011, 1, 24), coverSeed: 27,
        source: _src('BV1Js411K7Wm', 0, 0.96, true, 2, 'Adele', 6310000)),
    Song(title: 'Bohemian Rhapsody', artist: 'Queen', album: 'A Night at the Opera', duration: 354,
        lyricist: 'Freddie Mercury', composer: 'Freddie Mercury', genre: 'Rock',
        releaseDate: DateTime(1975, 10, 31), coverSeed: 28,
        sourceStatus: SourceStatus.pending,
        source: _src('BV1Nx411z7Pq', 5, 0.74, false, 18, '经典摇滚馆', 2180000)),
    Song(title: 'Stay', artist: 'The Kid LAROI & Justin Bieber', album: 'F*CK LOVE 3', duration: 141,
        lyricist: 'Justin Bieber', composer: 'Justin Bieber', genre: 'Pop',
        releaseDate: DateTime(2021, 7, 9), coverSeed: 29,
        source: _src('BV1nL411x7Yq', 0, 0.95, true, 0, 'Justin Bieber', 5820000)),

    // ---- 无音源场景 ----
    Song(title: '漠河舞厅', artist: '柳爽', album: '漠河舞厅', duration: 267,
        lyricist: '柳爽', composer: '柳爽', genre: '民谣',
        releaseDate: DateTime(2021, 3, 12), coverSeed: 30,
        sourceStatus: SourceStatus.none),
  ];

  static AudioSource _src(String bvid, int cid, double score, bool auto,
      int delta, String uploader, int plays) {
    return AudioSource(
      bvid: bvid,
      cid: 1000000 + cid * 137,
      qualityLabel: '192Kbps',
      qualityId: 30280,
      matchScore: score,
      auto: auto,
      durationDelta: delta,
      uploader: uploader,
      playCount: plays,
    );
  }

  /// 新歌推荐（按发行时间取最新 8 首）
  static List<Song> get newSongs {
    final list = [...songs]..sort((a, b) {
        final da = a.releaseDate ?? DateTime(1900);
        final db = b.releaseDate ?? DateTime(1900);
        return db.compareTo(da);
      });
    return list.take(8).toList();
  }

  /// 排行榜
  static final List<Board> boards = [
    Board(
      name: '华语新歌榜', region: 'cn', regionLabel: '中国内地',
      songs: songs.where((s) => s.artist == '买辣椒也用券' || s.artist == '毛不易' || s.artist == '周杰伦').toList(),
    ),
    Board(
      name: '华语热歌榜', region: 'cn', regionLabel: '中国内地',
      songs: songs.where((s) => ['周杰伦', '刘若英', '五月天'].contains(s.artist)).toList(),
    ),
    Board(
      name: '粤语榜', region: 'cn', regionLabel: '中国香港',
      songs: songs.where((s) => ['Beyond', '陈奕迅', '邓丽君'].contains(s.artist)).toList(),
    ),
    Board(
      name: '日本 Oricon 周榜', region: 'jp', regionLabel: '日本',
      songs: songs.where((s) => ['米津玄師', 'Official髭男dism', 'DAOKO × 米津玄師', 'YOASOBI'].contains(s.artist)).toList(),
    ),
    Board(
      name: '日系动漫歌曲榜', region: 'jp', regionLabel: '日本',
      songs: songs.where((s) => s.genre == '动漫').toList(),
    ),
    Board(
      name: 'Melon 周榜', region: 'kr', regionLabel: '韩国',
      songs: songs.where((s) => ['NewJeans', 'BTS', 'BLACKPINK'].contains(s.artist)).toList(),
    ),
    Board(
      name: 'Billboard Hot 100', region: 'us', regionLabel: '欧美',
      songs: songs.where((s) => ['The Weeknd', 'Ed Sheeran', 'Adele', 'Queen', 'The Kid LAROI & Justin Bieber'].contains(s.artist)).toList(),
    ),
  ];

  /// 搜索历史
  static const searchHistory = ['周杰伦', '米津玄師', '起风了', 'NewJeans', '粤语老歌'];

  /// 常听
  static List<Song> get hotSongs => [songs[3], songs[15], songs[21], songs[25], songs[5]];
}
