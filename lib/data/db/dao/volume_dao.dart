/// TrackVolume 表的读写（每曲音量记忆）。
///
/// ## 为什么音量记忆用 song_id 外键而不是 song.key
/// 与 LikedDao 同一取舍：`title|artist` 展示键改名即失联，真正的
/// 主键才可靠。歌被删时 CASCADE 清理，不留孤儿行。
///
/// ## 存储值域
/// just_audio 的 `volume` 有效域是 0~1（Android 平台限制）。
/// 想要「比原始素材更大声」走全局响度微调（LoudnessEnhancer ±dB），
/// 不在这张表里放大于 1 的值——DAO 层不做 clamp，由调用方
/// （AppState）保证语义，这里只负责存取如实还原。
library;

import 'package:sqflite/sqflite.dart';

import '../schema.dart';

class VolumeDao {
  VolumeDao(this.db);

  final DatabaseExecutor db;

  /// 某首歌的记忆音量。没记过返回 1.0（默认满量）。
  Future<double> volumeOf(int songId) async {
    final rows = await db.query(
      Tables.trackVolume,
      columns: ['volume'],
      where: 'song_id = ?',
      whereArgs: [songId],
      limit: 1,
    );
    if (rows.isEmpty) return 1.0;
    return (rows.first['volume'] as num?)?.toDouble() ?? 1.0;
  }

  /// 记忆某首歌的音量。重复保存覆盖旧值（用户后来又调了）。
  ///
  /// `INSERT OR REPLACE` 在这里是对的：音量没有「保留首次时间」的
  /// 需求，updated_at 本来就该随每次修改刷新。
  Future<void> save(int songId, double volume, {int? now}) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.insert(
      Tables.trackVolume,
      {'song_id': songId, 'volume': volume, 'updated_at': ts},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除某首歌的记忆（「清除本曲音量」入口用；本来就没有也不报错）。
  Future<void> clear(int songId) async {
    await db.delete(
      Tables.trackVolume,
      where: 'song_id = ?',
      whereArgs: [songId],
    );
  }
}
