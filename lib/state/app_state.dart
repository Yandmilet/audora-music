/// 全局播放与界面状态。
///
/// ## 数据来源（2026-09-29 二次改造）
/// 曲库数据来自 [LibraryRepository]（SQLite 真实数据）。
///
/// ⚠️ **不再有 mock 兜底**。早期版本在「库为空」时会塞 30 首演示歌，
/// 结果是用户完全无法分辨「这首是真的还是假的」——搜索看起来很"能用"
/// 其实搜的是假数据，导入完也看不出区别。现在库为空就诚实地显示空状态，
/// 并引导用户去导入。代价是首次安装看到的是空页面，但这比假数据好。
///
/// [MockData] 现在只服务两处：
///   1. `_repo == null` 的单测 / 纯 UI 预览
///   2. `kRegions` 这类领域常量（已挪到 models.dart）
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../data/db/rows.dart';
import '../data/mock_data.dart';
import '../data/repository/library_repository.dart';
import '../models/models.dart';
import '../services/bilibili/bili_cookie_session.dart';
import '../services/bilibili/bili_dto.dart'
    show VideoCandidate, audioQualityLabel;
import '../services/diag/diag_log.dart';
import '../services/match/match_config.dart' show MatchConfidenceX;
import '../services/lyric/lrc_parser.dart';
import '../services/lyric/lyric_translation.dart';
import '../services/playback/audio_player_controller.dart';
import '../services/qqmusic/qqmusic_provider.dart';
import '../services/settings/settings_store.dart';
// PlayStatsDao 只用于引用 countingThresholdMs 常量（播放门限），
// 逻辑本身封装在 Repository 里，UI 层不直接碰 DAO。
import '../data/db/dao/play_stats_dao.dart' show PlayStatsDao;

/// 曲库加载状态
enum LibraryLoadState { idle, loading, ready, failed }

class AppState extends ChangeNotifier {
  /// [repo] 为 null 时说明数据层未接入（单测 / 纯 UI 预览），此时走 mock。
  /// [player] 为 null 时播放走"模拟进度"（同样用于单测），不产生真实声音。
  /// [settings] 为 null 时使用默认偏好，不读磁盘（单测友好）。
  AppState({
    LibraryRepository? repo,
    AudioPlayerController? player,
    SettingsStore? settings,

    /// B站 Cookie 会话。传入后「扫码登录」拿到的 SESSDATA 可以立刻注入，
    /// 后续所有 B站请求立即用上登录态，不必重启应用。
    BiliCookieSession? biliSession,
  })  : _repo = repo,
        _player = player,
        _settings = settings,
        _biliSession = biliSession {
    _quality = _settings?.quality ?? QualityPreference.auto;
    // 启动时把详细级偏好同步给日志内核（AppState 是设置的唯一出口）
    _diagVerbose = _settings?.diagVerbose ?? false;
    DiagLog.instance.setVerbose(_diagVerbose);

    // 恢复上次登录态：Cookie 只存在于内存与 SharedPreferences，
    // 会话对象每次冷启动都是新的，必须在这里重新注入一次。
    _biliCookie = _settings?.biliCookieHeader ?? '';
    _biliCookieAt = _settings?.biliCookieAtMs ?? 0;
    _biliUserName = _settings?.biliUserName ?? '';
    _biliUserFace = _settings?.biliUserFace ?? '';
    if (_biliCookie.isNotEmpty) {
      biliSession?.setUserSession(cookieHeader: _biliCookie);
    }
    // 主题模式持久化：不读盘的话每次冷启动都会「默认浅色」，
    // 用户上一程选的深色全丢（2026-09-30 真机反馈）。
    _themeMode = _settings?.themeMode ?? ThemeMode.light;
    // ⚠️ 只有「数据层未接入」时才装 mock。真实运行时（repo != null）
    // 一律等 loadLibrary() 的结果——空就是空，不造假数据。
    if (_repo == null) {
      _library = [...MockData.songs];
      _queue = [...MockData.songs];
      _index = 4;
      _seedMockLikes();
    } else {
      _library = const [];
      _queue = const [];
      _index = -1;
    }
    _syncDuration();
    _bindPlayer();
  }

  /// 给 mock 模式随机点几个红心，让收藏相关 UI 在预览时有内容。
  /// 真实模式下收藏来自数据库，不走这里。
  void _seedMockLikes() {
    for (var i = 0; i < MockData.songs.length; i++) {
      if (i % 5 == 0) _likedKeys.add(MockData.songs[i].key);
    }
  }

  /// 是否已被 dispose。用于 async 方法在 await 之后安全检查——
  /// ChangeNotifier 本身不提供 mounted，这里自己维护一个。
  bool _disposed = false;
  bool get mounted => !_disposed;

  /// 曲库仓库。为 null 时说明数据层未接入（单测 / 纯 UI 预览），
  /// 此时全部走 mock 数据。
  final LibraryRepository? _repo;

  /// 本机偏好（音质等）。为 null 时用默认值，不读磁盘——单测不必
  /// 为了「不崩」去搭一套 SharedPreferences 假数据。
  final SettingsStore? _settings;

  // ---- 偏好设置 ----
  QualityPreference _quality = QualityPreference.auto;

  /// 音质上限偏好。播放器拉流时按它挑音质。
  QualityPreference get quality => _quality;

  /// 音质上限偏好的 B站音质 ID（0 = 不限制）
  int get qualityCeilingId => _quality.id;

  /// 改音质偏好：落盘 + 让**当前在播的这首**立刻按新上限重拉。
  ///
  /// ## 为什么要主动重拉一次
  /// 只改 [qualityCeilingId] 的话，偏好要到「下一次拉流」才生效——
  /// 而缓存 URL 有效期 100 分钟，用户切回同一首歌听到的还是旧音质，
  /// 表现出来就是「改了设置没反应」。这里在正在播放时强制重解析一次：
  /// 播放位置保住，听感上是无缝换档。
  ///
  /// 暂停中不去动它：重解析会装载新源并起播，暂停态下突然出声比
  /// 「下一首才生效」更难受；起播（[togglePlay]）时自然会用新档位。
  ///
  /// ## 竞态守卫（与 [_playResolved] 同一语义，2026-09-30 补）
  /// 重拉要花数秒，期间用户完全可能切歌。原实现有三个漏洞：
  ///   1. 不置 `_resolving` → 转圈不出现，且旧源 stop/setAudioSource
  ///      期间的位置流事件绕过守卫污染进度条；
  ///   2. 忽略 `playSong` 的返回错误 → 装载失败也继续往下走；
  ///   3. 无条件 `seek(at)` → 切歌顶掉本次重拉后（[_playGen] 已变），
  ///      **新歌**会被 seek 回旧歌的进度。
  Future<void> setQuality(QualityPreference q) async {
    if (_quality == q) return;
    _quality = q;
    // 必须先 notify：main.dart 的监听器据此把新值写进 Resolver，
    // 本次重拉与后续所有拉流都依赖这一步。
    notifyListeners();
    await _settings?.setQuality(q);

    final p = _player;
    final song = current;
    if (p == null || song == null || song.source == null) return;
    if (!_playing || _resolving) return;

    final at = _position;
    // 记代次 + 置 resolving：挡位置流、给 UI 加载态。
    // 早退的每个分支都要么自己复位 resolving，要么已被更新的
    // _playResolved 任务接管（它自己会管理）。
    final gen = _playGen;
    _setResolving(true);
    try {
      // 60s 兜底与 _playResolved 一致：极端弱网下 playSong 可能长时间不返回。
      final err = await p.playSong(song, forceRefresh: true)
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      // 重拉期间被切歌顶掉：静默退出。新任务已接管 resolving / 进度 /
      // 音质显示，这里任何写操作都会污染新歌状态——尤其不能 seek(at)。
      if (gen != _playGen) return;
      _syncPlayingQuality();
      _setResolving(false);
      if (err != null) {
        // 装载失败：如实呈现。继续 seek 只会「进度条动了却无声」。
        _playbackError = err;
        _playing = false;
        notifyListeners();
        return;
      }
      // 进度锚点只在装载成功后生效；显式回写 _position 与 _playResolved
      // 的恢复路径同理——装载/seek 之间的位置流事件不能再把进度拉回 0。
      if (at > 0) {
        await p.seek(Duration(seconds: at));
        if (!mounted || gen != _playGen) return;
        _position = at;
      }
      notifyListeners();
    } on TimeoutException {
      if (!mounted || gen != _playGen) return;
      _setResolving(false);
      _playbackError = '音质切换超时，请检查网络后重试';
      _playing = false;
      notifyListeners();
    }
  }

  // ---- 诊断日志 ----

  /// 详细级开关。摘要级（匹配 + 崩溃）永远开着，没有总开关。
  bool _diagVerbose = false;

  bool get diagVerbose => _diagVerbose;

  /// 切详细级：立即同步给 [DiagLog]，并落盘。
  ///
  /// 摘要级常开，所以这里不涉及「关掉全部日志」——
  /// 那会让「为什么没匹配上」这类问题彻底无从查起。
  Future<void> setDiagVerbose(bool v) async {
    if (_diagVerbose == v) return;
    _diagVerbose = v;
    DiagLog.instance.setVerbose(v);
    notifyListeners();
    await _settings?.setDiagVerbose(v);
  }

  // ---- B站登录态（C1：扫码登录，解锁更高音质与更宽配额）----

  final BiliCookieSession? _biliSession;

  /// 供扫码登录页复用同一个会话（登录成功后立刻生效）
  BiliCookieSession? get biliSession => _biliSession;

  /// Cookie 串的内存镜像（含 SESSDATA）。**永不写进日志。**
  String _biliCookie = '';
  int _biliCookieAt = 0;
  String _biliUserName = '';

  /// 头像 URL（nav `face` 字段）。「我的」页资料卡展示用，与昵称同生命周期
  String _biliUserFace = '';

  /// 后台 nav 校验的结果（null = 还没校验过 / 网络不可达未下结论）
  bool? _biliSessionValid;

  /// true = 服务端明确说这个凭证已经不认了。
  ///
  /// 只对「服务端明确否定」置真：网络不可达时保持「未校验」，
  /// 否则一趟电梯下来就被判成「登录失效」，用户会白白重扫一次。
  bool get biliSessionStale => _biliSessionValid == false;

  bool get biliLoggedIn => _biliCookie.isNotEmpty;
  String get biliUserName => _biliUserName;
  String get biliUserFace => _biliUserFace;

  /// 剩余天数；未登录返回 null
  int? get biliCookieDaysLeft {
    if (_biliCookieAt <= 0) return null;
    final exp = DateTime.fromMillisecondsSinceEpoch(_biliCookieAt)
        .add(SettingsStore.biliCookieTtl);
    final d = exp.difference(DateTime.now()).inDays;
    return d < 0 ? 0 : d;
  }

  /// 已过提示有效期 → 界面催「重新扫码」（不强制登出：服务端可能仍认）
  bool get biliCookieExpired {
    final left = biliCookieDaysLeft;
    return left != null && left <= 0;
  }

  /// 距到期不足 7 天
  bool get biliCookieExpiringSoon {
    final left = biliCookieDaysLeft;
    return left != null && left > 0 && left <= 7;
  }

  /// 保存登录态：注入会话 + 落盘。
  ///
  /// 成功后顺手用 nav 接口取一次昵称，界面才能显示「已登录为 XXX」——
  /// nav 本身就带 wbi key，顺带也把签名密钥刷新了。
  /// 启动后校验一次本地凭证是否还有效。
  ///
  /// 「本地存着 SESSDATA」不等于「服务端还认它」——被吊销、换设备、
  /// 网页端退出登录都会让它悄悄失效。不校验的表现是：界面显示「已登录」，
  /// 播放却一直拿 132K，用户根本不知道要重扫。
  ///
  /// 只对**服务端明确回答**下结论：nav 拿不到（断网/超时）时保留现状。
  Future<void> verifyBiliSession() async {
    if (_biliCookie.isEmpty) return;
    final nav = await _biliSession?.probeNav();
    if (nav == null || !mounted) return;

    _biliSessionValid = nav['isLogin'] == true;
    final name = nav['uname']?.toString() ?? '';
    if (name.isNotEmpty) _biliUserName = name;
    final face = _httpsFace(nav['face']?.toString() ?? '');
    if (face.isNotEmpty) _biliUserFace = face;
    notifyListeners();
  }

  /// B站部分接口仍回 http 头像域名，Android 默认禁明文流量，统一升级 https
  static String _httpsFace(String url) =>
      url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

  Future<void> applyBiliSession(String cookieHeader) async {
    _biliCookie = cookieHeader;
    _biliCookieAt = DateTime.now().millisecondsSinceEpoch;
    _biliUserName = '';
    _biliUserFace = '';
    _biliSessionValid = null;
    _biliSession?.setUserSession(cookieHeader: cookieHeader);
    notifyListeners();
    await _settings?.setBiliSession(cookieHeader);

    try {
      final nav = await _biliSession?.probeNav();
      final name = nav?['uname']?.toString() ?? '';
      final face = _httpsFace(nav?['face']?.toString() ?? '');
      _biliSessionValid = nav == null ? null : nav['isLogin'] == true;
      if (name.isNotEmpty) _biliUserName = name;
      if (face.isNotEmpty) _biliUserFace = face;
      if (mounted &&
          (name.isNotEmpty || face.isNotEmpty || _biliSessionValid == false)) {
        notifyListeners();
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

  Future<void> biliLogout() async {
    _biliCookie = '';
    _biliCookieAt = 0;
    _biliUserName = '';
    _biliUserFace = '';
    _biliSessionValid = null;
    // 无参调用 = 清空登录态并作废缓存的匿名指纹，下次请求会重新取
    _biliSession?.setUserSession();
    notifyListeners();
    await _settings?.clearBiliSession();
  }

  /// 当前这首歌**实际**在播的音质（B站音质 ID，0 = 还没解析出来）。
  ///
  /// 与 [Song.source.qualityId] 的区别：后者是库里缓存的「上次拉流的档位」，
  /// 首次播放前是 null（界面上就成了「未知音质」）。这个值是播放器本次
  /// 真正装载的流，播什么就显示什么。
  int _playingQualityId = 0;
  int _playingBandwidth = 0;
  int get playingQualityId => _playingQualityId;
  int get playingBandwidth => _playingBandwidth;

  /// 当前在播音质的展示文案（未解析时为「未知音质」）
  String get playingQualityLabel =>
      audioQualityLabel(_playingQualityId, bandwidth: _playingBandwidth);

  /// 从播放器同步当前音质（切歌时清零、解析完成后取值）
  void _syncPlayingQuality() {
    final p = _player;
    final id = p?.currentQualityId ?? 0;
    final bw = p?.currentBandwidth ?? 0;
    if (_playingQualityId == id && _playingBandwidth == bw) return;
    _playingQualityId = id;
    _playingBandwidth = bw;
  }

  // ---- 每曲音量记忆 ----
  // B站音源响度驳杂（UP 主混音响度差可达 10dB 以上），用户会为个别
  // 声太大/太小的歌单独调音量。与「全局响度」（音效面板 LoudnessEnhancer）
  // 分层：全局响度管整体增益，这里管单首歌的独立音量，互不干扰。

  /// 当前歌的音量（0~1）。默认 1.0；起播时从 track_volume 表恢复。
  double _trackVolume = 1.0;
  double get trackVolume => _trackVolume;

  /// 设置当前歌的音量并落库（按曲记忆）。
  ///
  /// 面板滑条在 onChangeEnd 调用（拖动过程只改本地显示值），
  /// 所以这里不需要防抖。
  Future<void> setTrackVolume(double v) async {
    final vol = v.clamp(0.0, 1.0).toDouble();
    _trackVolume = vol;
    final p = _player;
    if (p != null) await p.setVolume(vol);
    notifyListeners();
    // 未入库的歌（id 为 null）没有记忆载体，音量只对本会话生效
    final song = current;
    final songId = song?.id;
    if (songId == null) return;
    try {
      await _repo?.saveTrackVolume(songId, vol);
    } catch (_) {
      // 落库失败不阻塞：至少本次会话内音量是对的
    }
  }

  /// 起播前恢复该曲的记忆音量。放在 playSong **之前**执行：
  /// DB 读只有几毫秒，先恢复才能避免「先以默认音量出声再被拉回来」
  /// 的听感跳变（对调过小音量的歌尤其明显）。
  Future<void> _restoreTrackVolume(int? songId) async {
    double v = 1.0;
    if (songId != null) {
      try {
        v = await _repo?.trackVolumeOf(songId) ?? 1.0;
      } catch (_) {
        v = 1.0;
      }
    }
    if (!mounted) return;
    final p = _player;
    if (p != null) {
      try {
        await p.setVolume(v);
      } catch (_) {}
    }
    if (!mounted || _trackVolume == v) return;
    _trackVolume = v;
    notifyListeners();
  }

  /// 真实播放器。为 null 时（单测环境）退化为计时器模拟进度。
  ///
  /// ⚠️ 保留这个可空设计不是洁癖：`audio_service` 需要在测试里
  /// 启动前台 Service，widget test 环境跑不起来。让播放器可空，
  /// 三个页面的测试就能完全不碰音频栈，跑得又快又稳。
  final AudioPlayerController? _player;

  // ---- 播放 ----
  List<Song> _queue = const [];
  int _index = -1;
  bool _playing = false;
  int _position = 0;
  int _duration = 0;
  PlayMode _mode = PlayMode.sequential;
  Timer? _ticker;

  // ---- 播放统计 ----
  //
  // ## 为什么要累计 listened 而不是直接读 position
  // `position` 是「当前播到第几秒」，用户可以来回拖——把它当收听时长会
  // 被 seek 污染（拖到 200 秒再拖回去，等于听了 400 秒）。
  // 这里按位置流的**增量**累加，且只在「递增且步长合理」时算，
  // 把拖动导致的大跳变过滤掉。
  int? _listeningSongId;
  int _listenedMs = 0;
  int _lastPosMs = 0;

  // ---- 曲库 ----
  List<Song> _library = const [];

  /// 真实曲库是否已就绪（false 时 [library] 返回空列表）
  LibraryLoadState _loadState = LibraryLoadState.idle;
  String? _loadError;

  /// 待人工确认的音源数（来自 DB 的 REVIEW 队列真实统计）
  int _pendingCount = 0;

  // ---- 播放统计（常听 / 最近播放）----
  List<Song> _topPlayed = const [];
  List<Song> _recentlyPlayed = const [];

  // ---- 收藏 ----
  //
  // ## 为什么两个集合
  // `_likedIds` 是**真相**（数据库自增主键），落库只认它；
  // `_likedKeys` 是渲染缓存（`title|artist`），让 `isLiked(Song)` 不查库。
  //
  // 单用一个 `key` 集合的后果：导入的歌还没拿到 id 时无法收藏，
  // 且改名后红心会失联。真实模式下两者都维护，mock 模式下只有 keys。
  final Set<int> _likedIds = {};
  final Set<String> _likedKeys = {};

  // ---- 界面 ----
  ThemeMode _themeMode = ThemeMode.light;
  int _tabIndex = 0;
  bool _playerOpen = false;
  int _playerTab = 0; // 0=歌曲 1=歌词
  int _lyricLine = 0;
  Duration? _sleepTimer;
  Timer? _sleepTicker;

  // ---- 搜索 ----
  bool _searchOpen = false;
  String _query = '';
  // 搜索历史：数据层未接入时用 mock 的示例词，真实运行时从空开始
  final List<String> _history = [];

  // ---- 在线搜索（QQ音乐）----
  /// 在线结果。空 = 还没搜过或搜完无结果（用 [_onlineSearched] 区分）
  List<OnlineSong> _onlineResults = const [];
  bool _onlineSearching = false;
  bool _onlineSearched = false;
  String? _onlineError;

  /// 在线搜索的请求序号（竞态防护）。
  ///
  /// 搜索请求在途时用户可以再按一次回车（关键词已改），两个请求并发
  /// 在途——慢的旧请求若后返回，会把新结果覆盖成旧词的结果。
  /// 每次发起搜索自增，返回时序号不是最新即丢弃。
  int _onlineSearchSeq = 0;

  // ---- getters ----

  /// 曲库（真实数据。**空库就是空列表**，不再回退 mock）
  List<Song> get library => _library;
  LibraryLoadState get loadState => _loadState;
  String? get loadError => _loadError;

  /// 曲库是否为空（UI 据此显示空状态引导）
  bool get libraryEmpty => _library.isEmpty;

  /// 是否正在首次加载曲库（区别于「加载完但是空的」）
  bool get libraryLoading => _loadState == LibraryLoadState.loading;

  /// 数据层是否未接入（只有单测 / 纯 UI 预览会是 true）
  ///
  /// 注意与旧版 `usingMock` 的语义差别：旧版把「库为空」也算作 usingMock，
  /// 导致真实空库被误判成 mock 模式。现在只有真的没接数据层才是 true。
  bool get usingMock => _repo == null;

  List<Song> get queue => _queue;
  int get index => _index;
  Song? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  bool get playing => _playing;
  int get position => _position;
  int get duration => _duration;
  PlayMode get mode => _mode;
  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == ThemeMode.dark;
  int get tabIndex => _tabIndex;
  bool get playerOpen => _playerOpen;
  int get playerTab => _playerTab;
  int get lyricLine => _lyricLine;
  bool get searchOpen => _searchOpen;
  String get query => _query;
  List<String> get history => List.unmodifiable(_history);
  Duration? get sleepTimer => _sleepTimer;

  /// 在线搜索结果（QQ音乐）。带真实 songMid，可直接入库。
  List<OnlineSong> get onlineResults => _onlineResults;

  /// 在线搜索是否进行中
  bool get onlineSearching => _onlineSearching;

  /// 是否已经完成过一次在线搜索（用于区分「还没搜」和「搜了没结果」）
  bool get onlineSearched => _onlineSearched;

  /// 在线搜索的错误信息（网络 / 风控等），null 表示无错
  String? get onlineError => _onlineError;

  /// 在线搜索是否可用：数据层未接入（单测/预览）时没有 QQ 接口，不可用
  bool get canSearchOnline => _repo != null;

  bool isLiked(Song s) => _likedKeys.contains(s.key);
  double get progress =>
      _duration > 0 ? (_position / _duration).clamp(0.0, 1.0) : 0.0;

  int get likedCount => _likedKeys.length;

  /// 常听（按有效播放次数倒序）。
  ///
  /// ## 与旧的「假常听」的区别
  /// 之前搜索页的「常听」是 `library.take(8)` 冒充的——那是「最近添加」。
  /// 现在它来自真实的播放次数统计（`play_stat` 表），只有一个真正听过的
  /// 歌才会出现。mock 模式（无数据层）下为空，UI 显示空状态。
  List<Song> get topPlayed => _topPlayed;

  /// 最近播放（按最后收听时间去重倒序）
  List<Song> get recentlyPlayed => _recentlyPlayed;

  /// 常听是否为空（UI 据此显示空状态或引导）
  bool get topPlayedEmpty => _topPlayed.isEmpty;

  /// 待确认音源数量。
  ///
  /// 真实库就绪时是 DB 里 REVIEW 队列的条数（[loadLibrary] 里统计），
  /// 否则用 mock 的占位值。
  int get pendingCount => _pendingCount;

  /// 队列总时长（分钟）
  int get queueMinutes =>
      (_queue.fold<int>(0, (a, s) => a + s.duration) / 60).round();

  // ---- 曲库加载 ----

  /// 从数据库加载曲库。在 app 启动后调用一次。
  Future<void> loadLibrary() async {
    final repo = _repo;
    if (repo == null) return;

    _loadState = LibraryLoadState.loading;
    _loadError = null;
    notifyListeners();

    try {
      final items = await repo.listSongs(limit: 500);
      // ⚠️ 空库就是空库。**不要**回退 MockData——那会让用户以为已经导入了歌。
      _library = items.map((e) => e.song).toList();
      _loadState = LibraryLoadState.ready;

      // 同步收藏状态。收藏是持久化在 liked_song 表里的用户行为，
      // 不重新拉一次的话，重启 app 后红心会全部消失（看起来像「没存上」）。
      _likedIds.clear();
      _likedKeys.clear();
      for (final r in await repo.likedIds()) {
        _likedIds.add(r);
      }
      for (final s in _library) {
        if (s.id != null && _likedIds.contains(s.id)) {
          _likedKeys.add(s.key);
        }
      }

      // 同步待确认数（REVIEW 队列真实条数）
      final stats = await repo.stats();
      _pendingCount = stats.reviewCount;

      // 同步播放统计。这两项都随「听歌」变化，不只是随库变化——
      // 所以刷新曲库时一并重拉，避免「刚听完一首但常听榜没更新」。
      _topPlayed = (await repo.topPlayedSongs(limit: 20, minCount: 1))
          .map((e) => e.song)
          .toList();
      _recentlyPlayed = (await repo.recentlyPlayedSongs(limit: 30))
          .map((e) => e.song)
          .toList();

      // 播放队列同步策略（队列红线，2026-09-30）：
      // 队列 = 用户点击上下文的全量列表（榜单/歌手/新歌推荐/收藏…），
      // 曲库刷新**绝不重建**队列结构。旧实现「重建为曲库全量 + 按
      // current.key 找回」会把点播队列偷换成曲库顺序——用户按下一首
      // 就脱离了点击时的列表（日志实测：恢复态下队列被偷换后，
      // 千里之外这类曲库旧歌会顶掉用户刚点的歌）。只有两种情况动队列：
      if (_queue.isEmpty) {
        // ① 冷启动首次加载：队列还是空的，填充为曲库全量，
        //    供 restoreSession 按 key 找回上次的歌。
        //    空库诚实空着：index = -1，不指向不存在的歌。
        _queue = [..._library];
        _index = _queue.isEmpty ? -1 : 0;
        _syncDuration();
      } else {
        // ② 队列已有内容（正在播放某个上下文）：只把里面的旧对象
        //    换成曲库里的新对象（时长补全、音源激活等），顺序与
        //    播放位置一概不动。
        _syncQueueWithLibrary();
      }

      // ⚠️ 上面有多个 await。loadLibrary 常被 unawaited 调用
      // （playOnline / ensurePlayableSource 里都是），AppState 若在
      // 等待期间被 dispose，不带 mounted 守卫就会「used after disposed」。
      if (mounted) notifyListeners();
    } catch (e) {
      if (!mounted) return;
      _loadState = LibraryLoadState.failed;
      _loadError = '$e';
      notifyListeners();
    }
  }

  /// 用 [_library] 里最新的同 id 对象替换 [_queue] 中的旧对象。
  ///
  /// 只做**就地替换**，不动队列结构：队列代表播放顺序，可能来自
  /// 「按专辑播」这类非曲库顺序的列表，重建会把用户的播放位置弄丢。
  void _syncQueueWithLibrary() {
    if (_queue.isEmpty || _library.isEmpty) return;
    final byId = <int, Song>{};
    for (final s in _library) {
      final id = s.id;
      if (id != null) byId[id] = s;
    }
    for (var i = 0; i < _queue.length; i++) {
      final id = _queue[i].id;
      if (id == null) continue;
      final fresh = byId[id];
      if (fresh != null) _queue[i] = fresh;
    }
  }

  /// 重新加载（导入完曲库 / 匹配完后调）
  ///
  /// ## 为什么这里**不恢复、也不重建**播放状态
  /// 曲库刷新对播放链路是「旁路」：current / _index / _queue 结构都不归
  /// 它管——队列属于点击上下文（见 [loadLibrary] 内注释）。旧实现先后
  /// 用过「先存后恢复」「重建 + 按 current.key 找回」两版，都曾把
  /// current 改成别的歌（真机上表现为「点了新歌，迷你播放条还显示
  /// 之前那首」）。现在的唯一职责：刷新曲库/收藏/统计 + 同步队列里的
  /// 陈旧对象。
  Future<void> refreshLibrary() async {
    if (_loadState == LibraryLoadState.loading) return;
    await loadLibrary();
  }

  // ── 会话恢复（冷启动回到上次的界面与播放进度）──────────────
  //
  // 需求（2026-09-30）：退出重进后保持上次的界面（主题 / tab / 播放页），
  // 当前歌以**暂停态**呈现、进度保留——无论退出时是否在播，恢复后一律暂停。
  //
  // ## 为什么恢复不装载音源、不发起任何网络请求
  // 拉流要消耗 B站 限流配额（30 次/分钟），冷启动静默拉流既浪费又可能
  // 撞风控；而且用户可能只是想看一眼就退出。所以恢复只重建「界面快照」：
  // 队列定位 + 进度显示，音源留到用户真正按下播放键时走既有按需链路。

  /// 恢复态的待续播秒数（[restoreSession] 设置，[_playResolved] 装载成功后消费）。
  ///
  /// 非 null 时，`togglePlay` 的空源重试分支走 [_resumeTrack]（保留进度）
  /// 而不是 [_resetTrack]（归零重播）。所有**显式**切歌路径
  /// （playSong / playQueue / jumpTo / next / previous）都会清掉它，
  /// 保证旧进度绝不串到别的歌上。
  int? _resumeSeekSec;

  /// 恢复上次会话。曲库加载完成后调用一次（main.dart _boot）。
  ///
  /// 歌按 `key`（title|artist）在当前队列里找回；找不到（歌被删了 /
  /// 曲库清空）就只恢复界面、不恢复播放快照。
  Future<void> restoreSession() async {
    final settings = _settings;
    if (settings == null) return;

    _tabIndex = settings.lastTabIndex.clamp(0, 1);

    final key = settings.sessionSongKey;
    final pos = settings.sessionPositionSec;
    final q = _queue;
    final i = key.isEmpty ? -1 : q.indexWhere((s) => s.key == key);
    if (i >= 0) {
      _index = i;
      if (pos > 0) {
        // 进度恢复到元数据时长以内，防止「退出前进度已过时长」的脏数据
        final dur = q[i].duration;
        _position = dur > 0 ? pos.clamp(0, dur) : pos;
        _resumeSeekSec = _position;
        _updateLyricLine();
      }
      _syncDuration();
      // 歌词提前取好：用户点开播放页就能看到词，而不是等一次网络往返
      unawaited(loadLyricForCurrent());
      // 播放页只在「确实有可恢复的歌」时展开——空播放页没有意义
      if (settings.lastPlayerOpen) _playerOpen = true;
    }

    // ⚠️ 恒为暂停态：_playing 保持 false，不装载音源。
    // 用户按播放时由 togglePlay → _resumeTrack → _playResolved 接力，
    // 装载成功后 seek 回 [sessionPositionSec]。
    if (mounted) notifyListeners();
  }

  /// 落盘当前播放会话快照（当前歌 + 进度）。
  ///
  /// 调用时机：暂停时、切歌时、拖动进度时、播放中每 15 秒打点、
  /// 以及 app 退到后台（main.dart 生命周期监听）。多打点是为了兜住
  /// 「直接划掉应用」——那时不会再有任何回调，只靠最近一次落盘。
  Future<void> persistSession() async {
    _lastPersistedPos = _position;
    await _settings?.saveSession(
      songKey: current?.key ?? '',
      positionSec: _position,
    );
  }

  /// 最近一次已落盘的进度秒数（打点节流用）
  int _lastPersistedPos = 0;

  /// 恢复态按播放键的接力入口：与 [_resetTrack] 的区别是**不清进度**，
  /// 让 [_playResolved] 装载完成后 seek 回恢复的进度。
  void _resumeTrack() {
    _syncDuration();
    _playCurrent();
  }

  /// 待人工确认的曲目（音源匹配管理页用）
  Future<List<SongWithSource>> loadReviewQueue() async {
    final repo = _repo;
    if (repo == null) {
      // 无数据层时回退 mock 的 pending 项。
      // 注意这些 song 的 id 为 null，界面据此禁用「确认采用」（无法落库）。
      return MockData.songs
          .where((s) => s.sourceStatus != SourceStatus.ok)
          .map((s) => SongWithSource(song: s))
          .toList();
    }
    return repo.reviewQueue();
  }

  /// 未匹配到音源的曲目
  Future<List<SongWithSource>> loadUnmatched() async {
    final repo = _repo;
    if (repo == null) return const [];
    return repo.unmatchedQueue();
  }

  /// 人工确认采用某个音源（真实落库，修掉原先只改队列副本的 bug）
  Future<bool> confirmSource({
    required int songId,
    required String bvid,
    required double score,
    bool userSelected = false,
  }) async {
    final repo = _repo;
    if (repo == null) return false;
    try {
      await repo.confirmBinding(
        songId: songId,
        bvid: bvid,
        score: score,
        userSelected: userSelected,
      );
      // 关键：落库后必须刷新曲库，否则界面仍显示旧状态
      await refreshLibrary();
      return true;
    } catch (e) {
      _loadError = '确认失败：$e';
      notifyListeners();
      return false;
    }
  }

  /// 对单首歌重新跑匹配（真实调用匹配引擎）。
  ///
  /// ## 为什么匹配完还要走 activateBestCandidate 兜底
  /// matchOne 只在 AUTO（≥0.82）时激活；B站 对新歌/冷门歌常见的是
  /// REVIEW 级候选（0.60~0.82）。如果这里不兜底，「重新匹配」转完 20 秒
  /// 之后源还是 null——用户看到的现象就是「每次都说要重新匹配，
  /// 重新匹配了还是暂无可用音源」。点播语境允许 0.60 兜底激活
  /// （与 [ensurePlayableSource] 同一策略），批量 AUTO-only 红线不受影响。
  Future<String> rematchSong(int songId) async {
    final repo = _repo;
    if (repo == null) return '数据层未接入';
    try {
      final r = await repo.matchOne(songId);
      if (!r.isBound) {
        final activated = await repo.activateBestCandidate(songId);
        if (!activated) {
          await refreshLibrary();
          return '没找到足够的候选，试试「手动搜索音源」';
        }
      }
      await refreshLibrary();
      if (r.best == null) return '已激活历史最高分候选';
      return '匹配到 ${r.best!.video.bvid}（${r.best!.score100} 分 ${r.confidence.label}）';
    } catch (e) {
      return '匹配失败：$e';
    }
  }

  /// 手动兜底第一步：按关键词搜 B站，返回**未打分**的原始候选。
  ///
  /// 与匹配引擎的召回不同——这里不做任何打分/过滤，标题黑名单也不生效
  /// （用户看到「翻唱」两个字自然不会选它，打分交给用户的眼睛）。
  /// 只发一次搜索请求，不碰限流红线。
  Future<List<VideoCandidate>> manualSearchBili(String keyword) async {
    final repo = _repo;
    if (repo == null) return const [];
    try {
      return await repo.searchBiliCandidates(keyword);
    } catch (_) {
      // 网络异常/风控都返回空列表，让面板自己显示「没有结果」
      return const [];
    }
  }

  /// 手动兜底第二步：把用户亲自挑中的视频绑定为该歌的音源并播放。
  ///
  /// 行为：视频行 upsert → 人工绑定（USER_SELECTED，调参最有价值的样本，
  /// 设计文档 6.4）→ 刷新曲库 → 若是当前在播的歌立即重拉流。
  Future<String> bindManualSource({
    required int songId,
    required VideoCandidate video,
  }) async {
    final repo = _repo;
    if (repo == null) return '数据层未接入';
    try {
      await repo.bindManualVideo(songId: songId, video: video);
      await refreshLibrary();

      final cur = current;
      final p = _player;
      if (cur != null && cur.id == songId && p != null) {
        final fresh = (await repo.getSong(songId))?.song;
        if (fresh != null) {
          _replaceQueued(songId, fresh);
          await p.playSong(fresh, forceRefresh: true);
          if (!mounted) return '已指定音源：${video.bvid}';
          _syncPlayingQuality();
          notifyListeners();
        }
      }
      return '已指定音源：${video.bvid}';
    } catch (e) {
      return '绑定失败：$e';
    }
  }

  /// 取该歌**所有**候选（按分数倒序），供「手动更换音源」面板展示。
  ///
  /// 直接走 [BindingDao.getCandidates] 而不是包一层 Repository 方法：
  /// DAO 接口本身已经语义单一（`SELECT FROM binding WHERE song_id=?`），
  /// 再包装没有新增价值，反而徒增跳板。数据层未接入时返回空列表。
  Future<List<BindingRow>> loadCandidates(int songId) async {
    final repo = _repo;
    if (repo == null) return const [];
    return repo.db.bindings.getCandidates(songId);
  }

  /// 把当前激活音源切到指定候选（B站 bvid）。
  ///
  /// 行为约定：
  ///  - **唯一激活**：切前清掉该歌其它激活记录（[BindingDao.activate] 已事务化）。
  ///  - **落库即刷新**：写库后调 [refreshLibrary]，曲库列表与统计立刻跟上。
  ///  - **如果切的是当前在播的歌，立即重拉流**：用 `forceRefresh: true` 跳过
  ///    SourceResolver 的 URL 缓存，避免播的还是旧音源。
  ///
  /// 设计文档 6.4：用户改选记为 USER_SELECTED（调参最有价值的样本）；
  /// 当前实现只完成"切到 bvid"，score 类型留为原值——切后整库会被
  /// 后续 matchOne 重新评估。如果后面要严格区分，选时再带 score。
  Future<String> switchSource({
    required int songId,
    required String bvid,
  }) async {
    final repo = _repo;
    if (repo == null) return '数据层未接入';
    try {
      await repo.db.bindings.activate(songId, bvid);
      await refreshLibrary();

      final cur = current;
      final p = _player;
      if (cur != null && cur.id == songId && p != null) {
        final fresh = (await repo.getSong(songId))?.song;
        if (fresh != null) {
          // 队列里的对象也要换，否则通知栏 / 音源徽标还显示旧的
          _replaceQueued(songId, fresh);
          await p.playSong(fresh, forceRefresh: true);
          if (!mounted) return '已切换为 $bvid';
          _syncPlayingQuality();
          notifyListeners();
        }
      }
      return '已切换为 $bvid';
    } catch (e) {
      return '切换失败：$e';
    }
  }

  // ---- 导入曲库 ----

  /// 导入状态文案（导入中显示，导入完成后保留结果供用户查看）
  String? get importMessage => _importMessage;
  String? _importMessage;

  // ---- 全局轻提示（toast） ----

  /// 当前显示的提示。null = 无。
  ///
  /// ## 为什么不用 SnackBar
  /// SnackBar 需要 ScaffoldMessenger 的 context，而 AppState 是全局状态；
  /// 且提示要跨 tab 可见（用户在「音乐」页点歌，失败提示不能只出现在
  /// 播放页）。用一个全局字段 + 外壳层渲染，与 MatchBanner 同一插槽。
  String? get toast => _toast;
  String? _toast;
  Timer? _toastTimer;

  /// 显示一条 3 秒自动消失的轻提示。
  ///
  /// 3s 而非更早版本的 5s：轻提示是单行短文案（10~20 字），5s 驻留过长
  /// （2026-09-30 用户反馈）。带错误详情的长文案走播放页 SnackBar。
  Future<void> showToastLater(String msg) async => showToast(msg);

  void showToast(String msg) {
    _toast = msg;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      _toast = null;
      notifyListeners();
    });
  }

  bool get importing => _importing;
  bool _importing = false;

  /// 是否有次级路由压在外壳之上（目录子页、歌曲列表页等 Navigator push 的页）。
  ///
  /// ## 为什么需要它
  /// 迷你播放条有**两种形态**：一级页面用 Shell 内嵌条（在底部 tab 栏上方）；
  /// 次级页面上 Shell 整个被路由盖住，内嵌条不可见——改由 MaterialApp.builder
  /// 挂悬浮条。悬浮条只在次级页面出现（次级页没有 tab 栏，悬浮在底部），
  /// 切换时机由 NavigatorObserver 回调 [setSubPageOpen]。
  bool _subPageOpen = false;
  bool get subPageOpen => _subPageOpen;
  void setSubPageOpen(bool v) {
    if (_subPageOpen == v) return;
    _subPageOpen = v;
    notifyListeners();
  }

  // 说明：原「批量匹配」管线（matchAllPending / 进度状态 / 中止）
  // 已随「批量匹配音源」功能一并移除——匹配统一走播放页按需路径
  // （ensurePlayableSource，见 _playResolved 的注释）。

  // 说明：原「按关键词批量导入」（importByKeywords）已随「导入歌曲」入口
  // 一并移除——导入路径现在只有音乐页目录点歌（[playOnline] 静默入库）。
  // Repository 的 importFromKeywords 保留：它是纯数据层能力，
  // 日后要接批量入口时不必重写严格三重校验。

  // ---- 播放控制 ----
  //
  // ## 这里为什么既保留计时器又接真实播放器
  // [AudioPlayerController] 在单测环境不可用（audio_service 需要前台 Service），
  // 但三个页面的 widget test 必须能跑。所以 `_player == null` 时退化为
  // 「每秒 +1 秒」的模拟进度——界面逻辑（进度条、歌词高亮、自动下一首）
  // 在这两种模式下走的是**完全相同**的代码路径，测试才真的有意义。
  // 该退化路径只在测试里存在，真实 app 由 main.dart 注入 player。

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playSub;

  /// 播放失败 / 音源失效的提示文案（UI 用 SnackBar 展示）
  String? _playbackError;
  String? get playbackError => _playbackError;

  void clearPlaybackError() {
    _playbackError = null;
  }

  /// 当前是否正在解析音源（拉流中，UI 显示转圈）
  bool _resolving = false;
  bool get resolvingSource => _resolving;

  /// 播放代次：每次 [_playResolved] 启动时自增。
  /// 快速连点两首歌时，先点的任务在其 await 恢复后发现代次已变，
  /// 就地作废——否则旧任务会与新歌抢 `setAudioSource`。
  int _playGen = 0;

  /// 最新一次点播目标歌的 id（[_playCurrent] 维护）。
  ///
  /// 匹配一首要几十秒，期间用户很可能已经点了别的歌。判断「在途匹配的
  /// 结果是否已过时」用这个字段而不是切歌代号：点 A → 点 B → 再点回 A
  /// 时，A 的在途匹配仍然有效，不该作废重跑（重跑 = 白烧一份限流配额）。
  int? _pendingPlayId;

  /// 在途点播匹配（按歌 id）。
  ///
  /// 同一首歌的重复点播 / 失败后秒重试**复用**同一次 matchOne，不叠加
  /// 并发——3 个并发 matchOne = 3 份限流配额，每个都被 30 次/分钟的
  /// 全局限流拖到 45~73 秒（2026-09-30 真机日志实测：恢复态连按 3 次
  /// 播放，千里之外被重复匹配 3 遍，期间所有点击全部无响应）。
  final Map<int, Future<Song?>> _inflightMatches = {};

  /// 正在按需匹配音源的歌名（非空 = 「这首没有音源，正在现匹配」）。
  ///
  /// ## 为什么单独一个字段而不用 [_importMessage]
  /// 它要驱动**全局状态条**。首次播放一首没匹配的歌要等约 20 秒，
  /// 用户往往已经切到别的 tab 去干别的了——只有全局可见的反馈
  /// 才能解释「为什么点了播放没马上出声」。
  String? _onDemandMatchTitle;
  bool get matchingOnDemand => _onDemandMatchTitle != null;
  String? get onDemandMatchTitle => _onDemandMatchTitle;

  // ---- 歌词 ----

  /// 当前歌的歌词（真实 LRC 解析结果）。
  ///
  /// ⚠️ 这里刻意**不再有硬编码的假歌词**。之前播放页写死了《起风了》的
  /// 8 行词，导致播任何别的歌都显示这几行——比"暂无歌词"更糟，
  /// 因为用户会以为歌词错位了。宁可显示空。
  ParsedLyric _lyric = ParsedLyric.empty;
  ParsedLyric get lyric => _lyric;

  /// 歌词行列表（UI 直接消费）
  List<LyricLine> get lyrics => _lyric.lines;

  /// 是否正在加载歌词
  bool _lyricLoading = false;
  bool get lyricLoading => _lyricLoading;

  /// 为哪首歌加载过歌词（避免重复请求；收藏切歌来回时不必重拉）
  String? _lyricFor;

  /// 加载当前歌的歌词。
  ///
  /// 歌词来源是 QQ音乐（与元数据同源，有 songMid 就能取）。
  /// 取不到不是错误——纯音乐、下架曲目都可能没有，静默留空。
  Future<void> loadLyricForCurrent({bool force = false}) async {
    final song = current;
    final repo = _repo;
    if (song == null || repo == null) {
      _lyric = ParsedLyric.empty;
      return;
    }
    if (!force && _lyricFor == song.key) return;

    _lyricFor = song.key;
    _lyricLoading = true;
    _lyric = ParsedLyric.empty;
    notifyListeners();

    try {
      final bundle = await repo.fetchLyric(song);
      final raw = bundle?.lrc;
      _lyric = raw == null || raw.trim().isEmpty
          ? ParsedLyric.empty
          : attachTranslation(parseLrc(raw), bundle?.translation);
    } catch (_) {
      // 歌词失败不影响播放，静默留空
      _lyric = ParsedLyric.empty;
    } finally {
      _lyricLoading = false;
      // 歌词到位后按当前进度重算高亮行（前奏期间加载完的话，
      // 不重算会一直停在原来的行号上）
      _updateLyricLine();
      // _playCurrent 里是 unawaited 调这里，dispose 后可能才走到
      if (mounted) notifyListeners();
    }
  }

  void _bindPlayer() {
    final p = _player;
    if (p == null) return;

    _posSub = p.positionStream.listen((d) {
      // 解析期间忽略位置事件：切歌 stop 的瞬间，just_audio 会把**上一首**
      // 的进度随 idle 平台装载广播回来，若照单全收，刚归零的进度条会被
      // 旧值覆盖（「停在上一首歌的时间」的直接来源）。此时的新歌进度
      // 只能是 0，等装载完成后位置流自然会恢复推送。
      if (_resolving) return;
      _position = d.inSeconds;
      // 累计本次「实际听了多久」。用它而不是「点了多少次」来计播放次数——
      // 点开又秒切不该算听过（见 PlayStatsDao.countingThresholdMs）。
      _accumulateListened(d);
      _updateLyricLine();
      // 进度打点（15 秒节流）：用户不暂停、直接划掉应用时没有任何
      // 回调机会，恢复进度只能靠最近一次落盘。SharedPreferences 写入
      // 是内存级操作 + 异步刷盘，15 秒一次的开销可忽略。
      // 恢复态续播未完成前不打点：装载初期的位置事件从 0 推进，
      // 会把快照里刚存的进度覆盖掉。
      if (_resumeSeekSec == null && (_position - _lastPersistedPos).abs() >= 15) {
        unawaited(persistSession());
      }
      notifyListeners();
    });

    _durSub = p.durationStream.listen((d) {
      // 优先信任真实音频时长；它为 0 时（还没加载完）保持曲库元数据时长
      if (d.inSeconds > 0) {
        _duration = d.inSeconds;
        notifyListeners();
      }
    });

    _playSub = p.playingStream.listen((v) {
      if (_playing == v) return;
      _playing = v;
      notifyListeners();
    });

    // 播放结束 → 下一首（尊重 PlayMode）
    p.onTrackEnded = () async => next();

    // 通知栏 / 耳机线控 / 蓝牙的切歌请求 → 与界面按钮同一条链路。
    // BaseAudioHandler 的 skipToNext/skipToPrevious 默认是空操作，
    // 不接的话通知栏两个切歌键、线控双击全是死的。
    p.onSkipToNext = () async => next();
    p.onSkipToPrevious = () async => previous();

    // 播放出错 → 大概率是 URL 过期，重解析一次（必要时自动重新匹配）
    p.onPlaybackError = (e) async {
      final song = current;
      if (song == null) return;
      final r = await p.resolver?.resolveAfterPlaybackError(song);
      if (r == null || !r.ok) {
        _playbackError = r?.error ?? '播放失败';
        _playing = false;
        notifyListeners();
      }
    };
  }

  void _syncDuration() {
    final s = current;
    // 真实播放器已经有音频时长时不要覆盖它——
    // 曲库元数据的时长（QQ音乐给的）与视频实际时长常差 1~3 秒，
    // 用元数据去覆盖真实时长会让进度条永远走不满。
    if (_player != null && _duration > 0 && _playing) return;
    if (s != null) _duration = s.duration;
  }

  /// 按当前播放位置刷新歌词高亮行。
  ///
  /// 有真实歌词时按时间轴查找；没有时（mock / 纯音乐）退化为按比例分布，
  /// 保证歌词页不会永远停在第一行。
  void _updateLyricLine() {
    final lines = lyrics;
    if (lines.isEmpty) {
      _lyricLine = 0;
      return;
    }
    var idx = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time.inMilliseconds <= _position * 1000) {
        idx = i;
      } else {
        break;
      }
    }
    _lyricLine = idx.clamp(0, lines.length - 1);
  }

  /// 标记为正在播放并（在无真实播放器时）启动模拟计时器
  void _startPlayback() {
    _playing = true;
    if (_player == null) {
      _startTicker();
    }
  }

  Future<void> togglePlay() async {
    // 匹配/拉流期间播放器里没有可播的东西（切歌时旧声已被 stopForSwitch
    // 切断、播放器处于 idle）。此时按「播放」只会挂出一个无声的假播放态，
    // 等 playSong 完成后自然开声——期间直接忽略按键。
    if (_resolving) return;
    final p = _player;
    final song = current;
    // 播放器里没有装载任何音源（无源失败态 / 解析失败后）：按播放 =
    // 重新走「按需匹配 → 装载 → 播放」链路，而不是对着空播放器空转。
    // 直接 p.play() 只会挂出假播放态（播放器已空，无声可出）；
    // 用户修好音源（手动搜索/重新匹配）后 bindManualSource 会自行起播，
    // 这里兜住的是「失败后直接再按一次播放」的最短重试路径。
    if (p != null && song != null && !_playing && !p.hasLoadedSource) {
      // 恢复态（restoreSession 留下了待续播进度）：走 _resumeTrack 保留
      // 进度，装载完成后 seek 回去；其余失败态从零开始重播。
      if (_resumeSeekSec != null) {
        _resumeTrack();
      } else {
        _resetTrack();
      }
      return;
    }
    if (_playing) {
      await p?.pause();
      // 暂停即落盘会话快照：用户可能暂停后直接杀进程，
      // 没有这一次落盘的话恢复出来的进度会停在更早的打点上。
      unawaited(persistSession());
    } else {
      await p?.play();
    }
    // ⚠️ 这里是 async 间隙后的落点。UI 把 togglePlay 当同步回调用
    // （onPressed 里直接调，不 await），如果期间页面被销毁，
    // 后面的 notifyListeners() 会抛「used after being disposed」。
    // 真机上表现为退出播放页时偶发崩溃，所以必须在这里挡一道。
    if (!mounted) return;
    // 暂停时结算收听时长：用户可能暂停很久甚至直接杀进程，
    // 等到切歌才记的话这一段就丢了，「最近播放」会滞后。
    if (_playing) unawaited(_flushPlayRecord());
    // 无真实播放器时靠本地标记 + 计时器
    if (p == null) {
      _playing = !_playing;
      if (_playing) {
        _startTicker();
      } else {
        _ticker?.cancel();
      }
    }
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_position < _duration) {
        _position++;
        _updateLyricLine();
        notifyListeners();
      } else {
        next();
      }
    });
  }

  void next() {
    if (_queue.isEmpty) return;
    if (_mode == PlayMode.repeatOne) {
      _position = 0;
      _player?.seek(Duration.zero);
      _player?.play();
      if (_player == null) notifyListeners();
      return;
    }
    if (_mode == PlayMode.shuffle) {
      _index = Random().nextInt(_queue.length);
    } else {
      _index = (_index + 1) % _queue.length;
    }
    _resetTrack();
  }

  void previous() {
    if (_queue.isEmpty) return;
    if (_position > 4) {
      _position = 0;
      _player?.seek(Duration.zero);
      if (_player == null) notifyListeners();
      return;
    }
    _index = (_index - 1 + _queue.length) % _queue.length;
    _resetTrack();
  }

  void _resetTrack() {
    _position = 0;
    _lyricLine = 0;
    // 显式切歌/跳歌 = 用户放弃了恢复态的续播意图，必须清掉，
    // 否则旧歌的进度会被 seek 到新歌上（进度串歌）。
    _resumeSeekSec = null;
    _syncDuration();
    // 真实播放器：切歌即拉流并开始播放（异步，失败会回落到 onPlaybackError）
    _playCurrent();
    if (_player == null) notifyListeners();
  }

  /// 把 [current] 交给真实播放器。无播放器时只更新界面状态。
  ///
  /// ⚠️ 歌词加载挂在这里而不是三个切歌入口各挂一次：
  /// `playSong` / `playQueue` / `jumpTo` / `_resetTrack`（next/previous）
  /// 全都汇流到这一个方法，只挂一处就不会出现「某个入口切歌歌词不换」。
  void _playCurrent() {
    // 歌词与音源并行加载：歌词来自 QQ音乐，音源来自 B站，互不阻塞。
    // 先发歌词请求能盖住拉流的那几百毫秒，用户看到词比听到声音早一点，
    // 观感上比「先出声、过两秒才蹦出词」自然。
    unawaited(loadLyricForCurrent());

    // 切歌前先把上一首的收听时长结算掉，否则会丢一段。
    // ⚠️ 必须在 _listeningSongId 被改掉**之前**调，所以放在最前面。
    unawaited(_flushPlayRecord());

    final p = _player;
    final song = current;
    // 新歌开始，重置本次收听计数
    _listeningSongId = song?.id;
    // 同步「最新点播目标」：ensurePlayableSource 的在途匹配靠它判断
    // 自己是否已被用户放弃（见字段注释）
    _pendingPlayId = song?.id;
    _listenedMs = 0;
    _lastPosMs = 0;
    // 旧歌的真实时长随切歌作废：先清零再回落到新歌的元数据时长，
    // 新源装载完成后由 durationStream 用真实时长覆盖。
    // 不清的话，从切歌到装载完成这段时间总时长还显示上一首的值，
    // 进度条比例全错（用户看到「进度停在上一首」的另一半来源）。
    _duration = 0;
    _syncDuration();
    if (p == null || song == null) return;
    // 通知栏元数据先切新歌：没音源的歌要等匹配完 playSong 才会换，
    // 提前换让通知栏与迷你条/播放页同步显示新歌。
    p.previewMediaItem(song);
    // 新歌还没解析 → 清掉上一首的音质，避免详情面板显示上一首的档位
    _playingQualityId = 0;
    _playingBandwidth = 0;
    // 切歌即更新会话快照（新歌 + 当前进度）。恢复态接力（_resumeTrack）
    // 也会走到这里，落盘的是同一首歌的同一进度，幂等无害。
    unawaited(persistSession());
    _setResolving(true);
    unawaited(_playResolved(p, song));
  }

  /// 真正把一首歌交给播放器：**没有音源就先只匹配这一首**，再播。
  ///
  /// ## 切歌即断旧声（2026-09-29 需求）
  /// 不管新歌有没有音源、匹配要等多久，旧歌必须**立刻**停——匹配最长
  /// 20 秒，旧声不停的话用户看到的是「界面换了歌、耳朵还是上一首」。
  /// [AudioPlayerController.stopForSwitch] 会停掉旧声**并清空已装载的
  /// 音源**——只 stop 不清源的话，just_audio 会在下一次 play() 时把旧歌
  /// 按旧进度原地复活（2026-09-30 真机实测：「切歌失败后按播放，响的
  /// 还是上一首」就是这个原因）。
  ///
  /// [_playGen] 用于丢弃在途任务：快速连点两首歌时，先点的歌在其
  /// await 恢复后必须作废，不能与新歌抢 `setAudioSource`。
  ///
  /// ## 为什么必须按需匹配，而不是「等批量匹配跑完」
  /// 批量匹配受 B站 限流（30 次/分钟）约束，20 首要跑 6~7 分钟。如果没音源时
  /// 只能回一句「这首歌还没有匹配到音源」，用户在这几分钟里**一首歌都听不了**。
  /// 而「导入完发现听不了、也不知道要等多久」正是被抱怨成「卡住」的那个体验。
  ///
  /// 但用户真正会听的往往只有导入的其中几首。点哪首匹配哪首（约 20 秒/首），
  /// **首首可播时间从 6~7 分钟压到 20 秒**，而且总请求量更少 ——
  /// 不听的歌根本不会去匹配，不消耗任何限流配额。
  ///
  /// 批量匹配并非被取代：它仍然是「我就是要全部预处理」的手段，
  /// 入口在「我的 → 批量匹配音源」。
  Future<void> _playResolved(AudioPlayerController p, Song song) async {
    final gen = ++_playGen;

    // ⚠️ stop 必须先于新歌的 setAudioSource 完成（两者同在本方法内
    // 顺序执行），否则平台侧的 stop 可能把刚装载的新音源清掉。
    await p.stopForSwitch();
    if (!mounted || gen != _playGen) return;

    var target = song;
    if (target.source == null) {
      final fresh = await ensurePlayableSource(target);
      if (!mounted || gen != _playGen) return;
      if (fresh == null) {
        _setResolving(false);
        // 失败态收尾：进度与歌词行必须归零。切歌时 _resetTrack 已经清过，
        // 但播放器 stop 的瞬间会按**上一首**的进度广播一次位置事件把它
        // 覆盖回去——不在这里再清一次，进度条就停在上一首歌的时间上。
        // 时长回落为新歌的元数据时长（_playing=false 时 _syncDuration 会覆盖）。
        _position = 0;
        _lyricLine = 0;
        _syncDuration();
        _updateLyricLine();
        _playbackError = '没有找到可播放的音源：${target.title}';
        _playing = false;
        notifyListeners();
        // 浏览场景下用户不一定打开播放页，错误必须全局可见
        showToast('没找到可靠的音源：${target.title}');
        return;
      }
      target = fresh;
    }

    // 每曲音量：装载前先恢复该曲的记忆音量（见 _restoreTrackVolume 注释）。
    // 不参与 _playGen 竞态本身——它只动音量，晚到一次也只是多写一次 setVolume。
    await _restoreTrackVolume(target.id);
    if (!mounted || gen != _playGen) return;

    try {
      // 60s 兜底：resolve / setAudioSource 在极端弱网下可能长时间不返回，
      // 不能让 resolvingSource 的转圈无限期挂着（真机实测过「一直转圈」）。
      final err =
          await p.playSong(target).timeout(const Duration(seconds: 60));
      // 已被更新的切歌任务顶掉时静默退出——错误提示归最新一代管，
      // 否则会弹出「已切换到其他歌曲」这类用户看不懂的噪音。
      if (!mounted || gen != _playGen) return;
      // 解析完成后才有「真实在播的音质」——放这里而不是订阅播放器，
      // 是因为音质在一次装载里是恒定的，没必要为它再开一条流。
      _syncPlayingQuality();
      _setResolving(false);
      if (err != null) {
        _playbackError = err;
        // 播不出来就别显示"正在播放"
        _playing = false;
        notifyListeners();
      } else {
        // 会话恢复的续播：装载成功后跳回上次退出的进度。
        // seek 成功后才清标记：清早了的话，装载与 seek 之间的位置流
        // 事件（从 0 重新推进）会把快照里刚存的进度覆盖成 0。
        final resume = _resumeSeekSec;
        if (resume != null && resume > 0) {
          await p.seek(Duration(seconds: resume));
          if (!mounted || gen != _playGen) return;
          _position = resume;
          _resumeSeekSec = null;
          _lastPersistedPos = resume;
          _updateLyricLine();
          notifyListeners();
        }
      }
    } on TimeoutException {
      if (!mounted || gen != _playGen) return;
      // 作废在途装载，避免「超时报错之后，挂起的任务完成又突然出声」
      await p.cancelLoad();
      if (!mounted) return;
      _setResolving(false);
      _playbackError = '加载超时，请检查网络后重试';
      _playing = false;
      notifyListeners();
    } catch (e) {
      if (!mounted) return;
      _setResolving(false);
      _playbackError = '$e';
      _playing = false;
      notifyListeners();
    }
  }

  /// 确保 [song] 有一个可播放的音源；没有就现匹配。
  ///
  /// 成功返回**带音源的最新对象**（同时已就地替换播放队列里的旧对象），
  /// 失败返回 null。公开是为了让「匹配这首」这类入口能复用，
  /// 也让这条链路能被单测直接覆盖。
  ///
  /// ⚠️ 匹配一首要 10 次请求、约 20 秒。调用方**必须**先给出等待反馈，
  /// 否则用户面对的是 20 秒静默 + 一个转圈。
  Future<Song?> ensurePlayableSource(Song song) async {
    // 已经有音源就没必要再匹配。匹配一首要 10 次请求、约 20 秒，
    // 白跑一次就是白等 20 秒 + 白烧一份限流配额。
    if (song.source != null) return song;

    final repo = _repo;
    final id = song.id;
    // 没有数据层（单测/预览）或这首歌还没落库（id 为 null）时无法匹配。
    if (repo == null || id == null) return null;

    // 同一首歌的在途匹配直接复用：连按播放、失败后秒重试，都不叠加
    // 并发 matchOne（叠加 = 配额翻倍 + 所有匹配一起被限流拖慢）。
    final inflight = _inflightMatches[id];
    if (inflight != null) return inflight;

    _onDemandMatchTitle = song.title;
    notifyListeners();
    final future = _matchAndActivate(song, id, repo);
    _inflightMatches[id] = future;
    try {
      return await future;
    } finally {
      // 只清理仍指向自己这次的条目：晚到的 finally 不能删掉新一轮映射
      if (identical(_inflightMatches[id], future)) {
        _inflightMatches.remove(id);
      }
    }
  }

  /// [ensurePlayableSource] 的实体：匹配 → 过时校验 → 激活 → 回读 → 同步队列。
  Future<Song?> _matchAndActivate(
    Song song,
    int id,
    LibraryRepository repo,
  ) async {
    try {
      final r = await repo.matchOne(id);

      // ⚠️ matchOne 要跑几十秒，期间用户极可能已经点了别的歌。
      // 此时这次匹配的结果作废：不激活、不刷新曲库，把限流配额和
      // 播放链路让给最新点播目标。判据是「最新点播目标」（[_pendingPlayId]）
      // 而不是切歌代号——点 A → 点 B → 再点回 A 时 A 的匹配仍有效。
      // _pendingPlayId == null 只出现在测试直调的场景，放行。
      final pending = _pendingPlayId;
      if (!mounted || (pending != null && pending != id)) return null;

      if (!r.isBound) {
        // 点播兜底：没过 AUTO 阈值（0.82）但存在候选时，激活最高分候选。
        // 「用户点了想听」与「批量预处理」语境不同——静默失败比播一个
        // 可能不太对的版本更糟。批量匹配路径保持 AUTO-only（红线不动）。
        final activated = await repo.activateBestCandidate(id);
        if (!activated) return null;
        // 告知用户这是自动挑选的版本，不满意可以去人工换
        unawaited(showToastLater('已自动选择最相似的音源，可在播放页「手动更换音源」调整'));
      }

      // 必须重新读库：matchOne 只写数据库，不会改内存里的对象。
      final fresh = (await repo.getSong(id))?.song;
      if (fresh == null || fresh.source == null) return null;

      // 就地把队列里的旧对象换成带音源的新对象。
      // 不做这一步会有两个可见故障：
      //   1. 播放页的音源徽标还是「无音源」，但歌其实已经能播
      //   2. 下一首自动续播时拿到的还是旧对象 → 又白等 20 秒重新匹配
      _replaceQueued(id, fresh);
      // 曲库列表与「已匹配」计数也要跟上。本地库查询，开销可忽略；
      // 这里 await（而不是 unawaited）是为了让调用方拿到的状态是自洽的。
      await refreshLibrary();
      return fresh;
    } catch (_) {
      // 匹配失败（含被风控 / 网络异常）不该让播放抛错，
      // 交给调用方统一展示「没有找到可播放的音源」。
      return null;
    } finally {
      if (mounted) {
        _onDemandMatchTitle = null;
        notifyListeners();
      }
    }
  }

  /// 把播放队列中 id 为 [songId] 的歌曲换成 [fresh]（**就地**替换）。
  ///
  /// ## 为什么不直接 `_queue = [..._library]`
  /// 队列代表**播放顺序**。整表重建会把「用户当前播到第几首」以及
  /// 「按专辑/歌单播」这类非曲库顺序的队列一起重置掉。
  /// 这里只换发生变化的那个元素，队列结构完全不动。
  void _replaceQueued(int songId, Song fresh) {
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == songId) {
        _queue[i] = fresh;
        return;
      }
    }
  }

  /// 按位置流的增量累计本次收听时长（毫秒）。
  ///
  /// ## 为什么要过滤大跳变
  /// 用户拖动进度条时 position 会瞬间跳几秒甚至几分钟。若直接累加差值，
  /// 一次拖动就能把一首 3 分钟的歌「听」成 300 次。
  /// 只接受 **0 < 增量 <= 2 秒** 的正常推进，其余视为 seek 或跳变。
  void _accumulateListened(Duration pos) {
    final songId = _listeningSongId;
    if (songId == null) return;

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
      unawaited(_writePlayRecord(songId, chunk));
    }
  }

  /// 结算当前这首歌的收听时长（切歌 / 暂停 / 退出时调）
  Future<void> _flushPlayRecord() async {
    final songId = _listeningSongId;
    if (songId == null) return;
    final ms = _listenedMs;
    _listenedMs = 0;
    // 完全没听（<1 秒）不记流水——那是误触或加载失败，记了会污染「最近播放」
    if (ms < 1000) return;
    await _writePlayRecord(songId, ms);
  }

  Future<void> _writePlayRecord(int songId, int ms) async {
    final repo = _repo;
    if (repo == null) return;
    try {
      await repo.recordPlay(songId, playedMs: ms);
    } catch (_) {
      // 统计失败不该影响播放，静默吞掉
    }
  }

  /// 手动结束本次收听并落库（暂停时调，让「最近播放」及时更新）
  Future<void> flushPlaybackStats() => _flushPlayRecord();

  /// 清除播放历史与统计，返回结果文案。
  ///
  /// 只动 `play_log` / `play_stat`，**不动曲库与收藏**——
  /// 用户想清的是「听歌痕迹」，不是自己的歌。
  Future<String> clearPlayHistory() async {
    final repo = _repo;
    if (repo == null) return '数据层未接入';
    try {
      await repo.clearPlayHistory();
      _topPlayed = const [];
      _recentlyPlayed = const [];
      notifyListeners();
      return '播放记录已清除';
    } catch (e) {
      return '清除失败：$e';
    }
  }

  void _setResolving(bool v) {
    if (_resolving == v) return;
    _resolving = v;    notifyListeners();
  }

  /// 从某个上下文列表点歌播放。
  ///
  /// ## 队列来源规则（产品红线，2026-09-30 确认）
  /// 队列永远 = 「用户点击时所在的那个上下文的全量列表」：
  /// - 歌手页点歌 → 队列 = 该歌手的歌曲列表（BrowseScreen.singer →
  ///   `fetchSingerSongs` 全量）
  /// - 榜单页点歌 → 队列 = 该榜单的歌曲列表（BrowseScreen.toplist）
  /// - 收藏 / 最近听点歌 → 队列 = 对应的完整列表（MineScreen._SongListPage
  ///   传入的 songs）
  /// - 在线列表（榜单/歌手/歌单/搜索在线/新歌推荐）走 [playOnline]，
  ///   入库后同样以整批列表为队列
  /// 禁止「队列取可视子集」的写法（如 take(5)）——上一首/下一首必须沿
  /// 上下文列表连续播放。列表内截断只允许出现在展示层。
  ///
  /// [source] 缺省时退化为整个曲库 [_library]（如全局状态条重试的场景）。
  void playSong(Song song, {List<Song>? source}) {
    final q = source ?? _library;
    final i = q.indexWhere((s) => s.key == song.key);
    _queue = [...q];
    _index = i >= 0 ? i : 0;
    _position = 0;
    _lyricLine = 0;
    _resumeSeekSec = null;
    _syncDuration();
    _startPlayback();
    _playCurrent();
    unawaited(persistSession());
    notifyListeners();
  }

  void playQueue(List<Song> list, int startIndex) {
    if (list.isEmpty) return;
    _queue = [...list];
    _index = startIndex.clamp(0, list.length - 1);
    _position = 0;
    _lyricLine = 0;
    _resumeSeekSec = null;
    _syncDuration();
    _startPlayback();
    _playCurrent();
    unawaited(persistSession());
    notifyListeners();
  }

  void jumpTo(int i) {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    _resetTrack();
    _startPlayback();
    notifyListeners();
  }

  void cycleMode() {
    _mode = PlayMode.values[(_mode.index + 1) % PlayMode.values.length];
    notifyListeners();
  }

  void seekTo(double fraction) {
    if (!fraction.isFinite) return;
    final target = (fraction.clamp(0.0, 1.0) * _duration).round();
    _position = target;
    _updateLyricLine();
    // 真实播放器：拖动时立即 seek。拖动过程会连续触发，
    // just_audio 内部会合并请求，不必自己防抖。
    _player?.seek(Duration(seconds: target));
    // 拖完就落盘：拖动后直接杀进程的话，恢复进度以落盘值为准
    unawaited(persistSession());
    notifyListeners();
  }

  /// 智能混入：收藏 + 库内随机
  void shufflePlay() {
    final pool = <Song>{
      ..._library.where(isLiked),
      ..._library.take(15),
    }.toList();
    if (pool.isEmpty) return;
    playQueue(pool, Random().nextInt(pool.length));
  }

  /// 切换收藏。
  ///
  /// ## 为什么是 async 且要 mounted 守卫
  /// 真实模式下要写库（`liked_song` 表）。写法上先**乐观更新内存、
  /// 再落库**——红心必须在手指抬起的瞬间就变，等磁盘 IO 会让点击发飘。
  /// 落库失败才回滚（极少见，但静默失败会让用户以为收藏了其实没有）。
  Future<void> toggleLike(Song s) async {
    final repo = _repo;
    final id = s.id;

    // 乐观更新
    final wasLiked = _likedKeys.contains(s.key);
    if (wasLiked) {
      _likedKeys.remove(s.key);
      if (id != null) _likedIds.remove(id);
    } else {
      _likedKeys.add(s.key);
      if (id != null) _likedIds.add(id);
    }
    notifyListeners();

    // mock 模式 / 歌还没有 id（导入中间态）→ 只改内存
    if (repo == null || id == null) return;

    try {
      final nowLiked = await repo.toggleLike(id);
      // 用数据库的真实结果校准（防止并发点击导致内存与库不一致）
      if (nowLiked == wasLiked) {
        // 库说状态没变 → 说明本地乐观更新算错了，回滚
        if (wasLiked) {
          _likedKeys.add(s.key);
          _likedIds.add(id);
        } else {
          _likedKeys.remove(s.key);
          _likedIds.remove(id);
        }
        if (mounted) notifyListeners();
      }
    } catch (_) {
      // 落库失败：回滚到操作前，否则用户以为收藏成功了
      if (wasLiked) {
        _likedKeys.add(s.key);
        _likedIds.add(id);
      } else {
        _likedKeys.remove(s.key);
        _likedIds.remove(id);
      }
      if (mounted) notifyListeners();
    }
  }

  // ---- 界面控制 ----
  void setTab(int i) {
    _tabIndex = i;
    // 持久化停留页：冷启动恢复到上次的 tab（不落盘 = 每次都回「音乐」页）
    unawaited(_settings?.setTabIndex(i));
    notifyListeners();
  }

  // ---- 浏览目录点歌即播 ----

  /// QQ音乐元数据 Provider（目录浏览用）。
  ///
  /// 暴露而不是在 AppState 里包一层：目录页是**只读视图**，
  /// 榜单 / 歌手 / 歌单各自的加载、翻页、重试状态互不相同，
  /// 塞进全局 AppState 只会把它撑爆。页面自己持有 Future 状态，
  /// AppState 只负责点歌之后的事（入库 → 队列 → 播放）。
  QQMusicProvider? get qq => _repo?.qq;

  /// 从目录列表（榜单 / 歌手歌曲 / 歌单）点歌播放。
  ///
  /// 链路：整批静默入库（拿到 id）→ playQueue → 既有按需匹配链路。
  /// 用户等的就是一首歌的时间，入库不发网络请求，不产生可感知延迟。
  ///
  /// [index] 是用户点的那首在 [items] 里的位置；入库去重后位置可能
  /// 前移（重复项被去掉），所以这里按 key 对齐而不是直接沿用 index：
  /// 找不到时（理论上不会）退化为从第一首开始播。
  Future<void> playOnline(List<OnlineSong> items, int index) async {
    final repo = _repo;
    if (repo == null || items.isEmpty) return;
    final targetKey = items[index.clamp(0, items.length - 1)].song.key;

    final songs = await repo.persistOnline(items);
    if (songs.isEmpty) return;

    // 曲库列表、统计数要跟上，否则「我的」页显示的还是旧数量，
    // 用户会以为入库没发生（真机上就出现了 3 首没变的情况）。
    unawaited(refreshLibrary());

    final start = songs.indexWhere((s) => s.key == targetKey);
    playQueue(songs, start < 0 ? 0 : start);
  }

  void openPlayer() {
    _playerOpen = true;
    _playerTab = 0;
    unawaited(_settings?.setPlayerOpen(true));
    notifyListeners();
  }

  void closePlayer() {
    _playerOpen = false;
    unawaited(_settings?.setPlayerOpen(false));
    notifyListeners();
  }

  void setPlayerTab(int t) {
    _playerTab = t;
    notifyListeners();
  }

  void openSearch() {
    _searchOpen = true;
    notifyListeners();
  }

  void closeSearch() {
    _searchOpen = false;
    _query = '';
    _onlineResults = const [];
    _onlineSearched = false;
    _onlineError = null;
    notifyListeners();
  }

  /// 搜索词只用于驱动「在线搜 QQ 音乐」。
  ///
  /// 曲库作为独立概念已删除（QQ 音乐元数据即曲库，音源在播放页匹配），
  /// 不再有本地库搜索：输入即想搜 QQ 音乐，回车才发请求。
  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  void commitSearch(String q) {
    if (q.trim().isEmpty) return;
    _history.remove(q);
    _history.insert(0, q);
    if (_history.length > 8) _history.removeLast();
    _query = q;
    notifyListeners();
    // 回车 = 明确意图，这时候才值得花一次远端请求。
    unawaited(searchOnline(q));
  }

  void clearHistory() {
    _history.clear();
    notifyListeners();
  }

  // ── 在线搜索（QQ音乐）──────────────────────────────────────

  /// 手动触发一次在线搜索。
  ///
  /// ## 为什么不跟着 [setQuery] 的防抖自动打
  /// 在线搜索是打远端接口（慢、限流，防抖失效会触发风控 -412）。
  /// 打字时只更新输入框，用户**明确按下搜索/回车**才打远端。
  Future<void> searchOnline([String? keyword]) async {
    final repo = _repo;
    final kw = (keyword ?? _query).trim();
    if (repo == null || kw.isEmpty) return;

    // 竞态防护：旧请求晚归不能覆盖新请求的结果
    final seq = ++_onlineSearchSeq;
    _onlineSearching = true;
    _onlineError = null;
    notifyListeners();

    try {
      final items = await repo.searchOnline(kw);
      if (seq != _onlineSearchSeq) return;
      _onlineResults = items;
      _onlineSearched = true;
    } catch (e) {
      if (seq != _onlineSearchSeq) return;
      _onlineResults = const [];
      _onlineSearched = true;
      _onlineError = '$e';
    } finally {
      // 只有没有更新搜索在途时才能收掉 searching 态——
      // 否则新一轮搜索的转圈会被旧请求的 finally 提前关掉
      if (seq == _onlineSearchSeq) {
        _onlineSearching = false;
        notifyListeners();
      }
    }
  }

  /// 把在线搜索选中的条目导入曲库。
  ///
  /// 导入后必须 [loadLibrary] 刷新——否则用户在「我的」页看到的曲库
  /// 还是旧的，会以为导入没生效。
  Future<String> importOnline(List<OnlineSong> items) async {
    final repo = _repo;
    if (repo == null) return '数据层未接入';
    if (items.isEmpty) return '没有选中的歌曲';

    _importing = true;
    _importMessage = '正在导入 ${items.length} 首…';
    notifyListeners();

    try {
      final n = await repo.importOnline(items);
      await loadLibrary();
      // 导入后这些歌已经从「在线」变成「在库」，刷新预览的 inLibrary 标记，
      // 让 UI 立刻把按钮切到「已在库中」，不用用户再搜一次
      _onlineResults = _onlineResults
          .map((e) => e.inLibrary
              ? e
              : OnlineSong(
                  song: e.song,
                  songMid: e.songMid,
                  albumMid: e.albumMid,
                  inLibrary: items.any((x) => x.songMid == e.songMid),
                ))
          .toList();

      // ⚠️ 提示语必须指向**最短路径**。
      // 点开任意一首就会按需匹配（约 20 秒/首），直接听才是对的。
      final msg = '已导入 $n 首，点开即自动匹配音源（约 20 秒/首）';
      _importMessage = msg;
      return _importMessage!;
    } catch (e) {
      _importMessage = '导入失败：$e';
      return _importMessage!;
    } finally {
      _importing = false;
      notifyListeners();
    }
  }

  /// 清空在线搜索结果（关闭搜索页 / 清空输入时）
  void clearOnlineResults() {
    if (_onlineResults.isEmpty && !_onlineSearched && _onlineError == null) {
      return;
    }
    _onlineResults = const [];
    _onlineSearched = false;
    _onlineError = null;
    notifyListeners();
  }

  void toggleTheme() {
    _themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    // 落盘：下次冷启动按这个模式起（不落盘 = 每次都回浅色）
    unawaited(_settings?.setThemeMode(_themeMode));
    notifyListeners();
  }

  void setSleepTimer(Duration? d) {
    _sleepTicker?.cancel();
    _sleepTimer = d;
    if (d != null) {
      _sleepTicker = Timer(d, () {
        _playing = false;
        _ticker?.cancel();
        _sleepTimer = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _sleepTicker?.cancel();
    _toastTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    // 注意：_player 不在这里 dispose。
    // 它由 main.dart 创建并持有，生命周期比 AppState 长
    // （系统回收界面后前台 Service 仍需继续播放）。
    super.dispose();
  }
}

/// 便捷访问
extension Fmt on int {
  String get mmss {
    final v = this < 0 ? 0 : this;
    final m = v ~/ 60;
    final s = v % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
