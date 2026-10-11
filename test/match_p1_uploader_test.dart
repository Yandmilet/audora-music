/// P1 Uploader Bayesian Profile 专项测试。
/// 验证 bonus 公式: min(0.25, 0.08 + count * 0.04)
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_scorer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P1 Uploader Bayesian Profile — 按验证次数加权', () {
    // 造一个基础场景：视频 UP 主 mid=42，基础 S3 应该 0.4
    const song = Song(
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      duration: 269,
      coverSeed: 0,
    );
    VideoCandidate makeVideo() => const VideoCandidate(
          bvid: 'BV',
          title: '晴天',
          author: '普通UP主',
          durationSec: 269,
          mid: 42,
          pubdate: 1600000000,
        );

    double s3WithProfile(Map<int, int> profile) {
      return MatchScorer.score(
        makeVideo(),
        song,
        trustedUploaderProfile: profile,
      ).detail.s3Uploader;
    }

    test('空 profile → S3 = 0.4（基础分，无跨歌学习）', () {
      expect(s3WithProfile(const {}), closeTo(0.4, 0.01));
    });

    test('UP主 mid 不在 profile 里 → S3 = 0.4（不认识的 UP 主不给加分）', () {
      expect(s3WithProfile({999: 5}), closeTo(0.4, 0.01));
    });

    test('count=1（首次验证）→ bonus = 0.12，S3 = 0.52', () {
      // 0.08 + 1*0.04 = 0.12
      expect(s3WithProfile({42: 1}), closeTo(0.52, 0.01));
    });

    test('count=2 → bonus = 0.16，S3 = 0.56', () {
      // 0.08 + 2*0.04 = 0.16
      expect(s3WithProfile({42: 2}), closeTo(0.56, 0.01));
    });

    test('count=4 → bonus = 0.24，S3 = 0.64', () {
      // 0.08 + 4*0.04 = 0.24
      expect(s3WithProfile({42: 4}), closeTo(0.64, 0.01));
    });

    test('count=5 → bonus 封顶 0.25，S3 = 0.65', () {
      // 0.08 + 5*0.04 = 0.28 → clamp 到 0.25
      expect(s3WithProfile({42: 5}), closeTo(0.65, 0.01));
    });

    test('count=100 → bonus 仍然封顶 0.25', () {
      expect(s3WithProfile({42: 100}), closeTo(0.65, 0.01));
    });

    test('mid=0（无效 mid）→ 不加分', () {
      // 视频 mid 为 0，即使 profile 里有 0 也不应该加到这个视频
      const v = VideoCandidate(
        bvid: 'BV',
        title: '晴天',
        author: '普通UP主',
        durationSec: 269,
        mid: 0,
        pubdate: 1600000000,
      );
      final s3 = MatchScorer.score(
        v,
        song,
        trustedUploaderProfile: {0: 10},
      ).detail.s3Uploader;
      expect(s3, closeTo(0.4, 0.01)); // 不加
    });
  });

  group('P1 vs v0.7 对比 — 保守性提升', () {
    test('v0.7 Set 命中就给 +0.20，P1 count=1 只给 +0.12（更保守）', () {
      // P1：count=1 → +0.12
      final s3New = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BV',
          title: '晴天',
          author: '普通UP主',
          durationSec: 269,
          mid: 42,
          pubdate: 1600000000,
        ),
        const Song(
          title: '晴天',
          artist: '周杰伦',
          album: '叶惠美',
          duration: 269,
          coverSeed: 0,
        ),
        trustedUploaderProfile: {42: 1},
      ).detail.s3Uploader;

      // v0.7 Set 版本是 0.4 + 0.20 = 0.60
      // P1 count=1 版本是 0.4 + 0.12 = 0.52
      expect(s3New, lessThan(0.60),
          reason: '首次验证的 UP 主应比 v0.7 固定 +0.20 更保守');
    });
  });
}
