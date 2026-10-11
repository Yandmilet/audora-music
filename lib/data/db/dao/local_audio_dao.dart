/// `local_audio` 表的读写（本机音频文件：自带扫描 + app 下载）。
///
/// ## 两类条目共用一张表、一套 DAO，但**绝不混列**
/// 所有查询都带 `kind` 条件。「本地」列表只可能出 kind=local，「下载」列表
/// 只可能出 kind=download——这是产品明确要求的隔离（两个目录、两份清单，
/// 互相看不到）。唯一的跨类操作是 `deleteAllOfKind`（清理某一类）。
///
/// ## 扫描用「时间戳换血」而不是 `NOT IN (…)`
/// 重扫一遍手机后，这一轮没再出现的条目就该消失。直觉写法是
/// `DELETE WHERE uri NOT IN (本轮全部 uri)`，但手机上媒体库轻松上千条，
/// SQLite 默认变量上限 999，一条语句就崩。改成两段：
///   1. 本轮每条都盖 `last_seen = <本次扫描时刻>`
///   2. `DELETE WHERE kind = ? AND last_seen < <本次扫描时刻>`
/// 一条参数都不多占，还天然幂等（同一时刻重跑结果一致）。
///
/// ## uri 是唯一键，first_seen 不许被覆盖
/// 同一首歌在手机上不会有两个 uri；但扫描会反复遇到同一条。upsert 时
/// 只更新元数据与 last_seen，**first_seen 保留最早那次**——「什么时候开始
/// 有这首歌」是用户能感知的信息，不能被一次重扫抹平。
library;

import 'package:sqflite/sqflite.dart';

import '../schema.dart';

/// 条目来源。存库是字符串（可读、可 CHECK），不在 SQL 里写魔法数字。
enum LocalAudioKind {
  /// 手机自带音频（MediaStore 扫到的）
  local('local'),

  /// 本 app 下载落盘的文件
  download('download');

  const LocalAudioKind(this.wire);

  final String wire;

  static LocalAudioKind parse(Object? v) => switch (v.toString()) {
        'download' => LocalAudioKind.download,
        _ => LocalAudioKind.local,
      };
}

/// 一行本机音频。
class LocalAudioEntry {
  const LocalAudioEntry({
    this.id,
    required this.kind,
    required this.uri,
    required this.title,
    this.path = '',
    this.artist = '',
    this.album = '',
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.mtimeSec = 0,
    // 写入时由 repository 统一盖「本次扫描时刻」（同一次必须同一个值，
    // 换血式裁剪才准确）。0 = 由写入方决定。
    this.firstSeen = 0,
    this.lastSeen = 0,
    this.songId,
    this.qualityId = 0,
    this.songMid = '',
    this.albumMid = '',
    this.resolvedAt = 0,
  });

  final int? id;
  final LocalAudioKind kind;

  /// 播放句柄：MediaStore content uri 或 SAF 文档 uri。
  final String uri;

  /// 仅用于展示与「按目录过滤」的解释，不拿它开文件。
  final String path;

  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int sizeBytes;
  final int mtimeSec;
  final int firstSeen;
  final int lastSeen;

  /// 下载条目回指曲库的那首歌（扫描条目 null）。
  final int? songId;

  /// 下载时的 B站音质 ID；扫描条目 0。
  final int qualityId;

  /// ── v12：本机文件补出来的「线上身份」 ──────────────────────
  ///
  /// 文件本身没有 mid。按 标题+歌手+时长 去元数据源换一次身份，换到就
  /// 缓存下来，之后封面与歌词都直接吃缓存，不再重复请求：
  /// - [songMid]：QQ 的 songMid，**歌词接口只认它**。
  /// - [albumMid]：拼封面 URL 的原料（和 `song` 表同一口径：只存 mid，
  ///   URL 是派生值，落库反而会在源改域名时集体失效）。
  /// - [resolvedAt]：上一次*尝试*的时刻（秒），命中与否都会盖。0 = 没试过。
  ///   换不到身份的歌靠它做冷却，不然每次进列表都要重打一次注定失败的请求。
  final String songMid;
  final String albumMid;
  final int resolvedAt;

  /// 是否已经拿到可用的线上身份（有 songMid 就算，封面可能仍为空）。
  bool get hasResolvedId => songMid.isNotEmpty || albumMid.isNotEmpty;

  /// 换一份只改「线上身份」三件套的副本，其余字段原样。
  ///
  /// 刻意不做全字段 copyWith：补全链路永远只动这三列，参数收窄成三个
  /// 就不可能顺手抄漏一个字段、把 sizeBytes 或 songId 静默写成空值。
  LocalAudioEntry withResolution({
    required String songMid,
    required String albumMid,
    required int resolvedAt,
  }) =>
      LocalAudioEntry(
        id: id,
        kind: kind,
        uri: uri,
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        sizeBytes: sizeBytes,
        mtimeSec: mtimeSec,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
        songId: songId,
        qualityId: qualityId,
        songMid: songMid,
        albumMid: albumMid,
        resolvedAt: resolvedAt,
      );

  static const _unknownArtist = '未知歌手';

  /// 展示用歌手名。MediaStore 对无标签文件可能给空串，留白会让整列看着坏掉。
  String get displayArtist => artist.isEmpty ? _unknownArtist : artist;

  int get durationSec => (durationMs / 1000).round();

  /// 「3.2 MB」这种够用就好的体积文案（设置页与列表右侧都嫌长文案）。
  String get sizeText {
    if (sizeBytes <= 0) return '';
    final mb = sizeBytes / (1024 * 1024);
    if (mb >= 10) return '${mb.round()} MB';
    return '${(mb * 10).round() / 10} MB';
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'kind': kind.wire,
        'uri': uri,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'duration_ms': durationMs,
        'size_bytes': sizeBytes,
        'mtime_sec': mtimeSec,
        'first_seen': firstSeen,
        'last_seen': lastSeen,
        'song_id': songId,
        'quality_id': qualityId,
        'song_mid': songMid,
        'album_mid': albumMid,
        'resolved_at': resolvedAt,
      };

  factory LocalAudioEntry.fromMap(Map<String, Object?> m) => LocalAudioEntry(
        id: (m['id'] as num?)?.toInt(),
        kind: LocalAudioKind.parse(m['kind']),
        uri: (m['uri'] ?? '') as String,
        path: (m['path'] ?? '') as String,
        title: (m['title'] ?? '') as String,
        artist: (m['artist'] ?? '') as String,
        album: (m['album'] ?? '') as String,
        durationMs: (m['duration_ms'] as num?)?.toInt() ?? 0,
        sizeBytes: (m['size_bytes'] as num?)?.toInt() ?? 0,
        mtimeSec: (m['mtime_sec'] as num?)?.toInt() ?? 0,
        firstSeen: (m['first_seen'] as num?)?.toInt() ?? 0,
        lastSeen: (m['last_seen'] as num?)?.toInt() ?? 0,
        songId: (m['song_id'] as num?)?.toInt(),
        qualityId: (m['quality_id'] as num?)?.toInt() ?? 0,
        songMid: (m['song_mid'] ?? '') as String,
        albumMid: (m['album_mid'] ?? '') as String,
        resolvedAt: (m['resolved_at'] as num?)?.toInt() ?? 0,
      );
}

class LocalAudioDao {
  LocalAudioDao(this.db);

  final DatabaseExecutor db;

  /// 插入或按 uri 更新一行，返回行 id。
  ///
  /// `first_seen` 用 `COALESCE(旧值, 新值)` 保住最早那次；
  /// 显式 SELECT + UPDATE/INSERT 而不是 `INSERT OR REPLACE`，
  /// 因为 REPLACE 是删行重插，会把 first_seen 与自增 id 一起换掉。
  Future<int> upsert(LocalAudioEntry e) async {
    final existing = await db.query(
      Tables.localAudio,
      columns: ['id', 'first_seen'],
      where: 'uri = ?',
      whereArgs: [e.uri],
      limit: 1,
    );
    if (existing.isEmpty) {
      return db.insert(Tables.localAudio, e.toMap());
    }
    final row = existing.first;
    final id = row['id'] as int;
    await db.update(
      Tables.localAudio,
      {
        'kind': e.kind.wire,
        'path': e.path,
        'title': e.title,
        'artist': e.artist,
        'album': e.album,
        'duration_ms': e.durationMs,
        'size_bytes': e.sizeBytes,
        'mtime_sec': e.mtimeSec,
        'last_seen': e.lastSeen,
        // 已有行以库里的 first_seen 为准；调用方给的新值只在旧值为空时生效
        'first_seen': row['first_seen'] ?? e.firstSeen,
        'song_id': e.songId,
        'quality_id': e.qualityId,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  /// 某一类的全部条目。按歌手、歌名排——本机曲库没有「热度」概念，
  /// 字母序是唯一不随时间漂移、用户能预期位置的排序。
  Future<List<LocalAudioEntry>> listByKind(
    LocalAudioKind kind, {
    int limit = 2000,
  }) async {
    final rows = await db.query(
      Tables.localAudio,
      where: 'kind = ?',
      whereArgs: [kind.wire],
      orderBy: 'artist COLLATE NOCASE, title COLLATE NOCASE',
      limit: limit,
    );
    return rows.map(LocalAudioEntry.fromMap).toList();
  }

  /// 还没补到线上身份的条目——封面/歌词补全的待办清单。
  ///
  /// ## 冷却为什么放在 SQL 里而不是内存里
  /// 「这首歌元数据源根本没有」是常态（翻唱、-demo、文件名是 `Track 01`）。
  /// 没有 [retryAfterSec] 这道闸，每次进列表都会给这些歌重打一次注定失败
  /// 的请求，而且请求是串行带 400ms 间隔的，几十首就能把一次进页面拖成
  /// 半分钟。试过的时间戳落库，重启也认。
  ///
  /// 标题为空的没有可搜的关键词，直接排除（否则每次都白跑一趟）。
  Future<List<LocalAudioEntry>> unresolved({
    required int now,
    int limit = 60,
    int retryCooldownSec = 3 * 24 * 3600,
  }) async {
    final rows = await db.query(
      Tables.localAudio,
      where: "song_mid = '' AND album_mid = '' AND title <> '' "
          'AND (resolved_at = 0 OR resolved_at <= ?)',
      whereArgs: [now - retryCooldownSec],
      orderBy: 'kind, artist COLLATE NOCASE, title COLLATE NOCASE',
      limit: limit,
    );
    return rows.map(LocalAudioEntry.fromMap).toList();
  }

  /// 写入一次补全结果，返回受影响行数。
  ///
  /// 按 uri 定位：uri 才是本机文件的稳定标识，id 在重新扫描后可能变。
  /// 注意 [upsert] 的 UPDATE 分支**故意不碰**这三列——重新扫描只是刷新
  /// 文件信息，不该把已经换到的线上身份清空。
  Future<int> applyResolution({
    required String uri,
    required String songMid,
    required String albumMid,
    required int now,
  }) =>
      db.update(
        Tables.localAudio,
        {'song_mid': songMid, 'album_mid': albumMid, 'resolved_at': now},
        where: 'uri = ?',
        whereArgs: [uri],
      );

  /// 只盖「试过了」的时刻：这次没换到身份，冷却期内别再打请求。
  Future<int> markResolutionAttempted({required String uri, required int now}) =>
      db.update(
        Tables.localAudio,
        {'resolved_at': now},
        where: 'uri = ?',
        whereArgs: [uri],
      );

  Future<int> countOfKind(LocalAudioKind kind) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) FROM ${Tables.localAudio} WHERE kind = ?',
      [kind.wire],
    );
    return (rows.first.values.first as int?) ?? 0;
  }

  /// 某首歌已经下载到的文件（「已下载优先播本地」的查询入口）。
  ///
  /// 只认 kind=download：手机自带的同名歌曲不算「我下载过这首歌」。
  Future<LocalAudioEntry?> downloadedOfSong(int songId) async {
    final rows = await db.query(
      Tables.localAudio,
      where: 'kind = ? AND song_id = ?',
      whereArgs: [LocalAudioKind.download.wire, songId],
      orderBy: 'size_bytes DESC', // 同曲多档时挑体积最大的那份（音质最好）
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LocalAudioEntry.fromMap(rows.first);
  }

  Future<LocalAudioEntry?> byUri(String uri) async {
    final rows = await db.query(
      Tables.localAudio,
      where: 'uri = ?',
      whereArgs: [uri],
      limit: 1,
    );
    return rows.isEmpty ? null : LocalAudioEntry.fromMap(rows.first);
  }

  /// 换血：删掉本轮扫描没再出现的条目。返回删了几条。
  ///
  /// [scanStamp] 必须是本轮 upsert 用的同一个值，否则会把刚写进去的删掉。
  Future<int> pruneUnseen(LocalAudioKind kind, int scanStamp) async =>
      db.delete(
        Tables.localAudio,
        where: 'kind = ? AND last_seen < ?',
        whereArgs: [kind.wire, scanStamp],
      );

  Future<int> deleteById(int id) => db.delete(
        Tables.localAudio,
        where: 'id = ?',
        whereArgs: [id],
      );

  /// 清空某一类（「重新扫描前彻底清」/「清除全部下载记录」）。
  Future<int> deleteAllOfKind(LocalAudioKind kind) => db.delete(
        Tables.localAudio,
        where: 'kind = ?',
        whereArgs: [kind.wire],
      );

  /// 一批 uri 里哪些还在库里（下载完成后核对用）。
  Future<Set<String>> existingUris(Iterable<String> uris) async {
    if (uris.isEmpty) return {};
    final list = uris.toList();
    final out = <String>{};
    // 变量上限 999：按 500 一批查，别把「一次扫全库」变成一次崩溃。
    for (var i = 0; i < list.length; i += 500) {
      final batch = list.sublist(i, (i + 500).clamp(0, list.length));
      final rows = await db.query(
        Tables.localAudio,
        columns: ['uri'],
        where: 'uri IN (${List.filled(batch.length, '?').join(',')})',
        whereArgs: batch,
      );
      out.addAll(rows.map((r) => r['uri'] as String));
    }
    return out;
  }
}
