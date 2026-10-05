/// 播放统计：按位置流的增量累计收听时长，攒够门限落库。
///
/// ## 为什么从 AppState 拆出来（P3 组合式拆分，**不是** part 文件）
/// 自洽叶子模块：只依赖一个 repo 取值回调，不碰 UI / 队列 / 歌词。
/// AppState 保留同名转发（flushPlaybackStats 等），调用方无感。
///
/// ## 为什么要累计 listened 而不是直接读 position
/// `position` 是「当前播到第几秒」，用户可以来回拖——把它当收听时长会
/// 被 seek 污染（拖到 200 秒再拖回去，等于听了 400 秒）。
/// 这里按位置流的**增量**累加，且只在「递增且步长合理」时算，
/// 把拖动导致的大跳变过滤掉。
library;

import 'dart:async';

import '../data/db/dao/play_stats_dao.dart';
import '../data/repository/library_repository.dart';

class PlayStatsRecorder {
  PlayStatsRecorder({required LibraryRepository? Function() repo})
      : _repo = repo;

  final LibraryRepository? Function() _repo;

  /// 当前正在累计的歌。null = 没在统计（无 id 的 mock 歌等）。
  int? songId;

  int _listenedMs = 0;
  int _lastPosMs = 0;

  /// 换绑新歌并清零计数。调用前上一首必须已经 [flush] 过
  /// （AppState._playCurrent 的结算在最前面，正是为此）。
  void reset(int? newSongId) {
    songId = newSongId;
    _listenedMs = 0;
    _lastPosMs = 0;
  }

  /// 按位置流的增量累计本次收听时长（毫秒）。
  ///
  /// ## 为什么要过滤大跳变
  /// 用户拖动进度条时 position 会瞬间跳几秒甚至几分钟。若直接累加差值，
  /// 一次拖动就能把一首 3 分钟的歌「听」成 300 次。
  /// 只接受 **0 < 增量 <= 2 秒** 的正常推进，其余视为 seek 或跳变。
  void accumulate(Duration pos) {
    final id = songId;
    if (id == null) return;

    final ms = pos.inMilliseconds;
    final delta = ms - _lastPosMs;
    if (delta > 0 && delta <= 2000) {
      _listenedMs += delta;
    }
    _lastPosMs = ms;

    // 攒够门限就可以结算了，不必等到切歌——
    // 用户可能一直听同一首不切，等到切歌才记的话「常听」永远不更新。
    if (_listenedMs >= PlayStatsDao.countingThresholdMs) {
      final chunk = _listenedMs;
      _listenedMs = 0;
      unawaited(_write(id, chunk));
    }
  }

  /// 结算当前这首歌的收听时长（切歌 / 暂停 / 退出时调）
  Future<void> flush() async {
    final id = songId;
    if (id == null) return;
    final ms = _listenedMs;
    _listenedMs = 0;
    // 完全没听（<1 秒）不记流水——那是误触或加载失败，记了会污染「最近播放」
    if (ms < 1000) return;
    await _write(id, ms);
  }

  Future<void> _write(int songId, int ms) async {
    final repo = _repo();
    if (repo == null) return;
    try {
      await repo.recordPlay(songId, playedMs: ms);
    } catch (_) {
      // 统计失败不该影响播放，静默吞掉
    }
  }
}
