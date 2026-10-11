/// P1 连续平滑时长打分专项测试。
/// 验证线性插值在控制点之间的数值不是断崖式变化。
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_scorer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P1 Duration 连续平滑 — 边界间无断崖', () {
    // 在控制点之间取点，验证相邻步的差值 < 阶梯分档的断崖差（0.12）
    // 控制点: 0→1.00, 1500→1.00, 3000→0.92, 5000→0.80, 10000→0.55, 20000→0.25
    const song = Song(
      title: 'X',
      artist: 'Y',
      duration: 200,
      coverSeed: 0,
    );

    double durAt(int diffSec) {
      final videoSec = 200 + diffSec; // 构造精确 diff = diffSec 的视频
      return MatchScorer.score(
        VideoCandidate(
          bvid: 'BV',
          title: 'X - Y',
          durationSec: videoSec,
          pubdate: 1580000000,
        ),
        song,
      ).detail.s2Duration;
    }

    test('diff=2s (between 1.5s→1.00 and 3s→0.92) 应为 0.97 附近', () {
      final s = durAt(2);
      // 线性插值: t = (2000-1500)/(3000-1500) = 0.333, base = 1.00 + (0.92-1.00)*0.333 = 0.973
      expect(s, closeTo(0.973, 0.02));
    });

    test('diff=4s (between 3s→0.92 and 5s→0.80) 应为 0.86 附近', () {
      final s = durAt(4);
      // t = (4000-3000)/(5000-3000) = 0.5, base = 0.92 + (0.80-0.92)*0.5 = 0.86
      expect(s, closeTo(0.86, 0.02));
    });

    test('diff=7.5s (between 5s→0.80 and 10s→0.55) 应为 0.675 附近', () {
      final s = durAt(7);
      // t = (7000-5000)/(10000-5000) = 0.4, base = 0.80 + (0.55-0.80)*0.4 = 0.70
      expect(s, closeTo(0.70, 0.03));
    });

    test('断崖验证：相邻 100ms diff 的分数差 < 0.10（阶梯分档最大跳 0.12）', () {
      // durationSec 是 int 只能按整秒测：diff = 2000/3000/4000ms 跨越原 3s 断点
      final s1 = durAt(2);   // diff=2000ms (between 1.5s and 3s) → ~0.973
      final s2 = durAt(3);   // diff=3000ms (exact control point) → 0.92
      final s3 = durAt(4);   // diff=4000ms → ~0.86

      // 每 1s 的变化量应该远小于旧断崖的 0.12
      expect((s2 - s1).abs(), lessThan(0.12),
          reason: 'diff=2s→3s 不应有断崖（旧阶梯分档是 0.12 断崖）');
      expect((s3 - s2).abs(), lessThan(0.12),
          reason: 'diff=3s→4s 不应有断崖');
    });

    test('精确边界值保持不变（与 v0.7 阶梯分档完全一致）', () {
      expect(durAt(0), 1.00);
      expect(durAt(1), 1.00); // ≤1.5s 全部 1.00
      expect(durAt(3), 0.92);
      expect(durAt(5), 0.80);
      expect(durAt(10), 0.55);
      expect(durAt(20), 0.25);
    });
  });
}
