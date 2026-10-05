/// B站登录会话状态：Cookie / 昵称头像 / nav 校验结果 + 落盘。
///
/// ## 为什么从 AppState 拆出来（P3 组合式拆分，**不是** part 文件）
/// 这是一组自洽的叶子状态：只依赖 SettingsStore（落盘）与 BiliCookieSession
/// （网络）两个外部对象和一个 onChange 回调，不碰播放 / 曲库 / 队列任何东西。
/// AppState 保留同名转发（biliLoggedIn / verifyBiliSession / …），
/// UI 与测试的用法完全不变；本类可独立阅读与测试。
library;

import '../services/bilibili/bili_cookie_session.dart';
import '../services/settings/settings_store.dart';

class BiliSessionBox {
  BiliSessionBox({
    required BiliCookieSession? session,
    required SettingsStore? settings,
    required void Function() onChange,
  })  : _session = session,
        _settings = settings,
        _onChange = onChange {
    // 恢复上次登录态：Cookie 只存在于内存与 SharedPreferences，
    // 会话对象每次冷启动都是新的，必须在这里重新注入一次。
    cookie = settings?.biliCookieHeader ?? '';
    cookieAt = settings?.biliCookieAtMs ?? 0;
    userName = settings?.biliUserName ?? '';
    userFace = settings?.biliUserFace ?? '';
    if (cookie.isNotEmpty) {
      session?.setUserSession(cookieHeader: cookie);
    }
  }

  final BiliCookieSession? _session;
  final SettingsStore? _settings;
  final void Function() _onChange;

  /// 供扫码登录页复用同一个会话（登录成功后立刻生效）
  BiliCookieSession? get session => _session;

  /// Cookie 串的内存镜像（含 SESSDATA）。**永不写进日志。**
  String cookie = '';
  int cookieAt = 0;
  String userName = '';

  /// 头像 URL（nav `face` 字段）。「我的」页资料卡展示用，与昵称同生命周期
  String userFace = '';

  /// 后台 nav 校验的结果（null = 还没校验过 / 网络不可达未下结论）
  bool? valid;

  bool get loggedIn => cookie.isNotEmpty;

  /// true = 服务端明确说这个凭证已经不认了。
  ///
  /// 只对「服务端明确否定」置真：网络不可达时保持「未校验」，
  /// 否则一趟电梯下来就被判成「登录失效」，用户会白白重扫一次。
  bool get stale => valid == false;

  /// 剩余天数；未登录返回 null
  int? get daysLeft {
    if (cookieAt <= 0) return null;
    final exp = DateTime.fromMillisecondsSinceEpoch(cookieAt)
        .add(SettingsStore.biliCookieTtl);
    final d = exp.difference(DateTime.now()).inDays;
    return d < 0 ? 0 : d;
  }

  /// 已过提示有效期 → 界面催「重新扫码」（不强制登出：服务端可能仍认）
  bool get expired {
    final left = daysLeft;
    return left != null && left <= 0;
  }

  /// 距到期不足 7 天
  bool get expiringSoon {
    final left = daysLeft;
    return left != null && left > 0 && left <= 7;
  }

  /// 后台校验本地凭证是否还被服务端认账。
  ///
  /// 「本地存着 SESSDATA」不等于「服务端还认它」——被吊销、换设备、
  /// 网页端退出登录都会让它悄悄失效。不校验的表现是：界面显示「已登录」，
  /// 播放却一直拿 132K，用户根本不知道要重扫。
  ///
  /// 只对**服务端明确回答**下结论：nav 拿不到（断网/超时）时保留现状。
  /// 只对「服务端明确否定」判失效；网络不可达保持「未校验」，
  /// 否则一趟电梯下来就被判成「登录失效」，用户会白白重扫一次。
  Future<void> verify() async {
    if (cookie.isEmpty) return;
    final nav = await _session?.probeNav();
    if (nav == null) return;

    valid = nav['isLogin'] == true;
    final name = nav['uname']?.toString() ?? '';
    if (name.isNotEmpty) userName = name;
    final face = _httpsFace(nav['face']?.toString() ?? '');
    if (face.isNotEmpty) userFace = face;
    _onChange();
  }

  /// B站部分接口仍回 http 头像域名，Android 默认禁明文流量，统一升级 https
  static String _httpsFace(String url) =>
      url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

  /// 保存登录态：注入会话 + 落盘。
  ///
  /// 成功后顺手用 nav 接口取一次昵称，界面才能显示「已登录为 XXX」——
  /// nav 本身就带 wbi key，顺带也把签名密钥刷新了。
  /// 启动后校验一次本地凭证是否还有效。
  Future<void> apply(String cookieHeader) async {
    cookie = cookieHeader;
    cookieAt = DateTime.now().millisecondsSinceEpoch;
    userName = '';
    userFace = '';
    valid = null;
    _session?.setUserSession(cookieHeader: cookieHeader);
    _onChange();
    await _settings?.setBiliSession(cookieHeader);

    try {
      final nav = await _session?.probeNav();
      final name = nav?['uname']?.toString() ?? '';
      final face = _httpsFace(nav?['face']?.toString() ?? '');
      valid = nav == null ? null : nav['isLogin'] == true;
      if (name.isNotEmpty) userName = name;
      if (face.isNotEmpty) userFace = face;
      if (name.isNotEmpty || face.isNotEmpty || valid == false) {
        _onChange();
      }
      if (name.isNotEmpty || face.isNotEmpty) {
        await _settings?.setBiliSession(
          cookieHeader,
          userName: name,
          userFace: face,
        );
      }
    } catch (_) {
      // 拿不到昵称/头像不影响登录态本身
    }
  }

  Future<void> logout() async {
    cookie = '';
    cookieAt = 0;
    userName = '';
    userFace = '';
    valid = null;
    // 无参调用 = 清空登录态并作废缓存的匿名指纹，下次请求会重新取
    _session?.setUserSession();
    _onChange();
    await _settings?.clearBiliSession();
  }
}
