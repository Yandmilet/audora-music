/// v0.4 增量测试：VersionDetector 版本惩罚 + TitleParser 结构解析。
///
/// 对应设计文档 §4（标题解析）/ §5（版本惩罚）。
/// 运行：`flutter test test/match_v04_test.dart`
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:audora_music/services/match/match_scorer.dart';
import 'package:audora_music/services/match/title_parser.dart';
import 'package:audora_music/services/match/version_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VersionDetector.penalty — 设计文档 §5 惩罚表', () {
    test('伴奏 / instrumental → 0.25（最高档）', () {
      expect(VersionDetector.penalty('秘密 伴奏版'), 0.25);
      expect(VersionDetector.penalty('秘密 Instrumental'), 0.25);
    });

    test('翻唱 / cover → 0.20', () {
      expect(VersionDetector.penalty('秘密 翻唱'), 0.20);
      expect(VersionDetector.penalty('秘密 Cover'), 0.20);
    });

    test('remix → 0.20', () {
      expect(VersionDetector.penalty('秘密 Remix'), 0.20);
    });

    test('Live / 现场 → 0.05（轻罚不杀，正版 Live 不误过滤）', () {
      expect(VersionDetector.penalty('秘密 Live'), 0.05);
      expect(VersionDetector.penalty('秘密 现场版'), 0.05);
    });

    test('普通标题 / 官方MV → 0', () {
      expect(VersionDetector.penalty('白浩寅 - 秘密【官方MV】'), 0);
      expect(VersionDetector.penalty('秘密'), 0);
    });

    test('多类命中取最高档不累加', () {
      expect(VersionDetector.penalty('秘密 翻唱 remix Live'), 0.20);
      expect(VersionDetector.penalty('伴奏 cover'), 0.25);
    });

    test('大小写不敏感', () {
      expect(VersionDetector.penalty('SECRET LIVE'), 0.05);
      expect(VersionDetector.penalty('secret COVER'), 0.20);
    });

    // ── v0.6 新增模式 ────────────────────────────────────

    test('self cover / 自翻唱 → 0.10（原歌手自己唱自己，惩罚轻）', () {
      expect(VersionDetector.penalty('周杰伦 - 晴天 self cover'), 0.10);
      expect(VersionDetector.penalty('周杰伦 - 晴天 self-cover'), 0.10);
      expect(VersionDetector.penalty('周杰伦 - 晴天 self_cover'), 0.10);
      expect(VersionDetector.penalty('周杰伦 - 晴天 自翻唱'), 0.10);
    });

    test('self-cover 连字符不会被普通 cover 误匹配', () {
      // self-cover 是 0.10，普通 cover 是 0.20
      expect(VersionDetector.penalty('self cover'), 0.10);
      expect(VersionDetector.penalty('self-cover'), 0.10);
      expect(VersionDetector.penalty('self_cover'), 0.10);
      expect(VersionDetector.penalty('cover song'), 0.20);
    });

    test('acoustic / unplugged / 不插电 → 0.15', () {
      expect(VersionDetector.penalty('秘密 Acoustic'), 0.15);
      expect(VersionDetector.penalty('秘密 Unplugged'), 0.15);
      expect(VersionDetector.penalty('秘密 不插电版'), 0.15);
    });

    test('8bit / chiptune → 0.20', () {
      expect(VersionDetector.penalty('秘密 8bit'), 0.20);
      expect(VersionDetector.penalty('秘密 chiptune'), 0.20);
    });

    test('新增模式与已有模式同档时取最高档', () {
      // 0.20 档的多个词互撞
      expect(VersionDetector.penalty('8bit remix'), 0.20);
      // acoustic(0.15) + cover(0.20) → 取 0.20
      expect(VersionDetector.penalty('acoustic cover'), 0.20);
      // self cover(0.10) + live(0.05) → 取 0.10
      expect(VersionDetector.penalty('self cover live'), 0.10);
    });
  });

  group('TitleParser — 设计文档 §4 标题结构解析（备用件）', () {
    test('【4K修复】周杰伦 - 晴天 官方MV', () {
      final p = TitleParser.parse('【4K修复】周杰伦 - 晴天 官方MV');
      expect(p.artist, '周杰伦');
      expect(p.title, '晴天');
      expect(p.tags, contains('【4K修复】'));
    });

    test('多段连字符保留在歌名侧', () {
      final p = TitleParser.parse('周杰伦 - A-Train 官方MV');
      expect(p.artist, '周杰伦');
      expect(p.title, contains('A-Train'));
    });

    test('无标签无分隔符：artist 为空', () {
      final p = TitleParser.parse('晴天');
      expect(p.artist, '');
      expect(p.title, '晴天');
      expect(p.tags, isEmpty);
    });
  });

  group('MatchScorer × VersionDetector 集成', () {
    final song = Song(
      title: '秘密',
      artist: '白浩寅',
      album: '秘密',
      duration: 226,
      releaseDate: DateTime(2020, 1, 1),
      coverSeed: 1,
    );

    ScoredCandidate score(String title) => MatchScorer.score(
          VideoCandidate(
            bvid: 'BVtest',
            title: title,
            author: '某UP',
            durationSec: 226,
            play: 500000,
            pubdate: 1580000000,
            typename: '音乐',
          ),
          song,
        );

    test('普通标题：penalty=0，行为与 v0.3 完全一致', () {
      final r = score('白浩寅 - 秘密【官方MV】');
      expect(r.detail.penalty, 0);
      expect(r.confidence, MatchConfidence.auto);
    });

    test('Live 标题：总分恰降 0.05，penalty 落 detail', () {
      final plain = score('白浩寅 - 秘密');
      final live = score('白浩寅 - 秘密 Live');
      expect(live.detail.penalty, 0.05);
      expect(plain.detail.penalty, 0);
      expect(plain.total - live.total, closeTo(0.05, 1e-9));
    });

    test('伴奏标题：总分恰降 0.25', () {
      final plain = score('白浩寅 - 秘密');
      final accomp = score('白浩寅 - 秘密 伴奏');
      expect(accomp.detail.penalty, 0.25);
      expect(plain.total - accomp.total, closeTo(0.25, 1e-9));
    });

    test('ScoreDetail.toJson 含 penalty 键（score_detail 落库回溯用）', () {
      final json = score('白浩寅 - 秘密 Live').detail.toJson();
      expect(json['penalty'], 0.05);
      expect(json.containsKey('s1'), isTrue);
    });

    test('ScoreDetail.toString 含 P= 字段', () {
      final s = score('白浩寅 - 秘密 Live').detail.toString();
      expect(s, contains('P=0.05'));
    });

    test('惩罚不把总分压成负数', () {
      // 歌名完全对不上（s1=0）+ 伴奏惩罚：clamp 保底 0
      final r = score('完全无关的视频标题 伴奏');
      expect(r.total, greaterThanOrEqualTo(0));
      expect(r.total, lessThanOrEqualTo(1));
    });
  });
}
