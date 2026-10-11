/// B站扫码登录的解析逻辑测试（不联网）。
///
/// 联网部分（真机扫码）没法进单测，但**两类故障**完全可以在这里钉死：
///   1. 轮询响应的双层 code 判错 → 「还没扫就判成功 / 扫了却判失败」
///   2. 凭证提取渠道不全 → 「扫了码却没生效」
/// 这两类都由本地纯函数决定，且一旦回归很难在真机上稳定复现，所以必须有
/// 假 dio 适配器把整条链路（含 Set-Cookie 累积）跑一遍。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:audora_music/screens/bili_login_page.dart';
import 'package:audora_music/services/bilibili/bili_login.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cookieHeaderFromLoginUrl', () {
    test('提取登录必需字段，丢弃其它', () {
      const url = 'https://passport.bilibili.com/x/passport-login/web/'
          'cross-domain?DedeUserID=123456&DedeUserID__ckMd5=abcdef'
          '&Expires=1800&SESSDATA=xyz%2C123&bili_jct=token123'
          '&sid=abc&gourl=https%3A%2F%2Fwww.bilibili.com';
      final header = BiliQrLogin.cookieHeaderFromLoginUrl(url);

      expect(header, contains('SESSDATA=xyz%2C123'));
      expect(header, contains('bili_jct=token123'));
      expect(header, contains('DedeUserID=123456'));
      expect(header, contains('sid=abc'));
      // Expires / gourl 不是 Cookie，不该混进来（Cookie 串要落盘，越少越好）
      expect(header, isNot(contains('Expires')));
      expect(header, isNot(contains('gourl')));
    });

    test('缺 SESSDATA 时返回空串（调用方据此判失败）', () {
      const url = 'https://passport.bilibili.com/cross-domain?DedeUserID=1';
      expect(BiliQrLogin.cookieHeaderFromLoginUrl(url), isEmpty);
    });

    test('空串 / 无 query 时安全返回', () {
      expect(BiliQrLogin.cookieHeaderFromLoginUrl(''), isEmpty);
      expect(
        BiliQrLogin.cookieHeaderFromLoginUrl('https://passport.bilibili.com'),
        isEmpty,
      );
    });
  });

  group('扫码业务码 → 状态', () {
    test('四种正常码各自归位', () {
      expect(BiliQrStatus.fromBizCode(0), BiliQrStatus.success);
      expect(BiliQrStatus.fromBizCode(86090), BiliQrStatus.scanned);
      expect(BiliQrStatus.fromBizCode(86038), BiliQrStatus.expired);
    });

    test('86101 与 86039 都是「未扫码」（服务端按客户端给不同值）', () {
      expect(BiliQrStatus.fromBizCode(86101), BiliQrStatus.pending);
      expect(BiliQrStatus.fromBizCode(86039), BiliQrStatus.pending);
    });

    test('未知码判失败而不是继续转圈', () {
      expect(BiliQrStatus.fromBizCode(12345), BiliQrStatus.failed);
    });
  });

  group('凭证兜底链', () {
    const full = {
      'SESSDATA': 'aaaa',
      'bili_jct': 'bbbb',
      'DedeUserID': '123',
    };

    test('jar 命中即用（最高优先级）', () {
      final c = BiliQrCredentials.fromPoll(
        jar: {...full, 'buvid3': 'xxx'},
        cookieInfo: null,
        url: 'https://a/b?SESSDATA=fromurl&bili_jct=fromurl',
        responseCookies: const {},
      );
      expect(c.complete, isTrue);
      expect(c.source, 'jar');
      // jar 里的无关 Cookie 不进凭证（落盘字段越少越好）
      expect(c.values.containsKey('buvid3'), isFalse);
    });

    test('jar 不全时回落到 cookie_info', () {
      final c = BiliQrCredentials.fromPoll(
        jar: const {'SESSDATA': 'only-session'},
        cookieInfo: {
          'cookies': [
            {'name': 'SESSDATA', 'value': 'aaaa'},
            {'name': 'bili_jct', 'value': 'bbbb'},
          ],
        },
        url: '',
        responseCookies: const {},
      );
      expect(c.complete, isTrue);
      expect(c.source, 'cookie_info');
    });

    test('再回落到 data.url 查询参数', () {
      final c = BiliQrCredentials.fromPoll(
        jar: const {},
        cookieInfo: null,
        url: 'https://p/x?SESSDATA=fromurl&bili_jct=fromurl&Expires=1',
        responseCookies: const {},
      );
      expect(c.complete, isTrue);
      expect(c.source, 'url');
      expect(c.values['SESSDATA'], 'fromurl');
    });

    test('最后回落到本次响应的 Set-Cookie 头', () {
      final c = BiliQrCredentials.fromPoll(
        jar: const {},
        cookieInfo: null,
        url: '',
        responseCookies: const {'SESSDATA': 'h1', 'bili_jct': 'h2'},
      );
      expect(c.complete, isTrue);
      expect(c.source, 'set-cookie');
    });

    test('全都没有 → 不完整且来源为 none', () {
      final c = BiliQrCredentials.fromPoll(
        jar: const {'buvid3': 'x'},
        cookieInfo: null,
        url: '',
        responseCookies: const {},
      );
      expect(c.complete, isFalse);
      expect(c.source, 'none');
    });

    test('只有 SESSDATA 没有 bili_jct 也算不完整（写操作会失败）', () {
      final c = BiliQrCredentials.fromPoll(
        jar: const {'SESSDATA': 'only'},
        cookieInfo: null,
        url: '',
        responseCookies: const {},
      );
      expect(c.complete, isFalse);
      expect(c.source, 'jar-partial');
    });
  });

  group('poll 端到端（假适配器，不发真请求）', () {
    test('双层结构：data.code=86090 → 已扫码待确认', () async {
      final login = BiliQrLogin(dio: _dioReturning(jsonEncode({
        'code': 0,
        'message': '0',
        'data': {'code': 86090, 'message': '二维码已扫码未确认'},
      })));
      final r = await login.poll('k');
      expect(r.status, BiliQrStatus.scanned);
    });

    test('单层结构：外层 code=86038 → 已失效（老接口形态兼容）', () async {
      final login = BiliQrLogin(dio: _dioReturning(jsonEncode({
        'code': 86038,
        'message': '二维码已失效',
      })));
      final r = await login.poll('k');
      expect(r.status, BiliQrStatus.expired);
    });

    test('成功：凭证来自 cookie_info 时也能提取', () async {
      final login = BiliQrLogin(dio: _dioReturning(jsonEncode({
        'code': 0,
        'data': {
          'code': 0,
          'url': '',
          'cookie_info': {
            'cookies': [
              {'name': 'SESSDATA', 'value': 's1'},
              {'name': 'bili_jct', 'value': 'j1'},
              {'name': 'DedeUserID', 'value': '9527'},
            ],
          },
        },
      })));
      final r = await login.poll('k');
      expect(r.status, BiliQrStatus.success);
      expect(r.cookieHeader, contains('SESSDATA=s1'));
      expect(r.cookieHeader, contains('bili_jct=j1'));
    });

    test('成功：凭证来自 generate/poll 链路累积的 Set-Cookie', () async {
      // 这是旧项目实测「最可靠」的一级。实现里没有 jar 累积时，
      // 这一级会静默失效，表现为「扫了码却还要重扫」。
      final login = BiliQrLogin(
        dio: _FakeAdapter().asDio({
          '/qrcode/generate': _Resp(
            jsonEncode({
              'code': 0,
              'data': {'qrcode_key': 'k1', 'url': 'https://bili/qr'},
            }),
            setCookies: const ['SESSDATA=from-jar; Path=/', 'bili_jct=jjar; Path=/'],
          ),
          '/qrcode/poll': _Resp(jsonEncode({
            'code': 0,
            'data': {'code': 0, 'url': ''},
          })),
        }),
      );
      await login.generate();
      final r = await login.poll('k1');
      expect(r.status, BiliQrStatus.success);
      expect(r.cookieHeader, contains('SESSDATA=from-jar'));
      expect(r.cookieHeader, contains('bili_jct=jjar'));
    });

    test('成功但拿不到凭证 → 明确判失败（不能静默当作成功）', () async {
      final login = BiliQrLogin(dio: _dioReturning(jsonEncode({
        'code': 0,
        'data': {'code': 0, 'url': ''},
      })));
      final r = await login.poll('k');
      expect(r.status, BiliQrStatus.failed);
      expect(r.error, contains('凭证'));
    });

    test('风控 -412 → 失败且标记 riskControl（上层据此不重试）', () async {
      final login = BiliQrLogin(dio: _dioReturning(jsonEncode({
        'code': -412,
        'message': '请求被拦截',
      })));
      final r = await login.poll('k');
      expect(r.status, BiliQrStatus.failed);
      expect(r.riskControl, isTrue);
    });

    test('风控出现在内层也一样识别', () async {
      final login = BiliQrLogin(dio: _dioReturning(jsonEncode({
        'code': 0,
        'data': {'code': -352, 'message': '风控'},
      })));
      final r = await login.poll('k');
      expect(r.riskControl, isTrue);
    });
  });

  testWidgets('登录页可渲染（autoStart=false，不发真网络请求）',
      (tester) async {
    final st = AppState();
    await tester.pumpWidget(
      MaterialApp(home: BiliLoginPage(st: st, autoStart: false)),
    );
    await tester.pumpAndSettle();

    expect(find.text('用 B站手机 App 扫码登录'), findsOneWidget);
    // 收益说明要摊开讲清楚：用户得知道登录后换来什么
    expect(find.text('登录后有什么变化'), findsOneWidget);
    expect(find.text('可拿 192K / Hi-Res 音质（匿名态最高 132K）'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    st.dispose();
  });

  group('BiliQrPoll', () {
    test('done 只在成功与失败时为 true（轮询循环据此退出）', () {
      expect(BiliQrPoll.pending.done, isFalse);
      expect(BiliQrPoll.scanned.done, isFalse);
      expect(BiliQrPoll.expired.done, isFalse); // 失效是终态但需重新生成
      expect(BiliQrPoll.success('SESSDATA=1').done, isTrue);
      expect(BiliQrPoll.failed('boom').done, isTrue);
    });

    test('成功态带着完整 Cookie 串', () {
      final r = BiliQrPoll.success('SESSDATA=a; bili_jct=b');
      expect(r.status, BiliQrStatus.success);
      expect(r.cookieHeader, 'SESSDATA=a; bili_jct=b');
    });
  });
}

/// 所有请求都返回同一个响应体（用于验证状态码与解析分支）
Dio _dioReturning(String body) => _FakeAdapter().asDio(
      {'/qrcode/poll': _Resp(body)},
    );

/// 一次响应：响应体 + 可选 Set-Cookie 头
class _Resp {
  const _Resp(this.body, {this.setCookies = const []});

  final String body;
  final List<String> setCookies;
}

/// 按 path 后缀路由的假适配器：支持下发 Set-Cookie，
/// 这样才能覆盖「凭证来自 generate/poll 链路累积」这条路径。
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, _Resp> _routes = {};

  Dio asDio(Map<String, _Resp> routes) {
    _routes.addAll(routes);
    return Dio()..httpClientAdapter = this;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _Resp? resp;
    for (final e in _routes.entries) {
      if (options.path.endsWith(e.key)) {
        resp = e.value;
        break;
      }
    }
    resp ??= const _Resp('{}');
    return ResponseBody.fromString(
      resp.body,
      200,
      headers: {
        if (resp.setCookies.isNotEmpty) 'set-cookie': resp.setCookies,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
