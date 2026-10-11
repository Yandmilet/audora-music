/// P1 TitleParser 2.0 接入评分链路专项测试。
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:audora_music/services/match/match_scorer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P1-3 TitleParser 接入评分', () {
    const song = Song(
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      duration: 269,
      coverSeed: 0,
    );

    test('标准格式 title → 无 boost（contains 路径已经拿满分）', () {
      const v = VideoCandidate(
        bvid: 'BV',
        title: '周杰伦 - 晴天【官方MV】',
        durationSec: 269,
        pubdate: 1600000000,
      );
      final r = MatchScorer.score(v, song);
      // 标准格式 → tTitle=1.00，boost 守卫不满足
      expect(r.detail.s1TitleArtist, closeTo(1.0, 0.01));
    });

    test('非标准格式 "晴天 周杰伦 官方MV" → titleParserBoost +0.04', () {
      // TitleParser 无 `-` → artist='', parsed.title='晴天 周杰伦 官方MV'
      // nParsedTitle.startsWith('晴天') = true → titleParserBoost = 0.04
      const v = VideoCandidate(
        bvid: 'BV',
        title: '晴天 周杰伦 官方MV',
        durationSec: 269,
        pubdate: 1600000000,
      );
      final r = MatchScorer.score(v, song);
      // 纯 contains 路径 base = 0.9175 → + Album bonus 0.04 → 约 0.9575
      // (contains 标题 = 0.85, artist = 1.0 → 0.85*0.55+1.0*0.45 = 0.9175
      //  Album 叶惠美 在标题里? 不在 → Album bonus 不触发
      //  titleParserBoost +0.04 → 0.9575)
      expect(r.detail.s1TitleArtist, closeTo(0.9575, 0.02));
    });

    test('parsedTitle 不 startsWith song.title → titleParserBoost=0', () {
      // "揭秘白浩寅背后的秘密" → parsed.title 不以 "秘密" 开头 → 无 boost
      // 用不同 song：
      const songSecret = Song(
        title: '秘密',
        artist: '白浩寅',
        album: '秘密',
        duration: 226,
        coverSeed: 1,
        releaseDate: null,
      );
      const v = VideoCandidate(
        bvid: 'BV',
        title: '揭秘白浩寅背后的秘密',
        author: '某UP',
        durationSec: 226,
        play: 400000,
        pubdate: 1600000000,
        typename: '生活',
      );
      final r = MatchScorer.score(v, songSecret);
      // nParsedTitle = 揭秘白浩寅背后的秘密, nTitle = 秘密 → startsWith = false → boost = 0
      // 纯 contains 路径 base = 0.85*0.55 + 1.0*0.45 = 0.9175
      // 但 Album 同 title 不触发
      expect(r.detail.s1TitleArtist, closeTo(0.9175, 0.02));
      expect(r.confidence, isNot(MatchConfidence.auto));
    });

    test('完全不相关标题 → 不触发 boost（守卫防止假阳性）', () {
      const songSecret = Song(
        title: '秘密',
        artist: '白浩寅',
        album: '秘密',
        duration: 226,
        coverSeed: 1,
        releaseDate: null,
      );
      const v = VideoCandidate(
        bvid: 'BV',
        title: '揭秘白浩寅背后的秘密',
        author: '某UP',
        durationSec: 226,
        play: 400000,
        pubdate: 1600000000,
        typename: '生活',
      );
      final r = MatchScorer.score(v, songSecret);
      expect(r.confidence, isNot(MatchConfidence.auto));
    });
  });
}
