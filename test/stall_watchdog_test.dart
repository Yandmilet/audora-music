// 停滞看门狗判定逻辑单测（纯状态机，不起播放器）。
// 背景：Flyme 后台断网会制造「PLAYING 但 position 冻结」的死流，
// 看门狗靠位置读数发现并请求自愈；这里钉住判定/预算/清零的全部语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:audora_music/services/playback/audio_player_controller.dart';

void main() {
  group('StallWatchdog 判定', () {
    test('位置连续 5 拍不动才判死（2s/拍 ≈ 10s）', () {
      final w = StallWatchdog();
      var pos = Duration.zero;
      var fired = false;
      for (var i = 0; i < 4; i++) {
        fired = w.tick(playing: true, position: pos);
        expect(fired, isFalse, reason: '第 ${i + 1} 拍不应触发');
      }
      expect(w.tick(playing: true, position: pos), isTrue, reason: '第 5 拍应触发');
    });

    test('正常推进的播放永不触发', () {
      final w = StallWatchdog();
      var pos = Duration.zero;
      for (var i = 0; i < 100; i++) {
        pos += const Duration(seconds: 2);
        expect(w.tick(playing: true, position: pos), isFalse);
      }
    });

    test('暂停期间位置不动不攒计数，恢复后重新观察', () {
      final w = StallWatchdog();
      const pos = Duration(seconds: 30);
      for (var i = 0; i < 10; i++) {
        expect(w.tick(playing: false, position: pos), isFalse, reason: '暂停冻结是正常的');
      }
      // 恢复播放但流已死：需要重新攒满 5 拍，而不是继承暂停前的计数
      for (var i = 0; i < 4; i++) {
        expect(w.tick(playing: true, position: pos), isFalse);
      }
      expect(w.tick(playing: true, position: pos), isTrue);
    });

    test('大幅跳变（含 seek 倒退）视为流还活着，清零计数', () {
      final w = StallWatchdog();
      const frozen = Duration(seconds: 60);
      expect(w.tick(playing: true, position: frozen), isFalse);
      expect(w.tick(playing: true, position: frozen), isFalse);
      expect(w.tick(playing: true, position: frozen), isFalse);
      // 前进跳变
      expect(w.tick(playing: true, position: frozen + const Duration(seconds: 8)), isFalse);
      // 倒退跳变（回环/seek 回退）
      expect(w.tick(playing: true, position: frozen), isFalse);
      // 计数已清零：再冻 4 拍不触发，第 5 拍才触发
      for (var i = 0; i < 4; i++) {
        expect(w.tick(playing: true, position: frozen), isFalse);
      }
      expect(w.tick(playing: true, position: frozen), isTrue);
    });

    test('轻微抖动（<500ms）不算活着，累计触发', () {
      final w = StallWatchdog();
      var pos = Duration.zero;
      // 每拍只挪 300ms：肉眼在动但节奏远低于正常播放，应判死
      for (var i = 0; i < 4; i++) {
        pos += const Duration(milliseconds: 300);
        expect(w.tick(playing: true, position: pos), isFalse);
      }
      pos += const Duration(milliseconds: 300);
      expect(w.tick(playing: true, position: pos), isTrue);
    });
  });

  group('StallWatchdog 自愈预算', () {
    test('countRevive 计满后 exhausted，resetAttempts 回满预算', () {
      final w = StallWatchdog();
      expect(w.exhausted, isFalse);
      w.countRevive();
      w.countRevive();
      expect(w.exhausted, isFalse);
      w.countRevive();
      expect(w.attempts, 3);
      expect(w.exhausted, isTrue, reason: '默认预算 3 次');
      w.resetAttempts();
      expect(w.attempts, 0);
      expect(w.exhausted, isFalse);
    });

    test('触发自愈后 suspend 作废基线：恢复观察需重新攒满', () {
      final w = StallWatchdog();
      const pos = Duration(seconds: 10);
      for (var i = 0; i < 4; i++) {
        w.tick(playing: true, position: pos);
      }
      expect(w.tick(playing: true, position: pos), isTrue);
      w.suspend();
      // suspend 后基线作废，第 1 拍重新从零攒
      for (var i = 0; i < 4; i++) {
        expect(w.tick(playing: true, position: pos), isFalse);
      }
      expect(w.tick(playing: true, position: pos), isTrue);
    });
  });
}
