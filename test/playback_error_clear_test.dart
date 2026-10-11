/// 「播放错误横幅自动清除」的回归测试。
///
/// ## 防什么缺陷（2026-10-07 用户反馈）
/// 一首歌匹配失败 → 顶部挂出「没有找到可播放的音源」黄色横幅。
/// 之后：
///   - 切到下一首（有音源、播放正常）→ 上一首歌的横幅**依然常驻**
///   - 手动匹配音源成功 → 横幅**依然常驻**
///
/// 根因：`_playbackError` 只在用户点 X 关闭时清除，切歌和手动匹配路径
/// 都没有清掉它。修复点是：
///   1. `_playCurrent()` 开头清 error（覆盖 playSong/next/previous/jumpTo）
///   2. `bindManualSource` / `switchSource` 成功路径清 error
library;

import 'package:audora_music/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('播放错误横幅在切歌时被清除', () {
    test('playSong 清除上一首歌的错误', () {
      final st = AppState();
      addTearDown(st.dispose);

      // 模拟上一首歌匹配失败留下的错误
      st.playbackError = '没有找到可播放的音源：上一首歌';
      expect(st.playbackError, isNotNull);

      st.playSong(st.library.first);

      expect(st.playbackError, isNull,
          reason: '切歌应自动清除上一首歌的错误横幅');
    });

    test('next 清除上一首歌的错误', () {
      final st = AppState();
      addTearDown(st.dispose);

      // 先定位到第一首，设置错误，然后 next
      st.playQueue(st.library, 0);
      st.playbackError = '没有找到可播放的音源：第 1 首';

      st.next();

      expect(st.playbackError, isNull,
          reason: 'next() 应自动清除上一首歌的错误横幅');
    });

    test('previous 清除上一首歌的错误', () {
      final st = AppState();
      addTearDown(st.dispose);

      st.playQueue(st.library, 2);
      st.playbackError = '没有找到可播放的音源：第 3 首';

      st.previous();

      expect(st.playbackError, isNull,
          reason: 'previous() 应自动清除上一首歌的错误横幅');
    });

    test('jumpTo 清除上一首歌的错误', () {
      final st = AppState();
      addTearDown(st.dispose);

      st.playQueue(st.library, 0);
      st.playbackError = '没有找到可播放的音源';

      st.jumpTo(3);

      expect(st.playbackError, isNull,
          reason: 'jumpTo() 应自动清除上一首歌的错误横幅');
    });

    test('playQueue 清除上一首歌的错误', () {
      final st = AppState();
      addTearDown(st.dispose);

      st.playbackError = '没有找到可播放的音源';

      st.playQueue(st.library, 0);

      expect(st.playbackError, isNull,
          reason: 'playQueue() 应自动清除之前的错误横幅');
    });

    // TODO: bindManualSource / switchSource 的 error 清除需要完整的
    // repo + player 环境（AudioPlayerController 依赖 just_audio 原生实现，
    // 测试里无法构造），待有了 mock player 基础设施后补上。
    // 这两个方法的清除逻辑位于 p.playSong() 成功之后，真实运行时
    // player 始终存在（main.dart 注入），不会漏清。
  });
}
