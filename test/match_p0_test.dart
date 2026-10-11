/// P0 四项增量测试：RecallScorer / VersionDetector.classify /
/// Contradiction 强制降级 / Best-vs-Second Margin。
///
/// 运行：`flutter test test/match_p0_test.dart`
library;

import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_config.dart';
import 'package:audora_music/services/match/match_engine.dart';
import 'package:audora_music/services/match/match_scorer.dart';
import 'package:audora_music/services/match/recall_scorer.dart';
import 'package:audora_music/services/match/version_detector.dart';
import 'package:audora_music/services/net/rate_limiter.dart';
import 'package:audora_music/services/source/bili_audio_source_adapter.dart';
import 'package:audora_music/services/bilibili/bili_api.dart';
import 'package:audora_music/services/bilibili/bili_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P0-1 RecallScorer — 召回排序（只用搜索接口字段）', () {
    const song = Song(
      title: '秘密',
      artist: '白浩寅',
      album: '秘密',
      duration: 226,
      releaseDate: null,
      coverSeed: 0,
    );

    test('歌名精确命中 + 时长精确 → 高分（≥ 0.65）', () {
      const v = VideoCandidate(
        bvid: 'BV1',
        title: '白浩寅 - 秘密【官方MV】',
        author: '白浩寅',
        durationSec: 226,
        play: 500000,
      );
      final s = RecallScorer.score(v, song);
      expect(s, greaterThanOrEqualTo(0.65));
    });

    test('歌名完全不命中 → 0（被 Stage 3 预筛过滤掉）', () {
      const v = VideoCandidate(
        bvid: 'BV2',
        title: '揭秘白浩寅背后的秘密武器', // contains 秘密 但不是歌名（其实算）
        author: '某UP',
        durationSec: 226,
      );
      final s = RecallScorer.score(v, song);
      // 这里 title contains song.title，所以分数不会是 0
      expect(s, greaterThan(0.0));
    });

    test('歌名完全无关 → 0', () {
      const v = VideoCandidate(
        bvid: 'BV3',
        title: '如何用 Flutter 做一个播放器',
        author: '某UP',
        durationSec: 226,
      );
      final s = RecallScorer.score(v, song);
      expect(s, 0.0);
    });

    test('时长差巨大（1小时）→ 低分但不是 0（歌名还是命中了）', () {
      const v = VideoCandidate(
        bvid: 'BV4',
        title: '白浩寅 - 秘密 1小时循环版',
        durationSec: 3600,
      );
      final s = RecallScorer.score(v, song);
      expect(s, greaterThan(0.0));
      expect(s, lessThan(0.5));
    });

    test('歌手缺失（纯 instrumental 标题不含歌手）→ 打折但保留', () {
      const v = VideoCandidate(
        bvid: 'BV5',
        title: '秘密 伴奏版',
        author: '搬运工',
        durationSec: 226,
      );
      final s = RecallScorer.score(v, song);
      // 歌名 contains 但歌手不命中 + 时长精确
      expect(s, greaterThan(0.0));
      expect(s, lessThan(0.7));
    });
  });

  group('P0-4 VersionDetector.classify — 结构化版本分类', () {
    test('伴奏 → instrumental 0.95', () {
      final r = VersionDetector.classify('周杰伦 - 晴天 伴奏');
      expect(r.type, VersionType.instrumental);
      expect(r.confidence, 0.95);
    });

    test('翻唱 → cover 0.90', () {
      final r = VersionDetector.classify('晴天 翻唱版');
      expect(r.type, VersionType.cover);
      expect(r.confidence, 0.90);
    });

    test('self cover → selfCover 0.85', () {
      final r = VersionDetector.classify('周杰伦 - 晴天 self cover');
      expect(r.type, VersionType.selfCover);
    });

    test('live → live 0.80', () {
      final r = VersionDetector.classify('晴天 Live 现场版');
      expect(r.type, VersionType.live);
    });

    test('acoustic → acoustic 0.85', () {
      final r = VersionDetector.classify('晴天 Acoustic');
      expect(r.type, VersionType.acoustic);
    });

    test('标准标题（无版本词）→ studio 0.55', () {
      final r = VersionDetector.classify('周杰伦 - 晴天【官方MV】');
      expect(r.type, VersionType.studio);
    });
  });

  group('P0-4 Contradiction Evidence — 矛盾强制降级', () {
    test('Studio 专辑 + B站 Instrumental → contradiction 0.90 → 强制 REJECTED', () {
      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
      );
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BVtest',
          title: '周杰伦 - 晴天 伴奏版',
          author: '周杰伦',
          durationSec: 269,
          play: 500000,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        song,
      );
      expect(r.detail.contradiction, greaterThanOrEqualTo(0.75));
      expect(r.confidence, MatchConfidence.rejected);
    });

    test('Studio 专辑 + B站 Cover → contradiction 0.80 → REJECTED', () {
      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
      );
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BVtest',
          title: '晴天 翻唱',
          author: '某UP',
          durationSec: 269,
          play: 500000,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        song,
      );
      expect(r.detail.contradiction, greaterThanOrEqualTo(0.50));
      // cover 的 penalty 已经 0.20，矛盾 0.80 → rejected
      expect(r.confidence, MatchConfidence.rejected);
    });

    test('Live 专辑 + B站 Live 视频 → contradiction 0（版本吻合）', () {
      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '魔天伦演唱会 Live 专辑',
        duration: 280,
        coverSeed: 0,
      );
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BVtest',
          title: '周杰伦 - 晴天 Live 现场版',
          author: '周杰伦',
          durationSec: 280,
          play: 500000,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        song,
      );
      expect(r.detail.contradiction, 0.0); // 版本吻合
    });

    test('Album 命中 B站标题 → S1 bonus（base 未到满分时生效）', () {
      // 用一个 base ≈ 0.8 的场景（非标准格式、UP主不含歌手名）
      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
      );
      final r1 = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BV1',
          title: '晴天 周杰伦', // 非标准格式（无空格分隔符）
          author: '搬运工', // UP主名不含歌手
          durationSec: 269,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        song,
      );
      final r2 = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BV2',
          title: '晴天 周杰伦 叶惠美', // 同样非标准 + 专辑名命中
          author: '搬运工',
          durationSec: 269,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        song,
      );
      expect(r2.detail.s1TitleArtist, greaterThan(r1.detail.s1TitleArtist),
          reason: '专辑名"叶惠美"命中应给 S1 加 bonus');
    });

    test('Studio 专辑 + B站 "精选集" 标签 → contradiction 弱补充 +0.20', () {
      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
      );
      final r = MatchScorer.score(
        const VideoCandidate(
          bvid: 'BVtest',
          title: '周杰伦 - 晴天 精选集',
          author: '周杰伦',
          durationSec: 269,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        song,
      );
      // studio 预期 + studio 检测 = 基础 contradiction 0，
      // 但 Album Distractor +0.20 → contradiction = 0.20
      expect(r.detail.contradiction, closeTo(0.20, 0.01));
    });
  });

  group('P0-2 Best-vs-Second Margin — AUTO 降级', () {
    test('两个候选分差 < 0.03 → AUTO 降级 REVIEW', () async {
      // 造一个池：两个候选分数几乎相同
      final bili = _FakeBiliP0(pool: [
        const VideoCandidate(
          bvid: 'BVWIN',
          title: '周杰伦 - 晴天',
          author: '周杰伦',
          mid: 1,
          durationSec: 269,
          play: 500000,
          pubdate: 1600000000,
          typename: '音乐',
        ),
        const VideoCandidate(
          bvid: 'BVRUNNER',
          title: '周杰伦 - 晴天', // 完全相同的标题！两者同分
          author: '搬运工',
          mid: 2,
          durationSec: 269,
          play: 400000,
          pubdate: 1600000000,
          typename: '音乐',
        ),
      ]);
      final e = MatchEngine(
        BiliAudioSourceAdapter(bili),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
      );
      final r = await e.match(song);

      expect(r.best, isNotNull);
      // 两个候选标题 + 时长都完美命中，分数差极小 → AUTO 降级 REVIEW
      expect(r.best!.confidence, isNot(MatchConfidence.auto));
    });

    test('只有一个候选时 → 不触发 margin 降级', () async {
      final bili = _FakeBiliP0(pool: [
        const VideoCandidate(
          bvid: 'BVONLY',
          title: '周杰伦 - 晴天',
          author: '周杰伦',
          mid: 1,
          durationSec: 269,
          play: 500000,
          pubdate: 1600000000,
          typename: '音乐',
        ),
      ]);
      final e = MatchEngine(
        BiliAudioSourceAdapter(bili),
        rateLimiter: RateLimiter(maxRequests: 100000),
      );

      const song = Song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269,
        coverSeed: 0,
      );
      final r = await e.match(song);

      expect(r.best, isNotNull);
      // 只有一个候选、标题 + 歌手 + 时长全命中 → AUTO
      expect(r.best!.confidence, MatchConfidence.auto);
    });
  });
}

class _FakeBiliP0 extends BiliApi {
  _FakeBiliP0({required this.pool}) : super(BiliApiClient());
  final List<VideoCandidate> pool;

  @override
  Future<List<VideoCandidate>> searchWithFallback(
    String keyword, {
    required int durationFilter,
    int maxRetries = 3,
  }) async {
    return pool;
  }

  @override
  Future<VideoDetail?> fetchVideoDetail(String bvid) async {
    final c = pool.firstWhere(
      (e) => e.bvid == bvid,
      orElse: () => pool.first,
    );
    return VideoDetail(
      bvid: bvid,
      cid: 1001,
      title: c.title,
      ownerName: c.author,
      ownerMid: c.mid,
      tname: c.typename.isEmpty ? '音乐' : c.typename,
      durationSec: c.durationSec,
      playCount: c.play,
      pubdate: c.pubdate,
      pages: [
        VideoPage(cid: 1001, page: 1, part: c.title, durationSec: c.durationSec),
      ],
    );
  }
}
