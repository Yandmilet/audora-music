/// 音效层单元测试：预设曲线取值 / 自定义曲线序列化 / 每曲音量 DAO。
///
/// FxCurves 与 VolumeDao 都是纯逻辑/纯 SQL，**不碰真机、不碰网络**：
/// 曲线测试验证「频点 → dB」的数学口径（对数域插值），DAO 测试用
/// sqflite_common_ffi 内存库验证存取语义。
library;

import 'package:audora_music/data/db/app_database.dart';
import 'package:audora_music/data/db/rows.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/fx/fx_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FxCurves.interp（频点曲线取值）', () {
    test('空曲线恒为 0（平直语义）', () {
      expect(FxCurves.interp({}, 1000), 0);
    });

    test('低于首频点取端点值，高于末频点取端点值（不外推）', () {
      final curve = <double, double>{2000: 1.0, 8000: 3.0};
      expect(FxCurves.interp(curve, 100), 1.0);
      expect(FxCurves.interp(curve, 16000), 3.0);
    });

    test('log 域中点取值正确（几何中点 = 算术半程增益）', () {
      // 1000→4000 的几何中点是 2000（√(1000×4000)），log 域 t=0.5，
      // 增益应为两端值的算术中点。
      final curve = <double, double>{1000: 0.0, 4000: 4.0};
      expect(FxCurves.interp(curve, 2000), closeTo(2.0, 1e-9));
    });

    test('log 域插值与线性插值不同（这正是用 log 的理由）', () {
      // 若误用线性域：2000 在 1000~4000 的线性 t = 1/3 → 增益 1.33；
      // log 域 t = 0.5 → 增益 2.0。断言两者确实分开。
      // （double key 不能进 const map，一律 final 字面量）
      final curve = <double, double>{1000: 0.0, 4000: 4.0};
      final logVal = FxCurves.interp(curve, 2000);
      expect(logVal, closeTo(2.0, 1e-9));
      expect(logVal, isNot(closeTo(4.0 / 3, 1e-6)));
    });
  });

  group('FxCurves.encode / decode（自定义曲线序列化）', () {
    test('往返一致：整型频点、增益保留一位小数', () {
      final curve = <double, double>{60.0: 5.0, 150.0: 3.2, 4000.0: -1.5};
      final back = FxCurves.decode(FxCurves.encode(curve));
      expect(back.length, 3);
      expect(back[60.0], 5.0);
      expect(back[150.0], closeTo(3.2, 1e-9));
      expect(back[4000.0], -1.5);
    });

    test('频点按整型 Hz 归一，60.0 与 60.0 不会存出两份', () {
      final encoded = FxCurves.encode({60.0: 1.0, 60.3: 2.0});
      // 60.3.round() == 60，与 60.0 同键，后者胜出
      final back = FxCurves.decode(encoded);
      expect(back.length, 1);
      expect(back[60.0], 2.0);
    });

    test('输出按频点升序（便于人工核对日志/偏好串）', () {
      final encoded = FxCurves.encode({4000.0: 1.0, 60.0: 2.0});
      final idx60 = encoded.indexOf('60');
      final idx4000 = encoded.indexOf('4000');
      expect(idx60, lessThan(idx4000));
    });

    test('空曲线编码为空串，空串解码为空表', () {
      expect(FxCurves.encode({}), '');
      expect(FxCurves.decode(''), isEmpty);
    });

    test('损坏输入返回空表而不抛异常', () {
      expect(FxCurves.decode('not json at all'), isEmpty);
      expect(FxCurves.decode('[1,2,3]'), isEmpty);
      expect(FxCurves.decode('{"60":"abc"}'), isEmpty);
    });
  });

  group('FxPreset（预设注册表）', () {
    test('未知 id 回落平直，不让面板打不开', () {
      expect(FxPreset.byId('broken_id').id, FxPreset.flatId);
    });

    test('所有预设增益保守（|≤5dB|），避免削波与轰头', () {
      for (final p in FxPreset.presets) {
        for (final g in p.curve.values) {
          expect(g.abs(), lessThanOrEqualTo(5.0),
              reason: '${p.label} 存在超限增益 $g');
        }
      }
    });

    test('custom 预设本体无曲线（展示占位，真曲线在服务里）', () {
      expect(FxPreset.custom.curve, isEmpty);
    });
  });

  group('VolumeDao（每曲音量记忆）', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
    });

    tearDown(() async => db.close());

    Future<int> insertSong(String title) => db.songs.upsert(
          SongRow.fromSong(
            Song(
              title: title,
              artist: '测试歌手',
              album: '专辑',
              duration: 200,
              releaseDate: DateTime(2020, 1, 1),
              coverSeed: 1,
            ),
            qqSongMid: SongRow.deriveMid(title, '测试歌手'),
          ),
        );

    test('没记过的歌返回默认 1.0', () async {
      final id = await insertSong('默认音量');
      expect(await db.volumes.volumeOf(id), 1.0);
    });

    test('保存后可读回，重复保存覆盖旧值', () async {
      final id = await insertSong('调过音量');
      await db.volumes.save(id, 0.5);
      expect(await db.volumes.volumeOf(id), 0.5);

      await db.volumes.save(id, 0.8);
      expect(await db.volumes.volumeOf(id), 0.8);
      // 覆盖而非新增：同 song_id 只有一行（PK 冲突走 replace）
      final rows =
          await db.db.query('track_volume', where: 'song_id = ?', whereArgs: [id]);
      expect(rows.length, 1);
    });

    test('clear 后回到默认 1.0（本来没有也不报错）', () async {
      final id = await insertSong('清除音量');
      await db.volumes.save(id, 0.3);
      await db.volumes.clear(id);
      expect(await db.volumes.volumeOf(id), 1.0);
      // 再 clear 一次：幂等
      await db.volumes.clear(id);
      expect(await db.volumes.volumeOf(id), 1.0);
    });

    test('歌被删除时音量记忆 CASCADE 清理，不留孤儿行', () async {
      final id = await insertSong('将被删除');
      await db.volumes.save(id, 0.4);
      await db.songs.delete(id);
      final rows =
          await db.db.query('track_volume', where: 'song_id = ?', whereArgs: [id]);
      expect(rows, isEmpty);
    });
  });
}
