/// B站接口调用的异常类型。
///
/// 错误码依据官方文档与 NeriPlayer 实践：
///   -412 请求被拦截（Cookie 缺失 / 频率过高）
///   -352 风控校验失败（需 buvid 类 Cookie）
///   -404 视频不存在
///   -403 权限不足（付费 / 受限视频）
library;

/// B站接口通用异常
class BiliApiException implements Exception {
  /// B站返回的 code（非 0 表示出错）
  final int code;

  /// B站返回的 message
  final String message;

  /// 出错的接口路径，便于定位
  final String endpoint;

  const BiliApiException({
    required this.code,
    required this.message,
    required this.endpoint,
  });

  /// 请求被拦截，通常是 Cookie 缺失或频率过高 → 应刷新 Cookie / 退避重试
  bool get isBlocked => code == -412 || code == -352;

  /// 视频不存在或已失效 → 该候选应被淘汰，不必重试
  bool get isNotFound => code == -404 || code == 62002 || code == 62004;

  /// 权限不足 → 该候选不可用，不必重试
  bool get isForbidden => code == -403 || code == 62011;

  /// 是否值得重试（限流类值得，资源类不值得）
  bool get isRetryable => isBlocked || code == -509 || code == -799;

  @override
  String toString() => 'BiliApiException($code) @$endpoint: $message';
}

/// 网络层异常（超时 / 连接失败 / 响应无法解析）
class BiliNetworkException implements Exception {
  final String message;
  final String endpoint;
  final Object? cause;

  const BiliNetworkException(this.message, {required this.endpoint, this.cause});

  @override
  String toString() => 'BiliNetworkException @$endpoint: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

/// 未找到匹配候选（算法层的正常结果，不算错误）
class NoCandidateException implements Exception {
  final String reason;
  const NoCandidateException(this.reason);

  @override
  String toString() => 'NoCandidateException: $reason';
}
