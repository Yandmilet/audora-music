/// 匹配算法单元测试（纯 Dart，无网络依赖）。
///
/// 全部用设计文档 4.1 的表格作为黄金测试集 —— 那张表列出了
/// 「同名视频远远不够」的六种干扰类型，正好当负例。
///
/// 运行：`flutter test test/match_scorer_test.dart`
library;

import 'package:audora2/models/models.dart';
import 'package:audora2/services/bilibili/bili_dto.dart';
import 'package:audora2/services/match/match_config.dart';
import 'package:audora2/services/match/match_scorer.dart';
import 'package:audora2/services/match/text_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 设计文档 4.1 的例子：《秘密》- 白浩寅，时长 3:46
  final secret = Song(
    title: '秘密',
    artist: '白浩寅',
    album: '秘密',
    duration: 226,
    releaseDate: DateTime(2020, 1, 1),
    coverSeed: 1,
  );

  group('TextNormalizer', () {
    test('去括号类符号', () {
      expect(TextNormalizer.normalize('【官方MV】'), '官方');
      expect(TextNormalizer.normalize('（原版）'), '原版');
      expect(TextNormalizer.normalize('《歌名》'), '歌名');
      expect(TextNormalizer.normalize('["a"]'), 'a');
    });

    test('去分隔符与空格', () {
      expect(TextNormalizer.normalize('白浩寅 - 秘密'), '白浩寅秘密');
      expect(TextNormalizer.normalize('A_B|C/D'), 'abcd');
    });

    test('去质量词后缀（含大小写不敏感）', () {
      expect(TextNormalizer.normalize('秘密 无损'), '秘密');
      expect(TextNormalizer.normalize('秘密 完整版'), '秘密');
      expect(TextNormalizer.normalize('秘密 OFFiCiaL audio'), '秘密');
      expect(TextNormalizer.normalize('秘密 HQ'), '秘密');
    });

    // 回归：Dart 的 RegExp 不支持 `(?i)` 内联标志，
    // 照抄设计文档的 Kotlin 写法会抛 FormatException: Invalid group
    test('不得使用 Dart 不支持的内联标志 (?i)', () {
      expect(() => TextNormalizer.normalize('ABC'), returnsNormally);
    });

    test('标准格式判定：分隔符两侧必须有空格', () {
      expect(TextNormalizer.hasStandardFormat('白浩寅 - 秘密'), isTrue);
      expect(TextNormalizer.hasStandardFormat('白浩寅 – 秘密'), isTrue);
      // 无空格的连字符不算（否则 A-Lin 会被误判成「A 减 Lin」格式）
      expect(TextNormalizer.hasStandardFormat('A-Lin'), isFalse);
      expect(TextNormalizer.hasStandardFormat('秘密'), isFalse);
    });

    test('模糊匹配的两道守卫', () {
      // 长度差 > 3 直接否定
      expect(TextNormalizer.isFuzzyMatch('ab', 'abcdefgh', 0.65), isFalse);
      // 较短串 < 3 字直接否定（设计文档要求，避免短串误判）
      expect(TextNormalizer.isFuzzyMatch('秘密', '秘蜜', 0.65), isFalse);
      // 相同长串命中
      expect(TextNormalizer.isFuzzyMatch('起风了', '起风了', 0.85), isTrue);
    });

    test('编辑距离', () {
      expect(TextNormalizer.levenshtein('kitten', 'sitting'), 3);
      expect(TextNormalizer.levenshtein('abc', 'abc'), 0);
      expect(TextNormalizer.levenshtein('', 'abc'), 3);
    });
  });

  group('MatchScorer — 设计文档 4.1 黄金测试集', () {
    ScoredCandidate s(String title, int durSec, {String part = '音乐', int play = 50000}) =>
        MatchScorer.score(
          VideoCandidate(
            bvid: 'BVtest',
            title: title,
            author: '某UP',
            durationSec: durSec,
            play: play,
            pubdate: 1580000000,
            typename: part,
          ),
          secret,
        );

    test('正例：标准「歌手 - 歌名」+ 时长精确 → AUTO', () {
      final r = s('白浩寅 - 秘密【官方MV】', 226, play: 500000);
      expect(r.total, greaterThanOrEqualTo(MatchConfig.autoThreshold));
      expect(r.confidence, MatchConfidence.auto);
    });

    test('负例：1小时循环版 → 时长维度归零', () {
      final r = s('秘密 1小时循环版', 3600);
      expect(r.detail.s2Duration, lessThan(0.1));
      expect(r.confidence, MatchConfidence.rejected);
    });

    test('负例：钢琴版 → 时长略长，总分掉出 AUTO', () {
      final r = s('秘密（钢琴版）', 240);
      expect(r.confidence, isNot(MatchConfidence.auto));
    });

    test('负例：完全不相关（标题含关键词但语义无关）→ 不进 AUTO', () {
      final r = s('揭秘白浩寅背后的秘密', 226, part: '生活', play: 400000);
      expect(r.confidence, isNot(MatchConfidence.auto));
    });

    test('正例：UP主是歌手本人 → UP主维度拿满分', () {
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BVofficial',
          title: '秘密',
          author: '白浩寅',
          durationSec: 226,
          play: 200000,
          pubdate: 1580000000,
          typename: '音乐',
        ),
        secret,
      );
      expect(r.detail.s3Uploader, greaterThanOrEqualTo(0.9));
    });
  });

  group('MatchScorer — 时长维度（设计文档 4.6.3）', () {
    double dur(int videoSec) {
      const song = Song(title: 'X', artist: 'Y', duration: 200, coverSeed: 0);
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

    test('≤1.5 秒 → 1.00', () => expect(dur(200), 1.00));
    test('≤3 秒 → 0.92', () => expect(dur(203), 0.92));
    test('≤5 秒 → 0.80', () => expect(dur(205), 0.80));
    test('≤10 秒 → 0.55', () => expect(dur(210), 0.55));
    test('≤20 秒 → 0.25', () => expect(dur(220), 0.25));
    test('长度翻倍 → 0.00', () => expect(dur(400), 0.00));
  });

  group('MatchScorer — 发布先验（设计文档 4.6.5 v0.2 修正）', () {
    Song songWith(DateTime? d) =>
        Song(title: 'X', artist: 'Y', duration: 200, releaseDate: d, coverSeed: 0);

    double pub(DateTime release, int videoEpoch) {
      return MatchScorer.score(
        VideoCandidate(
          bvid: 'BV',
          title: 'X - Y',
          durationSec: 200,
          pubdate: videoEpoch,
        ),
        songWith(release),
      ).detail.s4Publish;
    }

    test('无发行时间 → 中性 0.5', () {
      final r = MatchScorer.score(
        const VideoCandidate(bvid: 'BV', title: 'X', durationSec: 200, pubdate: 1580000000),
        songWith(null),
      );
      expect(r.detail.s4Publish, 0.5);
    });

    test('早于发行 30 天以上 → 归零（v0.2 修正）', () {
      final release = DateTime(2020, 6, 1);
      // 视频发布于发行前 60 天
      final before = release.subtract(const Duration(days: 60));
      expect(pub(release, before.millisecondsSinceEpoch ~/ 1000), 0.00);
    });

    test('老歌搬运（3-10 年）→ 0.75，不重罚（v0.2 修正）', () {
      final release = DateTime(2005, 1, 1);
      final video = DateTime(2013, 1, 1);
      expect(pub(release, video.millisecondsSinceEpoch ~/ 1000), 0.75);
    });
  });

  group('MatchScorer — 降级路径（设计文档 10.1）', () {
    test('歌曲时长缺失 → 时长给中性分且置信度上限 REVIEW', () {
      const song = Song(title: '秘密', artist: '白浩寅', duration: 0, coverSeed: 0);
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BV',
          title: '白浩寅 - 秘密',
          author: '白浩寅',
          durationSec: 226,
          play: 500000,
          pubdate: 1580000000,
          typename: '音乐',
        ),
        song,
      );
      expect(r.detail.s2Duration, MatchConfig.durationNeutralScore);
      // 不允许在缺关键物理证据时自动绑定
      expect(r.confidence, isNot(MatchConfidence.auto));
    });

    test('歌手字段为空 → 标题维度权重提升到 0.45', () {
      const song = Song(title: 'Ave Maria', artist: '', duration: 200, coverSeed: 0);
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BV',
          title: 'Ave Maria',
          durationSec: 200,
          pubdate: 1580000000,
        ),
        song,
      );
      // 纯音乐无歌手，应能拿到较高分（权重转移生效）
      expect(r.total, greaterThan(0.5));
    });
  });

  group('MatchConfig', () {
    test('六维权重和为 1.0', () {
      const sum = MatchConfig.wTitleArtist +
          MatchConfig.wDuration +
          MatchConfig.wUploader +
          MatchConfig.wPublish +
          MatchConfig.wCategory +
          MatchConfig.wFormat;
      expect(sum, closeTo(1.0, 0.0001));
    });

    test('时长分档反推（设计文档 4.3.2）', () {
      expect(MatchConfig.durationFilterFor(226 * 1000), 1); // 3:46
      expect(MatchConfig.durationFilterFor(20 * 60 * 1000), 2); // 20 分
      expect(MatchConfig.durationFilterFor(45 * 60 * 1000), 3); // 45 分
      expect(MatchConfig.durationFilterFor(90 * 60 * 1000), 4); // 90 分
      expect(MatchConfig.durationFilterFor(0), 0);
    });

    test('分级阈值（设计文档 4.6.8）', () {
      expect(MatchScorer.grade(0.95), MatchConfidence.auto);
      expect(MatchScorer.grade(0.82), MatchConfidence.auto);
      expect(MatchScorer.grade(0.70), MatchConfidence.review);
      expect(MatchScorer.grade(0.62), MatchConfidence.review);
      expect(MatchScorer.grade(0.50), MatchConfidence.rejected);
    });

    test('动态时长容忍度：短歌收紧、长歌 30s 封顶', () {
      // 短歌：120s（2min） → 15% = 18s，远小于 30s 上限
      expect(MatchConfig.durationToleranceFor(120 * 1000), 18 * 1000);
      // 长歌：360s（6min） → 15% = 54s，但上限 30s
      expect(MatchConfig.durationToleranceFor(360 * 1000), 30 * 1000);
      // 边界：200s（3:20）→ 15% = 30s，刚好等于上限
      expect(MatchConfig.durationToleranceFor(200 * 1000), 30 * 1000);
      // 极短：60s（1min）→ 15% = 9s
      expect(MatchConfig.durationToleranceFor(60 * 1000), 9 * 1000);
      // 零时长：回退到上限（保险）
      expect(MatchConfig.durationToleranceFor(0), MatchConfig.durationToleranceMaxMs);
      // 负时长：同零处理
      expect(MatchConfig.durationToleranceFor(-1000), MatchConfig.durationToleranceMaxMs);
    });

    test('动态时长容忍度与硬过滤的联合效应', () {
      // 2min 歌容忍 18s，一首 2:25 的拼接视频（差 25s）应该被 Stage 2 杀掉
      const songMs = 120 * 1000;
      final tol = MatchConfig.durationToleranceFor(songMs);
      const diff = 25 * 1000;
      expect(diff > tol, isTrue, reason: '2min 歌容忍 18s，25s 差应该被硬过滤');

      // 5min 歌容忍 30s，同样 25s 差应该通过
      const longSongMs = 300 * 1000;
      final longTol = MatchConfig.durationToleranceFor(longSongMs);
      expect(25 * 1000 <= longTol, isTrue, reason: '5min 歌容忍 30s，25s 差应该通过');
    });
  });
}
