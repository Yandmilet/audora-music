/// SQLite 数据库主类：建库、升级、DAO 装配。
///
/// 用 sqflite 的 `openDatabase` 但**不依赖 `sqflite_common_ffi`**——
/// 真机上 sqflite 走原生实现，桌面/单测才需要 ffi。
/// 这里保持纯真机路径，DAO 的 SQL 逻辑用内存库单测验证（见 test/db_test.dart）。
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'dao/binding_dao.dart';
import 'dao/liked_dao.dart';
import 'dao/play_stats_dao.dart';
import 'dao/song_dao.dart';
import 'dao/video_dao.dart';
import 'dao/volume_dao.dart';
import 'schema.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  late final SongDao songs = SongDao(db);
  late final VideoDao videos = VideoDao(db);
  late final BindingDao bindings = BindingDao(db);
  late final LikedDao liked = LikedDao(db);
  late final PlayStatsDao plays = PlayStatsDao(db);
  late final VolumeDao volumes = VolumeDao(db);

  static AppDatabase? _instance;

  /// 单例：整个 app 只开一次数据库。
  ///
  /// [path] 传 `inMemoryDatabasePath` 可开内存库（单测用）。
  static Future<AppDatabase> open({String? path}) async {
    if (_instance != null && path == null) return _instance!;

    final dbPath = path ?? p.join(await getDatabasesPath(), kDbName);
    final db = await openDatabase(
      dbPath,
      version: kDbVersion,
      onConfigure: (db) async {
        // 外键约束默认关闭，必须手动开，否则 CASCADE 不生效
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        for (final sql in kCreateAll) {
          await db.execute(sql);
        }
      },
      onUpgrade: (db, oldV, newV) async {
        // 迁移原则：**只加不改**。用户曲库是真数据，
        // 任何 DROP / 重建都会让「重新打开 app 曲库空了」。
        //
        // 每段迁移各自一个事务，中途失败时已完成的版本不回滚——
        // 但下一次启动会从新的 oldV 继续，不会重复执行。
        if (oldV < 2) {
          for (final sql in kMigrateV1ToV2) {
            await db.execute(sql);
          }
        }
        if (oldV < 3) {
          for (final sql in kMigrateV2ToV3) {
            await db.execute(sql);
          }
        }
        if (oldV < 4) {
          for (final sql in kMigrateV3ToV4) {
            await db.execute(sql);
          }
        }
      },
    );

    final inst = AppDatabase._(db);
    if (path == null) _instance = inst;
    return inst;
  }

  /// 关库（测试收尾 / app 退出）
  Future<void> close() async {
    await db.close();
    _instance = null;
  }

  /// 清空所有表（调试用，慎调）
  Future<void> wipe() async {
    await db.transaction((txn) async {
      await txn.delete(Tables.playLog);
      await txn.delete(Tables.playStat);
      await txn.delete(Tables.trackVolume);
      await txn.delete(Tables.liked);
      await txn.delete(Tables.binding);
      await txn.delete(Tables.video);
      await txn.delete(Tables.song);
    });
  }
}
