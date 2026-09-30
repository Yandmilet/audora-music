/// B站扫码登录页（C1 方案）。
///
/// ## 为什么是扫码而不是「填 Cookie」
/// 让用户从浏览器开发者工具里抠 SESSDATA 粘进来，是能跑但很糟的方案：
/// 步骤多、易粘错、过期后用户根本想不起来当初是怎么配的。
/// 扫码是 B站 官方 Web 登录的标准流程，失效了再扫一次即可——
/// 所以页面把「重新扫码」做成一等入口，而不是让用户翻设置。
///
/// ## 有效期为什么是 30 天
/// SESSDATA 的真实有效期由服务端决定（量级是一个月，且可被随时吊销），
/// 客户端无从查询。这里按 30 天做**保守提示**：到期不强制登出
/// （万一服务端还认），但明确催一次重新扫码，避免用户以为一直有效。
///
/// ## 隐私
/// Cookie 只写本机 SharedPreferences，只存在于内存中，
/// **不进诊断日志、不进导出文件、不上传任何地方**。页面上也明示这一点。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/bilibili/bili_login.dart';
import '../state/app_state.dart';
import '../theme.dart';

class BiliLoginPage extends StatefulWidget {
  final AppState st;

  /// false 时不自动申请二维码（供 UI 测试渲染用——测试环境不该发真网络请求）
  final bool autoStart;

  const BiliLoginPage({super.key, required this.st, this.autoStart = true});

  @override
  State<BiliLoginPage> createState() => _BiliLoginPageState();
}

class _BiliLoginPageState extends State<BiliLoginPage> {
  BiliQrLogin? _login;
  BiliQrTicket? _ticket;
  BiliQrStatus _status = BiliQrStatus.pending;
  String? _error;
  bool _starting = false;

  /// 二维码剩余有效秒数（本地倒计时，比等服务端 86038 更及时）
  int _remainSeconds = 0;
  Timer? _countdown;

  /// 会话代号：每次「重新生成 / 关闭页面」都自增。
  ///
  /// 轮询是 `await` 驱动的循环，取消 Future 是不可能的，只能靠代号让旧循环
  /// 在下一个检查点自己退出——这是刷新二维码后旧请求还在发、或者
  /// 关闭页面后仍在轮询的根因。
  int _pollEpoch = 0;

  /// 同一会话内允许的连续失败次数。网络抖动要能扛，但无限重试不可接受。
  static const _maxConsecutiveFailures = 5;

  @override
  void initState() {
    super.initState();
    // 已登录且状态正常时不自动起二维码：用户多半只是来看一眼状态。
    // 反之（未登录 / 超过提示有效期 / 服务端已不认这个凭证）直接起码，
    // 别让用户先读一段说明再自己找按钮。
    if (widget.autoStart &&
        (!widget.st.biliLoggedIn ||
            widget.st.biliCookieExpired ||
            widget.st.biliSessionStale)) {
      _start();
    }
  }

  @override
  void dispose() {
    _pollEpoch++; // 让可能在 await 中的轮询循环退出
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final epoch = ++_pollEpoch;
    _countdown?.cancel();
    setState(() {
      _starting = true;
      _error = null;
      _ticket = null;
      _status = BiliQrStatus.pending;
      _remainSeconds = 0;
    });
    try {
      final login = BiliQrLogin(session: widget.st.biliSession);
      _login = login;
      final ticket = await login.generate();
      if (!mounted || epoch != _pollEpoch) return;
      setState(() {
        _ticket = ticket;
        _starting = false;
        _remainSeconds = BiliQrLogin.validSeconds;
      });
      _startCountdown();
      unawaited(_pollLoop(epoch));
    } catch (e) {
      if (!mounted || epoch != _pollEpoch) return;
      setState(() {
        _starting = false;
        _status = BiliQrStatus.failed;
        _error = '二维码获取失败：$e';
      });
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_status != BiliQrStatus.pending && _status != BiliQrStatus.scanned) {
        _countdown?.cancel();
        return;
      }
      if (_remainSeconds <= 0) return;
      setState(() => _remainSeconds--);
      if (_remainSeconds == 0) {
        // 本地判废：服务端可能还要过几秒才给 86038，
        // 让用户对着一个扫不出结果的码干等更糟
        _countdown?.cancel();
        _pollEpoch++;
        setState(() {
          _status = BiliQrStatus.expired;
          _ticket = null;
        });
      }
    });
  }

  /// 自驱动轮询循环。
  ///
  /// **不能用 `Timer.periodic` 发异步请求**：periodic 不等 `await`，
  /// 单次轮询一旦超过间隔（弱网下很容易），请求就会叠加，
  /// 几轮下来直接把配额打满、招来 -412。这里每轮结束后才排下一轮。
  Future<void> _pollLoop(int epoch) async {
    var failures = 0;
    while (mounted && epoch == _pollEpoch) {
      await Future<void>.delayed(BiliQrLogin.pollInterval);
      if (!mounted || epoch != _pollEpoch) return;

      final login = _login;
      final ticket = _ticket;
      if (login == null || ticket == null) return;

      final r = await login.poll(ticket.key);
      if (!mounted || epoch != _pollEpoch) return;

      if (r.status == BiliQrStatus.success) {
        _countdown?.cancel();
        await widget.st.applyBiliSession(r.cookieHeader ?? '');
        if (!mounted) return;
        setState(() {
          _status = BiliQrStatus.success;
          _ticket = null;
        });
        return;
      }
      if (r.status == BiliQrStatus.expired) {
        _countdown?.cancel();
        setState(() {
          _status = BiliQrStatus.expired;
          _ticket = null;
        });
        return;
      }
      if (r.status == BiliQrStatus.scanned) {
        failures = 0;
        if (_status != BiliQrStatus.scanned) {
          setState(() => _status = BiliQrStatus.scanned);
        }
        continue;
      }
      if (r.status == BiliQrStatus.pending) {
        failures = 0;
        continue;
      }
      // failed：风控没有重试价值，越试封得越久
      if (r.riskControl) {
        _countdown?.cancel();
        setState(() {
          _status = BiliQrStatus.failed;
          _error = r.error;
        });
        return;
      }
      failures++;
      if (failures >= _maxConsecutiveFailures) {
        _countdown?.cancel();
        setState(() {
          _status = BiliQrStatus.failed;
          _error = r.error ?? '登录失败，请重试';
        });
        return;
      }
    }
  }

  Future<void> _logout() async {
    _pollEpoch++;
    _countdown?.cancel();
    await widget.st.biliLogout();
    if (!mounted) return;
    setState(() {
      _ticket = null;
      _status = BiliQrStatus.pending;
      _remainSeconds = 0;
    });
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final st = widget.st;

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: const Text('B站账号',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          if (st.biliLoggedIn) _AccountCard(st: st, onRelogin: _start),
          const SizedBox(height: 16),
          _QrCard(
            starting: _starting,
            ticket: _ticket,
            status: _status,
            error: _error,
            remainSeconds: _remainSeconds,
            onRefresh: _start,
          ),
          const SizedBox(height: 16),
          const _WhyCard(),
          if (st.biliLoggedIn) ...[
            const SizedBox(height: 16),
            _LogoutRow(onLogout: _logout),
          ],
        ],
      ),
    );
  }
}

/// 已登录状态卡：谁、还剩多久、到期了要不要重扫
class _AccountCard extends StatelessWidget {
  final AppState st;
  final VoidCallback onRelogin;

  const _AccountCard({required this.st, required this.onRelogin});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final expired = st.biliCookieExpired;
    final soon = st.biliCookieExpiringSoon;
    final days = st.biliCookieDaysLeft ?? 0;

    final String line;
    final Color ink;
    if (st.biliSessionStale) {
      line = '服务端已不认这个凭证，请重新扫码';
      ink = Tokens.brand;
    } else if (expired) {
      line = '登录态已超过 30 天，建议重新扫码';
      ink = Tokens.brand;
    } else if (soon) {
      line = '还剩 $days 天到期，可随时重新扫码续期';
      ink = const Color(0xFFB4680C);
    } else {
      line = '有效期还有 $days 天（到期会自动提醒）';
      ink = const Color(0xFF11875A);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? Tokens.surfaceDark : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.rLg),
        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 18, color: Color(0xFF11875A)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  st.biliUserName.isEmpty
                      ? '已登录 B站账号'
                      : '已登录：${st.biliUserName}',
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(line, style: TextStyle(fontSize: 12, color: ink)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onRelogin,
              icon: const Icon(Icons.qr_code_2_rounded, size: 18),
              label: Text(expired ? '重新扫码登录' : '重新扫码（续期）',
                  style: const TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Cookie 只保存在本机，不会写入诊断日志，也不会上传。',
            style: TextStyle(
                fontSize: 10.5, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 二维码卡：按轮询状态切换内容
class _QrCard extends StatelessWidget {
  final bool starting;
  final BiliQrTicket? ticket;
  final BiliQrStatus status;
  final String? error;
  final int remainSeconds;
  final VoidCallback onRefresh;

  const _QrCard({
    required this.starting,
    required this.ticket,
    required this.status,
    required this.error,
    required this.remainSeconds,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? Tokens.surfaceDark : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.rLg),
        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
      ),
      child: Column(
        children: [
          const Text('用 B站手机 App 扫码登录',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          SizedBox(
            height: 208,
            child: AnimatedSwitcher(
              duration: Tokens.dur,
              child: _qrBody(context, dark),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: status == BiliQrStatus.failed
                  ? Tokens.brand
                  : t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Color get _qrInk =>
      status == BiliQrStatus.scanned ? Colors.grey.shade400 : Colors.black;

  Widget _qrBody(BuildContext context, bool dark) {
    if (starting) {
      return const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (status == BiliQrStatus.success) {
      return const Center(
        key: ValueKey('ok'),
        child: Icon(Icons.check_circle_rounded,
            size: 56, color: Color(0xFF11875A)),
      );
    }
    final url = ticket?.url;
    if (url != null &&
        (status == BiliQrStatus.pending || status == BiliQrStatus.scanned)) {
      return Center(
        key: const ValueKey('qr'),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(Tokens.rMd),
          ),
          child: QrImageView(
            data: url,
            version: QrVersions.auto,
            size: 180,
            backgroundColor: Colors.white,
            // 已扫码未确认时把二维码压暗，提示"去手机上点确认"
            eyeStyle: QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: _qrInk,
            ),
            dataModuleStyle: QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: _qrInk,
            ),
          ),
        ),
      );
    }
    // 失效 / 失败：给一个明确的重来入口
    return Center(
      key: const ValueKey('retry'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            status == BiliQrStatus.expired
                ? Icons.hourglass_disabled_rounded
                : Icons.error_outline_rounded,
            size: 44,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新二维码', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  String get _hint => switch (status) {
        // 给真实倒计时而不是「约 3 分钟」：用户据此判断要不要现在去拿手机
        BiliQrStatus.pending => ticket == null
            ? '正在获取二维码…'
            : '二维码还剩 $remainSeconds 秒失效',
        BiliQrStatus.scanned => '已扫码，请在手机上点「确认登录」',
        BiliQrStatus.expired => '二维码已失效，点上方刷新再来一次',
        BiliQrStatus.success => '登录成功，已生效（无需重启应用）',
        BiliQrStatus.failed => error ?? '登录失败，请重试',
      };
}

/// 值不值得登录？把收益和代价都摊开说
class _WhyCard extends StatelessWidget {
  const _WhyCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.brightness == Brightness.dark
            ? Tokens.surface2Dark
            : Tokens.surface2,
        borderRadius: BorderRadius.circular(Tokens.rMd),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('登录后有什么变化',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          SizedBox(height: 8),
          _Bullet(text: '可拿 192K / Hi-Res 音质（匿名态最高 132K）'),
          _Bullet(text: '接口配额更宽，密集匹配时更少触发风控 -412'),
          _Bullet(text: '不登录也能正常听，只是以上两项受限'),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;

  const _Bullet({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(Icons.circle, size: 4, color: Colors.grey),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogoutRow extends StatelessWidget {
  final VoidCallback onLogout;

  const _LogoutRow({required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: onLogout,
        icon: const Icon(Icons.logout_rounded, size: 18),
        label: const Text('退出登录', style: TextStyle(fontSize: 13)),
        style: TextButton.styleFrom(foregroundColor: Tokens.brand),
      ),
    );
  }
}
