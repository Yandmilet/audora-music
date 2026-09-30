/// B站 API 客户端。
///
/// 职责：统一处理「取 Wbi key → 签名 → 限流 → 带完整请求头发起请求 → 解析 code」
/// 这条链路，并把 B站的 `code != 0` 转成 [BiliApiException]。
///
/// 设计文档 7.3 的两个必踩坑都在这里兜住：
///   1. bilivideo.com 的 CDN 校验 Referer，缺失直接 403
///   2. 搜索与 playurl 接口需要 Wbi 签名，且要有 buvid 类 Cookie
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../diag/diag_log.dart';
import '../net/rate_limiter.dart';
import 'bili_cookie_session.dart';
import 'bili_exception.dart';
import 'wbi_signer.dart';

/// 桌面 UA：B站对移动端 UA 的接口策略不同，统一用桌面 UA
const kDesktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const kDesktopReferer = 'https://www.bilibili.com';

class BiliApiClient {
  BiliApiClient({
    Dio? dio,
    BiliCookieSession? session,
    RateLimiter? rateLimiter,
  })  : dio = dio ?? _buildDio(),
        session = session ?? BiliCookieSession(dio ?? _buildDio()),
        rateLimiter =
            rateLimiter ?? RateLimiter(maxRequests: 30, window: const Duration(minutes: 1));

  final Dio dio;
  final BiliCookieSession session;

  /// 全局限流：每分钟不超过 30 次（设计文档 9.3 硬性要求）
  final RateLimiter rateLimiter;

  static Dio _buildDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.plain,
        // B站出错时仍返回 200 + code != 0，需要自行判断
        validateStatus: (s) => s != null && s < 500,
      ),
    );
  }

  /// 通用签名请求。
  ///
  /// [params] 会自动追加签名参数；[signed] = false 时只带 Cookie 不签名
  /// （如 playurl 的某些场景、view 详情接口）。
  ///
  /// [maxRetries] 透传给 [retryWithBackoff]。默认 3 次重试是为**后台批量
  /// 匹配**设计的——它跑在用户不看的地方，多等等换稳健值得。
  /// 但**交互式搜索**（手动搜索音源）用户正在盯着转圈，弱网下
  /// 「连接超时 10s × 4 次尝试 + 1s/2s/4s 退避」最坏要 40 秒以上才报错，
  /// 体验等于卡死。交互式调用方应传 1（首次 + 1 次重试，最坏 ~11s）。
  Future<Map<String, dynamic>> request(
    String url, {
    required Map<String, dynamic> params,
    bool signed = true,
    String? referer,
    int maxRetries = 3,
  }) async {
    final cookies = await session.effectiveCookies();

    final finalParams = <String, dynamic>{...params};
    if (signed) {
      final keys = await session.fetchWbiKeys();
      if (keys == null) {
        throw BiliNetworkException(
          '无法获取 Wbi 签名密钥（nav 接口不可达或返回异常）',
          endpoint: url,
        );
      }
      final signer = WbiSigner(keys.$1, keys.$2);
      finalParams
        ..clear()
        ..addAll(signer.sign(params));
    }

    Future<Map<String, dynamic>> attempt() async {
      // 限流等待单独计时：它是「配额够不够」的直接证据——
      // waitedMs 长期很高，说明请求量已经顶到 30 次/分钟的上限。
      final gate = Stopwatch()..start();
      await rateLimiter.acquire();
      final waitedMs = gate.elapsedMilliseconds;

      final sw = Stopwatch()..start();
      final endpoint = _endpointOf(url);
      try {
        final resp = await dio.get<dynamic>(
          url,
          queryParameters: finalParams,
          options: Options(
            headers: {
              'User-Agent': kDesktopUa,
              'Referer': referer ?? kDesktopReferer,
              'Origin': kDesktopReferer,
              if (!cookies.isEmpty) 'Cookie': cookies.toHeader(),
            },
          ),
        );

        final raw = resp.data;
        if (raw == null || (raw is String && raw.trim().isEmpty)) {
          throw BiliNetworkException('响应体为空', endpoint: url);
        }
        final map = raw is String
            ? jsonDecode(raw) as Map<String, dynamic>
            : raw as Map<String, dynamic>;

        final code = (map['code'] as num?)?.toInt() ?? -1;

        // -412 / -352 是风控触发：作废匿名 Cookie 缓存，让下次重取
        var risk = false;
        if (code == -412 || code == -352) {
          risk = true;
          session.setUserSession();
          DiagLog.instance.w(
            DiagCategory.net,
            '触发风控 $code：$endpoint',
            {
              'event': 'request',
              'endpoint': endpoint,
              'code': code,
              'waitedMs': waitedMs,
              'ms': sw.elapsedMilliseconds,
            },
          );
        }

        if (code != 0) {
          if (!risk) {
            DiagLog.instance.w(
              DiagCategory.net,
              '接口返回 $code：$endpoint',
              {
                'event': 'request',
                'endpoint': endpoint,
                'code': code,
                'message': map['message']?.toString() ?? '',
                'waitedMs': waitedMs,
                'ms': sw.elapsedMilliseconds,
              },
            );
          }
          throw BiliApiException(
            code: code,
            message: map['message']?.toString() ?? '未知错误',
            endpoint: url,
          );
        }

        DiagLog.instance.i(
          DiagCategory.net,
          '$endpoint ${sw.elapsedMilliseconds}ms',
          {
            'event': 'request',
            'endpoint': endpoint,
            'code': 0,
            // 只记接口路径，不记 query（含搜索词）与响应体（含流 URL）
            'waitedMs': waitedMs,
            'ms': sw.elapsedMilliseconds,
          },
        );
        return map;
      } on DioException catch (e) {
        DiagLog.instance.w(
          DiagCategory.net,
          '网络失败：$endpoint ${e.type.name}',
          {
            'event': 'request',
            'endpoint': endpoint,
            'error': e.message ?? e.type.name,
          },
        );
        throw BiliNetworkException(
          e.message ?? e.type.name,
          endpoint: url,
          cause: e.error,
        );
      }
    }

    return retryWithBackoff(
      attempt,
      maxRetries: maxRetries,
      shouldRetry: (e) => e is BiliApiException ? e.isRetryable : true,
      onRetry: (n, e) {
        // 每次重试都会再占一次限流额度——记下来才能看出
        // 「重试」到底吃掉了多少配额（这是 -412 之后的头号浪费点）
        DiagLog.instance.w(
          DiagCategory.net,
          '第 $n 次重试：${_endpointOf(url)}（$e）',
          {'event': 'retry', 'endpoint': _endpointOf(url), 'attempt': n},
        );
      },
    );
  }

  /// 只取接口路径用于日志：不落 query（搜索词属个人信息），
  /// 更不会落任何 Cookie / 签名串。
  static String _endpointOf(String url) {
    final u = Uri.tryParse(url);
    final path = u?.path ?? url;
    return path.isEmpty ? url : path;
  }

  /// 取 `data` 字段（B站标准响应结构）
  static Map<String, dynamic> dataOf(Map<String, dynamic> resp) {
    final d = resp['data'];
    return d is Map<String, dynamic> ? d : <String, dynamic>{};
  }
}
