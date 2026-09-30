/// 限流器与并发控制。
///
/// 设计文档 9.3 明确要求：B站接口有频率限制，密集请求会触发 -412，
/// 个人项目应控制在**每分钟不超过 30 次请求**（`delay(800)` 不是可选项）。
library;

import 'dart:async';
import 'dart:collection';

/// 滑动窗口限流器。
///
/// 在 [window] 时间内最多放行 [maxRequests] 次请求，超出则等待到窗口释放。
class RateLimiter {
  final int maxRequests;
  final Duration window;

  /// 已放行请求的时间戳队列
  final Queue<DateTime> _history = Queue<DateTime>();

  /// 串行化闸门，避免并发请求同时通过检查
  Future<void> _gate = Future<void>.value();

  RateLimiter({this.maxRequests = 30, this.window = const Duration(minutes: 1)});

  /// 获取一个许可；必要时挂起等待。
  Future<void> acquire() {
    final completer = Completer<void>();
    _gate = _gate.then((_) async {
      try {
        while (true) {
          final now = DateTime.now();
          // 清理窗口外的历史记录
          while (_history.isNotEmpty &&
              now.difference(_history.first) > window) {
            _history.removeFirst();
          }
          if (_history.length < maxRequests) {
            _history.add(now);
            completer.complete();
            return;
          }
          // 窗口已满：等到最早那次请求滑出窗口
          final wait = window - now.difference(_history.first);
          await Future<void>.delayed(
            wait > Duration.zero ? wait : const Duration(milliseconds: 50),
          );
        }
      } catch (e, s) {
        if (!completer.isCompleted) completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// 当前窗口内已用次数（用于调试展示）
  int get usedInWindow {
    final now = DateTime.now();
    return _history.where((t) => now.difference(t) <= window).length;
  }

  void reset() => _history.clear();
}

/// 把列表按最大并发数 [n] 映射处理，保持结果顺序，丢弃 null 结果。
///
/// 对应设计文档 9.4 的 `mapWithConcurrency`：Stage 3 详情接口需要
/// 并发 3~5，但每个请求都要过限流。
Future<List<R>> mapWithConcurrency<T, R>(
  List<T> items,
  int n,
  Future<R?> Function(T item) block,
) async {
  if (items.isEmpty) return [];
  final results = List<R?>.filled(items.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      results[i] = await block(items[i]);
    }
  }

  final workers = List.generate(
    n < items.length ? n : items.length,
    (_) => worker(),
  );
  await Future.wait(workers);

  return results.whereType<R>().toList();
}

/// 指数退避重试：1s → 2s → 4s → 8s（最多 3 次重试）
///
/// 对应设计文档 10.1：B站限流返回 -412 时退避重试，
/// 仍失败则任务暂停并交由上层决定。
Future<T> retryWithBackoff<T>(
  Future<T> Function() task, {
  int maxRetries = 3,
  Duration initialDelay = const Duration(seconds: 1),
  bool Function(Object error)? shouldRetry,
  void Function(int attempt, Object error)? onRetry,
}) async {
  var delay = initialDelay;
  Object? lastError;
  StackTrace? lastStack;

  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await task();
    } catch (e, s) {
      lastError = e;
      lastStack = s;
      final retryable = shouldRetry?.call(e) ?? true;
      if (!retryable || attempt == maxRetries) break;
      onRetry?.call(attempt + 1, e);
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }
  Error.throwWithStackTrace(lastError!, lastStack!);
}
