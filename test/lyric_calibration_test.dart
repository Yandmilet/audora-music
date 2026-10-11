/// 歌词时间轴校准的单元测试。
///
/// ## 防什么缺陷
/// 旧实现用「最后一行歌词时间 ÷ 视频总时长」做自动等比缩放，再叠加用户
/// 平移偏移——斜率系统性偏小（尾奏）且与偏移双重补偿，数学上只能在一个
/// 时间点对齐，表现为「手动调准后，播一会又不匹配」。
///
/// 现模型：`lrcMs = realMs × slope + offsetMs`
/// - slope 默认 1.0（纯平移，一次校准全曲准，误差不随位置累积）
/// - 长按歌词行「本句对齐」：一次 = 平移；间隔 ≥20s 两次 = 定出斜率
///
/// 这些用例在无播放器的 AppState（模拟进度模式）下跑，位置用
/// `debugPositionMs` 精确到毫秒，专门钉住「秒级截断让 ±50ms 微调失效」
/// 这一类回归。
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/lyric/lrc_parser.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 4 行歌词：0 / 30s / 60s / 90s
ParsedLyric _lyric() => parseLrc('''
[00:00.00]第一句
[00:30.00]第二句
[01:00.00]第三句
[01:30.00]第四句
''');

Song _song({int id = 1}) => Song(
      id: id,
      title: '校准测试歌$id',
      artist: '测试歌手',
      duration: 300,
      coverSeed: 0,
    );

void main() {
  group('歌词映射（lrcMs = realMs × slope + offset）', () {
    test('默认 slope=1、offset=0：映射恒等且保留毫秒精度', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 1234;
      // 旧实现 d.inSeconds 截断后这里只会是 1000
      expect(st.mappedLyricMs, 1234);
    });

    test('±按钮只做平移，slope 保持 1.0', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 10000;
      st.adjustLyricOffset(500);
      expect(st.mappedLyricMs, 10500);
      expect(st.current!.lyricSlope, 1.0);

      // 平移后全曲误差恒定、不随位置累积（旧 scale 模型会越播越偏）
      st.debugPositionMs = 100000;
      expect(st.mappedLyricMs, 100500);
    });
  });

  group('单点「本句对齐」= 平移立即生效', () {
    test('在 15s 处对准 30s 的歌词行：offset=+15s，当前行立即跟随', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 15000;
      final msg = st.alignLyricLine(1); // 第二行 @30000ms

      expect(msg, isNotNull);
      expect(st.current!.lyricOffsetMs, 15000);
      expect(st.current!.lyricSlope, 1.0);
      expect(st.mappedLyricMs, 30000);
      expect(st.lyricLine, 1, reason: '对齐后该句应立即成为当前高亮行');
      expect(st.lyricAlignPending, isTrue, reason: '第一次对齐后挂起锚点');
    });
  });

  group('两点校准 = 自动定出变速斜率', () {
    test('两处对齐后算出 slope=1.5，中间点也严格落在直线上', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      // 锚点 1：真实 10s 处唱的是 LRC 0s 的第一句
      st.debugPositionMs = 10000;
      st.alignLyricLine(0);
      // 锚点 2：真实 50s 处唱的是 LRC 60s 的第三句（间隔 40s ≥ 20s）
      st.debugPositionMs = 50000;
      final msg = st.alignLyricLine(2);

      // slope = (60000-0)/(50000-10000) = 1.5
      // offset = 0 - 10000*1.5 = -15000
      expect(msg, contains('两点校准完成'));
      expect(st.current!.lyricSlope, closeTo(1.5, 1e-9));
      expect(st.current!.lyricOffsetMs, -15000);
      expect(st.lyricAlignPending, isFalse);

      // 两个锚点精确通过
      st.debugPositionMs = 10000;
      expect(st.mappedLyricMs, 0);
      st.debugPositionMs = 50000;
      expect(st.mappedLyricMs, 60000);
      // 中间点：30000*1.5 - 15000 = 30000
      st.debugPositionMs = 30000;
      expect(st.mappedLyricMs, 30000);
    });

    test('两点间隔 <20s：拒绝并保留第一次的平移，锚点不清除', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 10000;
      st.alignLyricLine(0); // offset=-10000

      st.debugPositionMs = 25000; // 只隔 15s
      final msg = st.alignLyricLine(1);

      expect(msg, contains('太近'));
      expect(st.current!.lyricSlope, 1.0, reason: '不能写入斜率');
      expect(st.current!.lyricOffsetMs, -10000, reason: '第一次平移保留');
      expect(st.lyricAlignPending, isTrue, reason: '允许走到远处再试');
    });

    test('拟合斜率超出合理区间：拒绝误操作', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 10000;
      st.alignLyricLine(0);

      // 真实只推进 20.001s，歌词却跨了 60s → slope≈2.999，明显是误操作
      st.debugPositionMs = 30001;
      final msg = st.alignLyricLine(2);

      expect(msg, contains('异常'));
      expect(st.current!.lyricSlope, 1.0);
      expect(st.lyricAlignPending, isTrue);
    });
  });

  group('挂起锚点的作废时机', () {
    test('±按钮手动平移后作废', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 10000;
      st.alignLyricLine(0);
      expect(st.lyricAlignPending, isTrue);

      st.adjustLyricOffset(50);
      expect(st.lyricAlignPending, isFalse);
    });

    test('切歌后作废', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song(id: 1), _song(id: 2)], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 10000;
      st.alignLyricLine(0);
      expect(st.lyricAlignPending, isTrue);

      st.next();
      expect(st.current!.id, 2);
      expect(st.lyricAlignPending, isFalse);
    });

    test('重置：offset/slope/挂起锚点全部归零', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);
      st.debugLyric = _lyric();

      st.debugPositionMs = 10000;
      st.alignLyricLine(0);
      st.debugPositionMs = 50000;
      st.alignLyricLine(2); // slope=1.5, offset=-15000
      expect(st.current!.lyricSlope, isNot(1.0));

      st.resetLyricOffset();
      expect(st.current!.lyricOffsetMs, 0);
      expect(st.current!.lyricSlope, 1.0);
      expect(st.lyricAlignPending, isFalse);
      st.debugPositionMs = 42424;
      expect(st.mappedLyricMs, 42424);
    });

    test('无歌词 / 越界行号 / 无 id 时安全返回 null', () {
      final st = AppState();
      addTearDown(st.dispose);
      st.playQueue([_song()], 0);

      // 未注入歌词
      expect(st.alignLyricLine(0), isNull);

      st.debugLyric = _lyric();
      expect(st.alignLyricLine(99), isNull);
    });
  });
}
