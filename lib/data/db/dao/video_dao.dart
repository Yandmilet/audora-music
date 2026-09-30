/// BilibiliVideo 表的读写。
library;

import 'package:sqflite/sqflite.dart';

import '../rows.dart';
import '../schema.dart';

class VideoDao {
  VideoDao(this.db);

  final DatabaseExecutor db;

  /// 插入或更新（bvid 为主键）。
  ///
  /// ## ⚠️ 绝不能用 `ConflictAlgorithm.replace`
  ///
  /// `INSERT OR REPLACE` 遇到主键冲突时的动作是**先 DELETE 旧行、再 INSERT 新行**。
  /// 本表被 `song_source_binding` 以 `FOREIGN KEY ... ON DELETE CASCADE` 引用，
  /// 于是每刷新一次视频元数据（拉播放量、改标题等，都是常规操作），
  /// 就会把**所有引用该 bvid 的歌曲绑定关系静默删除**——
  /// 用户表现为「歌突然播不了、音源凭空消失」，且无法复现。
  ///
  /// 这里走 `ON CONFLICT(bvid) DO UPDATE`，只改列不删行，绑定关系完好。
  /// 注意 DO UPDATE 的 SET 里**不要写 `bvid` 本身**（主键不变）。
  Future<void> upsert(VideoRow row) async {
    final m = row.toMap();
    final cols = m.keys.toList();
    final placeholders = List.filled(cols.length, '?').join(', ');
    final assignments =
        cols.where((c) => c != 'bvid').map((c) => '$c = excluded.$c').join(', ');

    await db.rawInsert(
      'INSERT INTO ${Tables.video} (${cols.join(', ')}) '
      'VALUES ($placeholders) '
      'ON CONFLICT(bvid) DO UPDATE SET $assignments',
      cols.map((c) => m[c]).toList(),
    );
  }

  /// 只更新音频流相关字段，不碰视频元信息。
  ///
  /// 拉流是高频操作（URL 120 分钟过期），而视频元信息几乎不变；
  /// 分开更新能避免每次拉流都重写整行。
  ///
  /// ## ⚠️ 行不存在时必须补插
  /// 原本这里只有 `UPDATE`，行不存在时影响 0 行且**不报错**——
  /// 结果是 URL 永远写不进库，每次播放都要重新拉一次流。
  /// 正常流程下匹配引擎会先 upsert 视频行，所以这个问题在
  /// "匹配 → 播放" 路径上不会暴露；但只要有别的路径（如从备份恢复、
  /// 手动改库、或将来做「直接按 bvid 播放」）绕过了匹配，就会踩到。
  /// 这里改用 UPSERT：行在就更新，不在就插一条最小记录。
  Future<void> updateAudioStream(
    String bvid, {
    required String url,
    required int expireAt,
    int? qualityId,
    int? bitrate,
    int cid = 0,
  }) async {
    final changed = await db.update(
      Tables.video,
      {
        'audio_url': url,
        'audio_url_expire_at': expireAt,
        'audio_quality_id': qualityId,
        'audio_bitrate': bitrate,
        'available': 1,
        'unavailable_reason': null,
        // cid > 0 时一并修正（-400 自愈路径会把修好的 cid 传进来）；
        // 默认 0 不写——调用方没带 cid 时不能把好数据清成 0
        if (cid > 0) 'cid': cid,
      },
      where: 'bvid = ?',
      whereArgs: [bvid],
    );

    if (changed > 0) return;

    // 行不存在：插一条最小记录。title 留空而不是写 bvid——
    // 界面若显示空标题，一眼能看出"这条视频元数据没拉全"，
    // 比显示一个和 bvid 一模一样的"标题"更容易发现问题。
    await db.insert(
      Tables.video,
      {
        'bvid': bvid,
        'cid': cid,
        'title': '',
        'fetched_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'audio_url': url,
        'audio_url_expire_at': expireAt,
        'audio_quality_id': qualityId,
        'audio_bitrate': bitrate,
        'available': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 只修正 cid（playurl -400 自愈路径专用）。
  ///
  /// ## 为什么需要它
  /// 搜索接口（search/type）**不返回 cid**，凡是绕过详情接口落库的视频行
  /// （手动搜索绑定、Stage3 详情全部失败后的兜底激活）cid 必然是 0；
  /// playurl 拿 cid=0 请求恒返回 -400「请求错误」，且对该 bvid 永不自愈。
  /// 这里把详情接口取回的真实 cid 就地写回，行不存在时静默跳过
  /// （说明该 bvid 从未参与过播放，没必要凭空补行）。
  Future<void> updateCid(String bvid, int cid) async {
    await db.update(
      Tables.video,
      {'cid': cid},
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
  }

  /// 标记不可用（设计文档 8.2：拉流失败时调用，触发重新匹配）
  Future<void> markUnavailable(String bvid, String reason) async {
    await db.update(
      Tables.video,
      {
        'available': 0,
        'unavailable_reason': reason,
        'audio_url': null,
        'audio_url_expire_at': null,
      },
      where: 'bvid = ?',
      whereArgs: [bvid],
    );
  }

  Future<VideoRow?> getByBvid(String bvid) async {
    final rows = await db.query(
      Tables.video,
      where: 'bvid = ?',
      whereArgs: [bvid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return VideoRow.fromMap(rows.first);
  }

  Future<List<VideoRow>> getByBvids(List<String> bvids) async {
    if (bvids.isEmpty) return [];
    final placeholders = List.filled(bvids.length, '?').join(',');
    final rows = await db.query(
      Tables.video,
      where: 'bvid IN ($placeholders)',
      whereArgs: bvids,
    );
    return rows.map(VideoRow.fromMap).toList();
  }

  /// 拿可直接播放的 URL（未过期）
  ///
  /// 设计文档 8.2：URL 未过期直接用，过期则由上层重新拉流。
  Future<String?> getValidAudioUrl(String bvid) async {
    final v = await getByBvid(bvid);
    if (v == null) return null;
    return v.isAudioUrlValid ? v.audioUrl : null;
  }

  Future<int> count() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.video}');
    return (r.first['c'] as int?) ?? 0;
  }
}
