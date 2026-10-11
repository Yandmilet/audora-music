/// Stage 3 预筛用的轻量召回打分器（P0-1 新增）。
///
/// ## 为什么需要与 Final Score 分离
/// 当前 `_preselect()` 直接调用 `MatchScorer.score().total` 做 coarse score，
/// 但 MatchScorer 是为"最终选准"设计的，它把 UP主可信度、分区、文本规范度
/// 这些**只有详情接口才完整**的维度也算进去了。
///
/// 这导致一个危险后果：Stage 3 的 coarse score 同时承担了"召回排序"和
/// "淘汰候选"两个职责 —— 正确候选可能因为 S3（UP主）只有 0.4 分、S5（分区）
/// 详情未补全时拿中性分，coarse score 被压到 0.75，而另一个干扰项靠高播放量
/// 把 S3 顶到 0.6、S5 也是中性 0.5，coarse score 反而 0.78，
/// 于是正确候选被挡在详情请求之外。
///
/// ## RecallScorer 的设计目标：不漏
/// 只用**搜索接口就有的字段**：
///   - VideoCandidate.title / author / durationSec / typename / play
///   - Song.title / artist / duration / album
///
/// 不依赖详情接口补的 tag / cid / 精确 typename。
/// 权重偏向召回率（Recall）而非精确率（Precision）——
/// 宁可多给几个候选进详情接口，也不要把正确的挡在门外。
///
/// ## 与 MatchScorer 的职责边界
///   - RecallScorer：回答"这个候选值得进详情接口看一眼吗？"（Stage 3）
///   - MatchScorer：回答"候选里谁是正确音源？"（Stage 4）
library;

import '../../models/models.dart';
import '../bilibili/bili_dto.dart';
import 'match_config.dart';
import 'text_normalizer.dart';

class RecallScorer {
  RecallScorer._();

  /// 轻量召回打分：只用搜索接口字段。
  ///
  /// 返回值范围 [0, 1]，但这不是"匹配概率"，只是召回排序用的相对分数 ——
  /// 分数越低越可能是干扰项，但不代表"错"（详情接口补全后可能逆袭）。
  static double score(VideoCandidate v, Song song) {
    final songTitle = TextNormalizer.normalize(song.title);
    final songArtist1 = _firstArtist(song.artist);
    final songMs = song.duration * 1000;

    final nTitle = TextNormalizer.normalize(v.title);
    if (nTitle.isEmpty || songTitle.isEmpty) return 0.0;

    // ── 标题 + 歌手匹配（核心信号）─────────────────────
    var titleHit = 0.0;
    if (nTitle == songTitle) {
      titleHit = 1.0;
    } else if (nTitle.contains(songTitle)) {
      titleHit = 0.85;
    } else if (songTitle.contains(nTitle) && nTitle.length >= 4) {
      titleHit = 0.55;
    } else if (TextNormalizer.isFuzzyMatch(nTitle, songTitle, 0.75)) {
      titleHit = 0.35;
    } else {
      titleHit = 0.0; // 歌名根本没命中 → 直接给低分，召回阶段就过滤掉
    }

    // 歌手匹配（标题 contains 或 UP主名 contains）
    var artistHit = 0.0;
    if (songArtist1.isNotEmpty) {
      final nSongArtist = TextNormalizer.normalize(songArtist1);
      final nAuthor = TextNormalizer.normalize(v.author);
      if (nTitle.contains(nSongArtist)) {
        artistHit = 1.0;
      } else if (nAuthor.isNotEmpty && nAuthor.contains(nSongArtist)) {
        artistHit = 0.7;
      } else if (TextNormalizer.fuzzyContains(nTitle, nSongArtist, 0.85)) {
        artistHit = 0.4;
      }
    }

    // 合并：歌名完全没命中 → 0（不值得进详情）
    if (titleHit == 0.0) return 0.0;

    final titleArtistScore = artistHit == 0.0
        ? titleHit * 0.65 // 歌名命中但歌手没对上 → 打折
        : titleHit * 0.6 + artistHit * 0.4;

    // ── 时长粗差（搜索返回的 durationSec 精度够用）─────────
    var durScore = 0.5; // 无时长时中性
    if (songMs > 0 && v.durationSec > 0) {
      final diff = ((v.durationSec * 1000) - songMs).abs();
      final ratio = diff / songMs;

      // 绝对值 + 相对比例的软判定（不是硬过滤，只是排序信号）
      if (diff <= 3000 && ratio <= 0.10) {
        durScore = 1.0;
      } else if (diff <= 8000 && ratio <= 0.20) {
        durScore = 0.85;
      } else if (diff <= 15000 && ratio <= 0.35) {
        durScore = 0.65;
      } else if (diff <= 30000) {
        durScore = 0.4;
      } else {
        durScore = 0.15; // 硬过滤都过不了的 → 低分
      }
    }

    // ── 分区提示（搜索有时返回 typename）──────────────────
    var partBonus = 0.0;
    if (v.typename.isNotEmpty) {
      if (MatchConfig.musicPartitions.contains(v.typename)) {
        partBonus = 0.05;
      } else if (MatchConfig.lowRelevancePartitions.contains(v.typename)) {
        partBonus = -0.15; // 低相关分区减分，但不杀（硬过滤 Stage 2 已拦）
      }
    }

    // ── 播放量轻微 tiebreaker（±0.05 范围，不主导排序）────
    var playBonus = 0.0;
    if (v.play > 1000000) {
      playBonus = 0.05;
    } else if (v.play > 100000) {
      playBonus = 0.03;
    } else if (v.play > 10000) {
      playBonus = 0.01;
    }

    // ── 合并 ────────────────────────────────────────────
    // 标题歌手 + 时长是主信号（0.35 + 0.35 = 0.70），分区和播放量只做微调
    final score =
        titleArtistScore * 0.35 + durScore * 0.35 + partBonus + playBonus;

    return score.clamp(0.0, 1.0);
  }

  static String _firstArtist(String artist) {
    final a = artist.trim();
    if (a.isEmpty) return '';
    // 与 MatchScorer._splitArtists 保持一致的分隔符
    return a.split(RegExp('[/、,&]')).first.trim();
  }
}
