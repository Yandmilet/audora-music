/// B站 Cookie 会话管理（三态策略）。
///
/// 对应设计文档 7.3.1：
///   1) 优先：用户已登录的 SESSDATA —— 可拿 192K 音质
///   2) 兜底：自动获取匿名指纹 Cookie —— 够用于搜索 / 详情 / 132K
///
/// 关键结论（经源码验证）：**不需要用户登录就能跑通整个匹配流程**。
/// 搜索与详情只要求 buvid3 等指纹 Cookie，而这些可以匿名自动获取。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// 匿名 Cookie 的获取结果
class BiliCookies {
  /// 指纹 Cookie 键值对（buvid3 / buvid4 / buvid_fp / b_lsid ...）
  final Map<String, String> values;

  /// 是否来自用户登录态（含 SESSDATA）
  final bool loggedIn;

  const BiliCookies({required this.values, this.loggedIn = false});

  static const empty = BiliCookies(values: {});

  bool get isEmpty => values.isEmpty;

  /// 拼成 HTTP Cookie 头
  String toHeader() =>
      values.entries.map((e) => '${e.key}=${e.value}').join('; ');

  @override
  String toString() =>
      'BiliCookies(${values.keys.join(",")}${loggedIn ? ", loggedIn" : ""})';
}

/// 指纹接口：返回 buvid3 / buvid4 等
const _fingerprintUrl = 'https://api.bilibili.com/x/frontend/finger/spi';

/// nav 接口：用于探测登录态与取 Wbi key
const _navUrl = 'https://api.bilibili.com/x/web-interface/nav';

/// 桌面 UA：指纹接口对 UA 敏感，用桌面端 UA 更稳
const _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// Cookie 会话：负责获取与缓存匿名指纹，并可选叠加用户 SESSDATA。
class BiliCookieSession {
  BiliCookieSession(this._dio);

  final Dio _dio;

  /// 缓存的匿名 Cookie
  BiliCookies? _cached;
  DateTime? _cachedAt;

  /// 缓存 1 小时，避免频繁请求指纹接口
  static const _cacheTtl = Duration(hours: 1);
  static const _fingerprintCacheTtl = Duration(hours: 1);

  /// 用户手动填入的 SESSDATA（可选）
  String? _sessdata;

  /// 用户手动填入的完整 Cookie 串（优先于 [_sessdata]）
  String? _userCookieHeader;

  /// 设置用户登录态（SESSDATA 或整串 Cookie）
  void setUserSession({String? sessdata, String? cookieHeader}) {
    _sessdata = (sessdata != null && sessdata.trim().isNotEmpty)
        ? sessdata.trim()
        : null;
    _userCookieHeader =
        (cookieHeader != null && cookieHeader.trim().isNotEmpty)
            ? cookieHeader.trim()
            : null;
    // 登录态变化要重新组合
    _cached = null;
    _cachedAt = null;
  }

  bool get hasUserSession =>
      _userCookieHeader != null || _sessdata != null;

  /// 只作废**匿名指纹**缓存，**保留用户登录态**（SESSDATA / Cookie 串）。
  ///
  /// ## 为什么不能直接用 setUserSession()
  /// `setUserSession()` 无参调用会把 [_sessdata] 与 [_userCookieHeader]
  /// 双双置 null —— 那是 `logout()` 的语义。而风控（-412/-352）的本意
  /// 只是「匿名指纹这台机器的指纹被风控盯上了，换一组重来」，
  /// 跟用户有没有登录是两回事。原先直接在风控分支调无参
  /// setUserSession()，结果一次普通限流就把用户静默踢回匿名，
  /// 丢掉 192K 音质，界面还给不出任何提示。
  ///
  /// -412 是 IP 维度拦截，换 Cookie 换不掉（见 docs/design-notes.md），
  /// 所以清掉匿名缓存、下次重新取指纹本来就是这条路径能做的全部。
  void invalidateAnonymousCookie() {
    _cached = null;
    _cachedAt = null;
  }

  /// 取当前可用的 Cookie；登录态优先，否则匿名。
  Future<BiliCookies> effectiveCookies() async {
    if (_userCookieHeader != null) {
      return BiliCookies(
        values: _parseCookieHeader(_userCookieHeader!),
        loggedIn: true,
      );
    }

    final anonymous = await _anonymousCookies();
    if (_sessdata == null) return anonymous;

    // 登录态：匿名指纹 + 用户 SESSDATA 合并（SESSDATA 用于解锁 192K）
    return BiliCookies(
      values: {...anonymous.values, 'SESSDATA': _sessdata!},
      loggedIn: true,
    );
  }

  /// 取匿名指纹 Cookie（带缓存）
  Future<BiliCookies> _anonymousCookies() async {
    final cached = _cached;
    final at = _cachedAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _fingerprintCacheTtl) {
      return cached;
    }

    final fetched = await _fetchAnonymousCookies();
    if (!fetched.isEmpty) {
      _cached = fetched;
      _cachedAt = DateTime.now();
      return fetched;
    }
    // 获取失败时退回本地生成的伪指纹，保证搜索接口不至于因缺 buvid3 直接 -412
    final fallback = BiliCookies(values: _pseudoFingerprint());
    _cached = fallback;
    _cachedAt = DateTime.now();
    return fallback;
  }

  /// 调指纹接口拿 buvid3 / buvid4
  Future<BiliCookies> _fetchAnonymousCookies() async {
    try {
      final resp = await _dio.get<dynamic>(
        _fingerprintUrl,
        options: Options(
          headers: {'User-Agent': _desktopUa},
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = resp.data;
      final map = body is String
          ? jsonDecode(body) as Map<String, dynamic>
          : body as Map<String, dynamic>;
      final data = map['data'] as Map<String, dynamic>?;
      if (data == null) return BiliCookies.empty;

      final values = <String, String>{};
      void put(String key, dynamic v) {
        final s = v?.toString() ?? '';
        if (s.isNotEmpty) values[key] = s;
      }

      // 字段名随接口版本略有差异，两种都兼容
      put('buvid3', data['b_3'] ?? data['buvid3']);
      put('buvid4', data['b_4'] ?? data['buvid4']);
      put('buvid_fp', data['buvid_fp']);
      put('b_lsid', data['b_lsid']);

      return BiliCookies(values: values);
    } catch (_) {
      return BiliCookies.empty;
    }
  }

  /// 本地生成的伪指纹。
  ///
  /// 指纹接口不可用时的兜底：buvid3 的形式是 `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXinfoc`，
  /// 服务端主要做「存在性」校验，随机值通常也能让搜索接口放行。
  Map<String, String> _pseudoFingerprint() {
    final now = DateTime.now().microsecondsSinceEpoch.toString();
    final rnd = md5.convert(utf8.encode(now)).toString();
    final uuid = '${rnd.substring(0, 8)}-${rnd.substring(8, 12)}-'
        '${rnd.substring(12, 16)}-${rnd.substring(16, 20)}-'
        '${rnd.substring(20, 32)}';
    final t = DateTime.now().millisecondsSinceEpoch;
    return {
      'buvid3': '${uuid}infoc',
      'buvid4': '${rnd.substring(0, 16)}-${t ~/ 1000}-${t % 1000}',
      'b_lsid': rnd.substring(0, 8).toUpperCase(),
    };
  }

  /// 解析形如 `a=1; b=2` 的 Cookie 串
  static Map<String, String> _parseCookieHeader(String header) {
    final result = <String, String>{};
    for (final part in header.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final k = part.substring(0, idx).trim();
      final v = part.substring(idx + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty) result[k] = v;
    }
    return result;
  }

  /// 探测当前是否具备登录态（nav 接口），顺便验证网络是否可达。
  Future<Map<String, dynamic>?> probeNav() async {
    try {
      final cookies = await effectiveCookies();
      final resp = await _dio.get<dynamic>(
        _navUrl,
        options: Options(
          headers: {
            'User-Agent': _desktopUa,
            'Referer': 'https://www.bilibili.com',
            if (!cookies.isEmpty) 'Cookie': cookies.toHeader(),
          },
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = resp.data;
      final map = body is String
          ? jsonDecode(body) as Map<String, dynamic>
          : body as Map<String, dynamic>;
      final data = map['data'];
      if (data is Map<String, dynamic>) {
        // wbi_img 附带在 nav 返回里，可顺带取签名 key
        return data;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// nav 接口返回里的 Wbi key（imgKey / subKey）
  Future<(String imgKey, String subKey)?> fetchWbiKeys() async {
    // 独立缓存 10 分钟
    final now = DateTime.now();
    if (_wbiKeys != null &&
        _wbiKeysAt != null &&
        now.difference(_wbiKeysAt!) < const Duration(minutes: 10)) {
      return _wbiKeys;
    }
    final data = await probeNav();
    final wbiImg = data?['wbi_img'] as Map<String, dynamic>?;
    if (wbiImg == null) return null;
    final img = wbiImg['img_url']?.toString() ?? '';
    final sub = wbiImg['sub_url']?.toString() ?? '';
    final keys = (
      _extractKey(img),
      _extractKey(sub),
    );
    if (keys.$1.isEmpty || keys.$2.isEmpty) return null;
    _wbiKeys = keys;
    _wbiKeysAt = now;
    return keys;
  }

  (String, String)? _wbiKeys;
  DateTime? _wbiKeysAt;

  static String _extractKey(String url) {
    if (url.isEmpty) return '';
    final name = url.split('?').first.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 缓存过期时间（供调试展示）
  Duration get cacheTtl => _cacheTtl;
}
