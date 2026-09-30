/// B站扫码登录：二维码生成 + 轮询 + 凭证提取。
///
/// ## 为什么需要它
/// 匿名指纹 Cookie 能跑通搜索 / 详情 / 132K，但有两个天花板：
///   1. **配额更紧**：风控（-412）对匿名请求明显更敏感
///   2. **拿不到 192K / Hi-Res**：高码率音频要求登录态
/// 登录态是唯一「正当」的扩容手段——用的是用户自己的账号，
/// 而不是多开指纹绕过风控（后者是对抗性设计，不采用）。
///
/// ## 接口（passport.bilibili.com，公开 Web 登录流程）
///   生成  GET /x/passport-login/web/qrcode/generate        → qrcode_key + url
///   轮询  GET /x/passport-login/web/qrcode/poll?qrcode_key= → 双层 code
///
/// ## 三个关键结构（踩过坑才写在这里）
/// 1. **双层 code**：响应是 `code` + `data.code` 两层。外层是「请求层业务码」
///    （0 = 请求成功），`data.code` 才是**扫码业务码**。
///    只判外层会把「未扫码 / 已扫码待确认」误判成登录成功。
/// 2. **凭证位置不固定**：扫码成功后 SESSDATA 可能出现在五个地方，
///    必须按优先级「命中即用」（见 [BiliQrCredentials.fromPoll]）。
///    只认其中一个，表现就是「扫了码却没生效」。
/// 3. **passport 的 Referer 必须是登录页**：带 www 域访问 passport 接口时，
///    扫码成功响应可能**不下发登录凭证**（拦截器里已按 host 分流）。
///
/// ## 安全红线
/// 凭证**只返回给调用方**，不打印值、不落日志。诊断日志里只记
/// 「命中了哪一级来源」这类元信息，**禁止出现** SESSDATA / bili_jct 的值。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../diag/diag_log.dart';
import 'bili_cookie_session.dart';

/// 二维码状态（UI 直接按它渲染文案）
enum BiliQrStatus {
  /// 等待扫码
  pending,

  /// 已扫码，等待手机端确认
  scanned,

  /// 二维码已失效（约 3 分钟），需重新生成
  expired,

  /// 登录成功
  success,

  /// 网络或解析失败
  failed;

  /// 扫码业务码 → 状态。未知码一律按 [failed]（比一直转圈诚实）。
  static BiliQrStatus fromBizCode(int code) => switch (code) {
        0 => BiliQrStatus.success,
        86090 => BiliQrStatus.scanned,
        // 86101 与 86039 都是「未扫码」：服务端按客户端类型给不同值，
        // 只认一个就会表现为「明明没扫，却判成了别的态」
        86101 || 86039 => BiliQrStatus.pending,
        86038 => BiliQrStatus.expired,
        _ => BiliQrStatus.failed,
      };
}

/// 生成结果
class BiliQrTicket {
  /// 供二维码编码的登录地址
  final String url;

  /// 轮询用的 key
  final String key;

  const BiliQrTicket({required this.url, required this.key});
}

/// 轮询结果
class BiliQrPoll {
  final BiliQrStatus status;

  /// 登录成功时的完整 Cookie 串（含 SESSDATA）
  final String? cookieHeader;

  /// 失败原因（status == failed 时非空）
  final String? error;

  /// 是否被风控拦截（-352 / -412）。此时**不要重试**——
  /// 越重试封得越久，只提示用户过一会儿再来。
  final bool riskControl;

  const BiliQrPoll._(this.status,
      {this.cookieHeader, this.error, this.riskControl = false});

  static const pending = BiliQrPoll._(BiliQrStatus.pending);
  static const scanned = BiliQrPoll._(BiliQrStatus.scanned);
  static const expired = BiliQrPoll._(BiliQrStatus.expired);

  factory BiliQrPoll.success(String cookieHeader) =>
      BiliQrPoll._(BiliQrStatus.success, cookieHeader: cookieHeader);

  factory BiliQrPoll.failed(String error, {bool riskControl = false}) =>
      BiliQrPoll._(BiliQrStatus.failed, error: error, riskControl: riskControl);

  bool get done =>
      status == BiliQrStatus.success || status == BiliQrStatus.failed;
}

class BiliQrLogin {
  BiliQrLogin({Dio? dio, BiliCookieSession? session}) : _session = session {
    final base = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.plain,
          // B站错误走 200 + body.code；HTTP 层只挡 5xx
          validateStatus: (s) => s != null && s < 500,
        ));
    // 包一层自己的 Dio：复用外部注入的 adapter（测试可 mock），
    // 但必须挂上 Set-Cookie 累积拦截器——jar 是凭证兜底链的第一优先级。
    _dio = Dio()
      ..options = base.options
      ..httpClientAdapter = base.httpClientAdapter
      ..interceptors.add(InterceptorsWrapper(
        onRequest: _onRequest,
        onResponse: _onResponse,
      ));
  }

  late final Dio _dio;

  /// 复用 app 的那个会话：登录成功后直接把 Cookie 注入进去，
  /// 后续所有 B站请求立刻用上登录态（无需重启应用）。
  final BiliCookieSession? _session;

  /// Set-Cookie 累积（generate / poll 链路下发，登录凭证最可靠的来源）
  final Map<String, String> _jar = {};

  /// 本次会话要带的手工 Cookie（含匿名指纹 buvid3），生成二维码前注入一次
  Map<String, String>? _manualCookies;

  /// 二维码有效期（秒）：本地倒计时与轮询上限都按它算
  static const int validSeconds = 180;

  /// 轮询建议间隔：固定 2 秒。更短的间隔只会招来 -412
  static const Duration pollInterval = Duration(seconds: 2);

  static const _generateUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
  static const _pollUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';

  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// passport 链路的 Referer 必须是登录页本身：
  /// 带 www 域访问 passport 接口时，扫码成功可能不下发凭证
  static const _passportReferer = 'https://passport.bilibili.com/login';
  static const _wwwReferer = 'https://www.bilibili.com';

  /// 登录态必需的 Cookie 键。Cookie 串要落盘，多一个都不留。
  static const Set<String> _credKeys = {
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
  };

  // ── 拦截器 ────────────────────────────────────────────────

  void _onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final isPassport = options.uri.host == 'passport.bilibili.com';
    options.headers['User-Agent'] = _desktopUa;
    options.headers['Referer'] =
        isPassport ? _passportReferer : _wwwReferer;
    options.headers['Origin'] =
        isPassport ? 'https://passport.bilibili.com' : _wwwReferer;

    // 手工凭证优先，jar 补缺：无脑拼接会让同名键在 Cookie 头里出现两次，
    // 服务端取哪个就不确定了
    final manual = _manualCookies ?? const <String, String>{};
    final jarPart = _jar.entries
        .where((e) => !manual.containsKey(e.key))
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    final cookie = [
      ...manual.entries.map((e) => '${e.key}=${e.value}'),
      if (jarPart.isNotEmpty) jarPart,
    ].join('; ');
    if (cookie.isNotEmpty) options.headers['Cookie'] = cookie;
    handler.next(options);
  }

  void _onResponse(Response<dynamic> res, ResponseInterceptorHandler handler) {
    _storeCookies(res.headers);
    handler.next(res);
  }

  void _storeCookies(Headers headers) {
    final raw = headers['set-cookie'];
    if (raw == null) return;
    for (final line in raw) {
      final first = line.split(';').first;
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (name.isEmpty) continue;
      // 空值 / Max-Age=0 是删除指令
      final parts = line.split(';').map((p) => p.trim().toUpperCase());
      if (value.isEmpty || parts.contains('MAX-AGE=0')) {
        _jar.remove(name);
      } else {
        _jar[name] = value;
      }
    }
  }

  // ── 对外流程 ──────────────────────────────────────────────

  /// 申请一个登录二维码。
  ///
  /// 顺序有讲究：先取匿名指纹（passport 对无指纹请求不友好），
  /// 再清空 jar（每次登录会话干净开始），最后才生成。
  Future<BiliQrTicket> generate() async {
    _jar.clear();
    if (_session != null) {
      // effectiveCookies 内部已有 1 小时缓存与失败兜底，拿不到也不阻塞
      try {
        _manualCookies = (await _session.effectiveCookies()).values;
      } catch (_) {
        _manualCookies = null;
      }
    }

    final resp = await _dio.get<dynamic>(_generateUrl);
    final map = _decode(resp.data);
    final outer = (map?['code'] as num?)?.toInt();
    if (outer != null && outer != 0) {
      throw StateError('二维码生成失败：${map?['message'] ?? 'code=$outer'}');
    }
    final data = map?['data'] as Map<String, dynamic>?;
    final key = data?['qrcode_key']?.toString() ?? '';
    final url = data?['url']?.toString() ?? '';
    if (key.isEmpty || url.isEmpty) {
      throw StateError('二维码生成失败：${map?['message'] ?? '返回缺少 qrcode_key'}');
    }
    return BiliQrTicket(url: url, key: key);
  }

  /// 轮询一次。固定 2 秒节奏，由调用方驱动。
  Future<BiliQrPoll> poll(String key) async {
    final Response<dynamic> resp;
    try {
      resp = await _dio.get<dynamic>(
        _pollUrl,
        queryParameters: {'qrcode_key': key},
      );
    } on DioException catch (e) {
      // 网络抖动交给上层决定要不要重试（单次超时 ≠ 登录失败）
      return BiliQrPoll.failed('网络异常：${e.type.name}');
    }

    final map = _decode(resp.data);
    if (map == null) return BiliQrPoll.failed('轮询响应无法解析');

    final outerCode = (map['code'] as num?)?.toInt() ?? -1;
    final data = map['data'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    // 内层缺失时回落外层：兼容只返回单层 code 的老结构
    final bizCode = (data['code'] as num?)?.toInt() ?? outerCode;

    // 风控：无论出现在哪一层都必须立刻终止。**不能重试。**
    if (outerCode == -352 || outerCode == -412 ||
        bizCode == -352 || bizCode == -412) {
      _diag(false, '风控拦截');
      return BiliQrPoll.failed('请求被风控拦截，请稍后再试', riskControl: true);
    }

    final status = BiliQrStatus.fromBizCode(bizCode);
    // 外层非 0 且内层也没有可识别语义 → 请求层就失败了
    if (outerCode != 0 && status == BiliQrStatus.failed) {
      _diag(false, '外层 code=$outerCode');
      return BiliQrPoll.failed('接口返回 $outerCode：${map['message'] ?? ''}');
    }

    switch (status) {
      case BiliQrStatus.success:
        final url = data['url']?.toString() ?? '';
        var creds = BiliQrCredentials.fromPoll(
          jar: _jar,
          cookieInfo: data['cookie_info'],
          url: url,
          responseCookies: _cookiesFromSetCookie(resp.headers),
        );
        // 第五级兜底：主动请求跨域激活链接，跟随重定向后取最终 Set-Cookie
        if (!creds.complete) {
          final viaActivate = await _cookiesFromActivateUrl(url);
          if (viaActivate != null) {
            creds = BiliQrCredentials(viaActivate, 'activate');
          }
        }
        if (!creds.complete) {
          _diag(false, '凭证不全 source=${creds.source}');
          return BiliQrPoll.failed('登录凭证解析失败，请重试');
        }
        _diag(true, 'source=${creds.source}');
        return BiliQrPoll.success(_toHeader(creds.values));
      case BiliQrStatus.scanned:
        return BiliQrPoll.scanned;
      case BiliQrStatus.pending:
        return BiliQrPoll.pending;
      case BiliQrStatus.expired:
        return BiliQrPoll.expired;
      case BiliQrStatus.failed:
        final msg =
            data['message']?.toString() ?? map['message']?.toString() ?? '';
        _diag(false, 'biz=$bizCode');
        return BiliQrPoll.failed('未知状态 code=$bizCode $msg'.trim());
    }
  }

  /// 登录成功后注入 user cookie 的时机由调用方决定；这里只提供
  /// 「主动 GET 跨域激活链接」这一级兜底（失败静默）。
  Future<Map<String, String>?> _cookiesFromActivateUrl(String url) async {
    if (url.isEmpty) return null;
    try {
      final res = await _dio.get<dynamic>(url);
      final creds = pickCredentials(_cookiesFromSetCookie(res.headers));
      // 只有 SESSDATA 没有 bili_jct 同样无法完成后续鉴权操作
      return (creds['SESSDATA'] ?? '').isNotEmpty &&
              (creds['bili_jct'] ?? '').isNotEmpty
          ? creds
          : null;
    } catch (_) {
      return null;
    }
  }

  // ── 纯函数区（可单测）──────────────────────────────────────

  /// 从 cross-domain 跳转地址提取 Cookie 串。
  ///
  /// 只保留登录必需字段，其余丢弃——Cookie 串会落盘，越少越好。
  /// **没有 SESSDATA 时返回空串**：只有 uid 没有会话串等于没登录，
  /// 返回非空会让调用方误判成功（表现为「扫了码却还是匿名态」）。
  static String cookieHeaderFromLoginUrl(String url) {
    final creds = cookiesFromLoginUrl(url);
    if ((creds['SESSDATA'] ?? '').isEmpty) return '';
    return _toHeader(creds);
  }

  /// 同 [cookieHeaderFromLoginUrl]，返回键值对以便与其它来源合并判定。
  static Map<String, String> cookiesFromLoginUrl(String url) {
    final idx = url.indexOf('?');
    if (idx < 0) return const {};
    final out = <String, String>{};
    for (final part in url.substring(idx + 1).split('&')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final k = part.substring(0, eq);
      if (!_credKeys.contains(k)) continue;
      final v = part.substring(eq + 1);
      if (v.isEmpty) continue;
      out[k] = v;
    }
    return out;
  }

  /// 新版标准字段：`data.cookie_info.cookies = [{name, value}, ...]`
  static Map<String, String> cookiesFromCookieInfo(dynamic info) =>
      pickCredentials(_flattenCookieInfo(info));

  static Map<String, String> _flattenCookieInfo(dynamic info) {
    if (info is! Map<String, dynamic>) return const {};
    final list = info['cookies'];
    if (list is! List) return const {};
    final out = <String, String>{};
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final name = item['name'] as String?;
      final value = item['value'] as String?;
      if (name == null || name.isEmpty || value == null || value.isEmpty) {
        continue;
      }
      out[name] = value;
    }
    return out;
  }

  /// 从任意来源的键值表里挑出登录必需字段
  static Map<String, String> pickCredentials(Map<String, String> src) => {
        for (final e in src.entries)
          if (_credKeys.contains(e.key) && e.value.isNotEmpty) e.key: e.value,
      };

  static Map<String, String> _cookiesFromSetCookie(Headers headers) {
    final out = <String, String>{};
    final raw = headers['set-cookie'];
    if (raw == null) return out;
    for (final line in raw) {
      final first = line.split(';').first;
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      out[name] = value;
    }
    return out;
  }

  static String _toHeader(Map<String, String> values) =>
      values.entries.map((e) => '${e.key}=${e.value}').join('; ');

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) {
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _diag(bool ok, String detail) {
    final entry = <String, Object?>{
      'event': 'qr_login',
      'ok': ok,
      'detail': detail,
    };
    if (ok) {
      DiagLog.instance
          .i(DiagCategory.ui, 'B站扫码登录成功（$detail）', entry);
    } else {
      // 失败要在摘要级可见——这是用户唯一能反馈给我们的材料
      DiagLog.instance
          .w(DiagCategory.ui, 'B站扫码登录失败（$detail）', entry);
    }
  }
}

/// 凭证兜底链的判定结果：值 + 命中来源（来源名进日志，值永远不进）。
class BiliQrCredentials {
  const BiliQrCredentials(this.values, this.source);

  final Map<String, String> values;
  final String source;

  /// SESSDATA 与 bili_jct 缺一不可：前者是会话，后者是 CSRF token，
  /// 只有前者等于「能看不能写」，后续任何写操作都会失败。
  bool get complete =>
      (values['SESSDATA'] ?? '').isNotEmpty &&
      (values['bili_jct'] ?? '').isNotEmpty;

  /// 五级凭证兜底链，顺序固定、**命中即用**。
  ///
  /// B站返回凭证的位置随客户端与版本变化，只认一种必然在某些机型上翻车。
  /// 抽成静态方法是为了能单测——「扫了码却没生效」最难复现，必须钉死。
  static BiliQrCredentials fromPoll({
    required Map<String, String> jar,
    required dynamic cookieInfo,
    required String url,
    required Map<String, String> responseCookies,
  }) {
    final candidates = <(String name, Map<String, String>)>[
      ('jar', BiliQrLogin.pickCredentials(jar)),
      ('cookie_info', BiliQrLogin.cookiesFromCookieInfo(cookieInfo)),
      ('url', BiliQrLogin.cookiesFromLoginUrl(url)),
      ('set-cookie', BiliQrLogin.pickCredentials(responseCookies)),
    ];
    for (final c in candidates) {
      final creds = BiliQrCredentials(c.$2, c.$1);
      if (creds.complete) return creds;
    }
    // 都不完整：留一个「最接近」的结果，source 里带 partial 便于定位
    for (final c in candidates) {
      if (c.$2.isNotEmpty) return BiliQrCredentials(c.$2, '${c.$1}-partial');
    }
    return const BiliQrCredentials(<String, String>{}, 'none');
  }
}
