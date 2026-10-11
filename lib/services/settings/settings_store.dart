/// 本机偏好设置（持久化）。
///
/// ## 为什么单独一个 store，而不是塞进 AppDatabase
/// 这些是「本机使用偏好」——换台设备就没了也无所谓；而 `audora.db` 装的是
/// 曲库与音源绑定，是用户真正的资产（要备份、要清理、要迁移）。
/// 混在一起的后果是：清一次偏好会连带把曲库清掉。
///
/// ## 为什么不用 abstract 包一层再给假实现
/// `SharedPreferences` 自带 `setMockInitialValues`，测试里一行就能换成
/// 内存实现，再抽象一层接口只是增加间接性、没有实际收益。
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart' show ThemeMode;

/// 音质档位：UI 选项与实际 B站音质 ID 的映射。
///
/// ## 为什么只有三档
/// 2026-10-11 用户把音质偏好拆成「在线音质 / 下载音质」，两边都只留
/// 标准 132K / 高品质 192K / 自动。原来的「省流 64Kbps」下线——B站
/// 64K 档实际是带强噪声的降级流，省下的体积不够补偿听感损失。
///
/// [id] 为 0 表示「不设上限」（始终取最高可用音质）。
enum QualityPreference {
  /// 不限制，永远挑最高的（Hi-Res 有则用）
  auto(0, '自动（最高音质）', '有 Hi-Res / 无损就用，流量与文件体积代价最大'),

  /// 上限 192Kbps —— B站绝大多数音频的实际最高档
  high(30280, '高品质 192Kbps', 'B站音频常见最高档，音质与体积平衡'),

  /// 上限 132Kbps
  medium(30232, '标准 132Kbps', '体积明显更小，适合移动网络');

  /// B站音质 ID；0 = 不限制
  final int id;
  final String label;
  final String desc;

  const QualityPreference(this.id, this.label, this.desc);

  /// 设置行右侧那一小串字用的紧凑写法（[label] 放不下两条）。
  ///
  /// 只用于展示；任何比较、落库都走 [id]。
  String get chip => switch (this) {
        QualityPreference.auto => '自动',
        QualityPreference.high => '192K',
        QualityPreference.medium => '132K',
      };

  /// 已下线的「省流 64Kbps」档位 ID。
  static const _legacyLowId = 30216;

  /// 按 id 反查（读持久化值用）。
  ///
  /// 老版本存过 64K 的映射到 [medium]（就近降一档），而不是落到 [auto]——
  /// 否则「档位下线」会变成一次**静默升档**，用户改天突然发现流量涨了一截。
  /// 其余无法识别的值返回 [auto]：配置损坏不该让应用起不来。
  static QualityPreference fromId(int id) {
    if (id == _legacyLowId) return QualityPreference.medium;
    return QualityPreference.values
        .firstWhere((e) => e.id == id, orElse: () => QualityPreference.auto);
  }
}

/// 设置面板的档位展示顺序：标准 → 高品质 → 自动。
///
/// 与 [QualityPreference.values] 的声明顺序不同（那边按「上限从高到低」排，
/// 供音质比较逻辑用），这里单独列出，避免为了 UI 顺序去动枚举语义。
const List<QualityPreference> kQualityChoices = [
  QualityPreference.medium,
  QualityPreference.high,
  QualityPreference.auto,
];

class SettingsStore {
  SettingsStore._(this._prefs);

  final SharedPreferences _prefs;

  // 音质偏好拆成两个独立键（2026-10-11）：在线拉流一个上限、落盘下载一个
  // 上限。_kOnlineQuality 沿用老键名 quality_ceiling，老装机用户的设置不丢。
  static const _kOnlineQuality = 'quality_ceiling';
  static const _kDownloadQuality = 'download_quality_ceiling';
  static const _kAutoMatch = 'auto_match_on_import';
  static const _kDiagVerbose = 'diag_verbose';

  // ── 歌曲目录（SAF tree uri）──────────────────────────────
  static const _kLocalDirUri = 'local_dir_uri';
  static const _kDownloadDirUri = 'download_dir_uri';

  // ── 音效偏好（EQ 预设 / 自定义曲线 / 全局响度）────────────
  // 仍是「本机偏好」：EQ band 数随设备不同，自定义曲线换了设备语义
  // 会偏（但不错位），不该进 audora.db 混进用户曲库资产。
  static const _kFxPreset = 'fx_preset';
  static const _kFxCustomGains = 'fx_custom_gains';
  static const _kFxLoudness = 'fx_loudness';

  // ── 会话恢复（上次退出时的界面与播放进度）────────────────
  static const _kThemeMode = 'theme_mode';
  static const _kTabIndex = 'last_tab_index';
  static const _kPlayerOpen = 'last_player_open';
  static const _kSessionSongKey = 'session_song_key';
  static const _kSessionPosition = 'session_position_sec';

  /// ⚠️ 以下是 B站登录态（C1 方案）。SESSDATA 属于**账号凭据**：
  /// 只落本机 shared_preferences、只进内存，**绝不写进诊断日志或导出文件**。
  /// 顺带存一下昵称，只为界面上显示「已登录为 XXX」，不存 uid 之外的任何信息。
  static const _kBiliCookie = 'bili_cookie_header';
  static const _kBiliCookieAt = 'bili_cookie_at';
  static const _kBiliUserName = 'bili_user_name';
  static const _kBiliUserFace = 'bili_user_face';

  /// B站登录态的**提示**有效期。
  ///
  /// 真实 SESSDATA 的有效期由服务端决定（大致是 1 个月量级，且可被服务端
  /// 随时吊销），客户端无从查询。这里按 30 天做**保守提示**：
  /// 到期不强制登出（万一还能用），但界面上明确催一次重新扫码。
  static const biliCookieTtl = Duration(days: 30);

  /// 进入「即将到期」提示的提前量
  static const biliCookieWarnBefore = Duration(days: 7);

  /// 打开设置（读取磁盘）。应用启动时调一次。
  static Future<SettingsStore> open() async =>
      SettingsStore._(await SharedPreferences.getInstance());

  /// 直接用已有的 SharedPreferences 实例构造。
  ///
  /// 给测试用：先 `SharedPreferences.setMockInitialValues({...})` 声明初值，
  /// 再 `await SharedPreferences.getInstance()` 拿内存实例传进来。
  /// 之所以要外部传实例，是因为 `setMockInitialValues` 是
  /// `@visibleForTesting` 成员，生产代码里调会报警告。
  SettingsStore.fromPrefs(this._prefs);

  /// 在线播放的音质上限（拉流时按它挑档）。
  QualityPreference get onlineQuality =>
      QualityPreference.fromId(_prefs.getInt(_kOnlineQuality) ?? 0);

  Future<void> setOnlineQuality(QualityPreference q) =>
      _prefs.setInt(_kOnlineQuality, q.id);

  /// 下载落盘的音质上限。默认 [QualityPreference.high]：
  /// 下载是要留下来的文件，132K 太小、自动又可能一次拉进几十 MB 的
  /// Hi-Res，192K 是 B站音频的常见最高档，体积与听感都划得来。
  QualityPreference get downloadQuality => QualityPreference.fromId(
      _prefs.getInt(_kDownloadQuality) ?? QualityPreference.high.id);

  Future<void> setDownloadQuality(QualityPreference q) =>
      _prefs.setInt(_kDownloadQuality, q.id);

  // ── 歌曲目录（SAF tree uri）──────────────────────────────
  //
  // 存的是 `content://…/tree/…` 字符串，不是文件路径：tree uri 才是授权体系
  // 认的东西，posix 路径只是它的一个可读别名（且只有机身存储/SD 卡提供方有）。
  // 「这个 uri 现在还能不能用」不在这里判断，由 MusicDirsBox 启动时问原生。

  /// 本地扫描范围。空串 = 不设限，扫手机全部音频。
  String get localDirUri => _prefs.getString(_kLocalDirUri) ?? '';

  Future<void> setLocalDirUri(String uri) =>
      uri.isEmpty ? _prefs.remove(_kLocalDirUri) : _prefs.setString(_kLocalDirUri, uri);

  /// 下载目录。空串 = 未设置（此时下载功能会拒绝并提示先选目录）。
  String get downloadDirUri => _prefs.getString(_kDownloadDirUri) ?? '';

  Future<void> setDownloadDirUri(String uri) =>
      uri.isEmpty
          ? _prefs.remove(_kDownloadDirUri)
          : _prefs.setString(_kDownloadDirUri, uri);

  /// 导入后是否自动批量匹配音源。
  ///
  /// 默认 **false**：匹配要打 B站接口（限流 30 次/分钟），
  /// 导入 50 首会自动触发 50 次请求，用户没预期的等待和流量。
  /// 让他显式去「我的 → 批量匹配」更稳妥。
  bool get autoMatchOnImport => _prefs.getBool(_kAutoMatch) ?? false;

  Future<void> setAutoMatchOnImport(bool v) => _prefs.setBool(_kAutoMatch, v);

  // ── 诊断日志 ────────────────────────────────────────────

  /// 详细级开关（用户 2026-09-29 决策）。
  ///
  /// **摘要级没有开关、永远开着**——它只记匹配过程与崩溃，量小且是排查刚需。
  /// 这里控制的是「要不要连每条成功网络请求也记下来」，默认关。
  bool get diagVerbose => _prefs.getBool(_kDiagVerbose) ?? false;

  Future<void> setDiagVerbose(bool v) => _prefs.setBool(_kDiagVerbose, v);

  // ── 音效偏好 ─────────────────────────────────────────────

  /// EQ 预设 id（[FxPreset] 的常量之一）。损坏值由 FxPreset.byId 回落平直。
  String get fxPreset => _prefs.getString(_kFxPreset) ?? '';

  Future<void> setFxPreset(String id) => _prefs.setString(_kFxPreset, id);

  /// 自定义 EQ 曲线（JSON 字符串，FxCurves.encode/decode 承担编解码）。
  String get fxCustomGains => _prefs.getString(_kFxCustomGains) ?? '';

  Future<void> setFxCustomGains(String json) =>
      _prefs.setString(_kFxCustomGains, json);

  /// 全局响度微调（dB）。
  double get fxLoudness => _prefs.getDouble(_kFxLoudness) ?? 0;

  Future<void> setFxLoudness(double db) => _prefs.setDouble(_kFxLoudness, db);

  // ── 会话恢复 ──────────────────────────────────────────────
  //
  // 这些值随操作频繁写入（切 tab / 暂停 / 拖进度 / 每 15 秒打点），
  // 全走 shared_preferences：写是内存级操作，磁盘异步刷，开销可忽略。
  // 恢复语义见 AppState.restoreSession —— 这里只管存取。

  /// 主题模式。未存过时为 null（上层用默认浅色）。
  ThemeMode? get themeMode {
    switch (_prefs.getString(_kThemeMode)) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return null;
    }
  }

  Future<void> setThemeMode(ThemeMode m) =>
      _prefs.setString(_kThemeMode, m == ThemeMode.dark ? 'dark' : 'light');

  /// 上次停留的底部 tab（0=音乐 1=我的）
  int get lastTabIndex => _prefs.getInt(_kTabIndex) ?? 0;

  Future<void> setTabIndex(int i) => _prefs.setInt(_kTabIndex, i);

  /// 上次退出时播放页是否展开
  bool get lastPlayerOpen => _prefs.getBool(_kPlayerOpen) ?? false;

  Future<void> setPlayerOpen(bool v) => _prefs.setBool(_kPlayerOpen, v);

  /// 上次在播的歌（`title|artist`）。空串 = 没有可恢复的会话。
  String get sessionSongKey => _prefs.getString(_kSessionSongKey) ?? '';

  /// 上次的播放进度（秒）。
  int get sessionPositionSec => _prefs.getInt(_kSessionPosition) ?? 0;

  /// 保存播放会话快照（当前歌 + 进度）。
  ///
  /// [songKey] 传空串表示清空（没有在播的歌时也要把旧快照擦掉，
  /// 否则下次启动会恢复出一首早已不存在的歌）。
  Future<void> saveSession({
    required String songKey,
    required int positionSec,
  }) async {
    if (songKey.isEmpty) {
      await _prefs.remove(_kSessionSongKey);
      await _prefs.remove(_kSessionPosition);
      return;
    }
    await _prefs.setString(_kSessionSongKey, songKey);
    await _prefs.setInt(_kSessionPosition, positionSec);
  }

  // ── B站登录态（C1）──────────────────────────────────────

  /// 已保存的完整 Cookie 串（含 SESSDATA）；未登录时为空串。
  String get biliCookieHeader => _prefs.getString(_kBiliCookie) ?? '';

  /// 登录时刻（ms）。0 表示没登录过。
  int get biliCookieAtMs => _prefs.getInt(_kBiliCookieAt) ?? 0;

  String get biliUserName => _prefs.getString(_kBiliUserName) ?? '';

  /// 头像 URL（nav 接口 `face` 字段）。只为「我的」页展示，与昵称同生命周期。
  String get biliUserFace => _prefs.getString(_kBiliUserFace) ?? '';

  bool get biliLoggedIn => biliCookieHeader.isNotEmpty;

  /// 按 [biliCookieTtl] 推算的到期时刻（未登录时返回 null）
  DateTime? get biliCookieExpiresAt {
    final at = biliCookieAtMs;
    if (at <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(at).add(biliCookieTtl);
  }

  /// 剩余天数（未登录时返回 null）
  int? get biliCookieDaysLeft {
    final exp = biliCookieExpiresAt;
    if (exp == null) return null;
    final d = exp.difference(DateTime.now()).inDays;
    return d < 0 ? 0 : d;
  }

  /// 已过提示有效期 → 界面催「重新扫码」
  bool get biliCookieExpired {
    final exp = biliCookieExpiresAt;
    return exp != null && DateTime.now().isAfter(exp);
  }

  /// 距到期不足 [biliCookieWarnBefore] → 界面提示「快到期了」
  bool get biliCookieExpiringSoon {
    final exp = biliCookieExpiresAt;
    if (exp == null) return false;
    return !biliCookieExpired &&
        DateTime.now().isAfter(exp.subtract(biliCookieWarnBefore));
  }

  /// 保存登录态。[cookieHeader] 必须是完整 Cookie 串（含 SESSDATA）。
  Future<void> setBiliSession(
    String cookieHeader, {
    String userName = '',
    String userFace = '',
  }) async {
    await _prefs.setString(_kBiliCookie, cookieHeader);
    await _prefs.setInt(_kBiliCookieAt, DateTime.now().millisecondsSinceEpoch);
    await _prefs.setString(_kBiliUserName, userName);
    await _prefs.setString(_kBiliUserFace, userFace);
  }

  Future<void> clearBiliSession() async {
    await _prefs.remove(_kBiliCookie);
    await _prefs.remove(_kBiliCookieAt);
    await _prefs.remove(_kBiliUserName);
    await _prefs.remove(_kBiliUserFace);
  }
}
