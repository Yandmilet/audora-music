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

import '../data/db/dao/local_audio_dao.dart';
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
import '../services/lyric/ttml_lyric_parser.dart';
import '../services/playback/audio_player_controller.dart';
import '../services/qqmusic/qqmusic_provider.dart';
import '../services/qqmusic/qqmusic_dto.dart';
import '../services/settings/settings_store.dart';
import 'bili_session.dart';
import 'download.dart';
import 'guess_for_you.dart';
import 'local_library.dart';
import 'music_dirs.dart';
import 'online_search.dart';
import 'play_stats.dart';

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

    /// 目录浏览专用的 QQMusicProvider（榜单 / 歌手 / 歌单 / 新歌榜）。
    /// 这些能力不在 MetadataProvider 接口里——未来换元数据源时可能根本没有「榜单」概念，
    /// 所以 AppState 直接持有原始 QQMusicProvider 实例，而不是从 LibraryRepository.metadata 拿。
    QQMusicProvider? qqCatalog,

    /// B站 Cookie 会话。传入后「扫码登录」拿到的 SESSDATA 可以立刻注入，
    /// 后续所有 B站请求立即用上登录态，不必重启应用。
    BiliCookieSession? biliSession,
  })  : _repo = repo,
        _player = player,
        _settings = settings,
        _qqCatalog = qqCatalog {
    _onlineQuality = _settings?.onlineQuality ?? QualityPreference.auto;
    _downloadQuality =
        _settings?.downloadQuality ?? QualityPreference.high;
    // 启动时把详细级偏好同步给日志内核（AppState 是设置的唯一出口）
    _diagVerbose = _settings?.diagVerbose ?? false;
    DiagLog.instance.setVerbose(_diagVerbose);

    // 子模块先于一切使用点构造（组合式拆分，见各自文件头）。
    _bili = BiliSessionBox(
      session: biliSession,
      settings: settings,
      onChange: _notifyIfMounted,
    );
    _stats = PlayStatsRecorder(repo: () => _repo);
    _search = OnlineSearchBox(
      catalog: () => _qqCatalog,
      repo: () => _repo,
      onImported: loadLibrary,
      onChange: _notifyIfMounted,
    );
    _guess = GuessForYouBox(
      catalog: () => _qqCatalog,
      topPlayed: () => _topPlayed,
      liked: () => _library.where(isLiked).toList(),
      recentlyPlayed: () => _recentlyPlayed,
      play: playOnline,
      onChange: _notifyIfMounted,
      // 与 next(shuffle) 共用一个随机源：省一次 Random() 构造，
      // 也让「打散推荐」和「随机下一首」在测试里可用同一个 seed 注入。
      rng: _rng,
    );
    _dirs = MusicDirsBox(
      settings: () => _settings,
      onChange: _notifyIfMounted,
    );
    _local = LocalLibraryBox(
      repo: () => _repo,
      // 扫描范围跟着「本地目录」这项设置走；没设就是全盘
      scanPathPrefix: () => _dirs.localScanPath,
      // 清单一有变化（扫描完 / 补到了线上身份）就把队列里本机歌的封面补齐。
      // 不在这里 notify 一次以上都不做：队列元素是点歌那一刻映射出来的快照，
      // 补全发生在之后，不回填就会出现「列表已有封面、播放页还在放渐变」。
      onChange: () {
        _syncQueueCoverWithLocalLibrary();
        _notifyIfMounted();
      },
    );
    _download = DownloadBox(
      repo: () => _repo,
      // 只把「解析一条可下流的地址」这一件事交给它，不把整个播放器递过去：
      // DownloadBox 因此能脱离音频后端单测（真的 controller 会起 2 秒
      // 周期的看门狗 Timer，单测里就是悬挂计时器）。
      resolve: (song, ceiling) async {
        final r = _player?.resolver;
        if (r == null) {
          return (url: null, qualityId: 0, mime: 'audio/mp4', error: '播放器未初始化');
        }
        final res = await r.resolveForDownload(song, ceiling: ceiling);
        return (
          url: res.ok ? res.url : null,
          qualityId: res.qualityId,
          mime: res.mimeType,
          error: res.ok ? null : (res.error ?? '拿不到下载地址'),
        );
      },
      // CDN 校验 Referer/UA，缺一个就是 403；由当前源适配器给
      streamHeaders: () => _player?.resolver?.sourceHeaders ?? const {},
      dirs: () => _dirs,
      downloadQuality: () => _downloadQuality,
      // 「已下载」的唯一真相就是下载清单，不另开一份索引
      downloaded: () => _local.downloadedTracks,
      reloadDownloaded: _local.load,
      onChange: _notifyIfMounted,
    );
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

  /// 目录浏览专用的 QQMusicProvider（榜单/歌手/歌单等 QQ 专属能力）。
  /// 与 [_repo.metadata] 分离——后者只负责 search/fetchDetail/fetchLyric，
  /// 目录浏览方法（fetchSingers/fetchPlaylists/fetchToplist*）不在 MetadataProvider 接口里。
  final QQMusicProvider? _qqCatalog;

  /// 本机偏好（音质等）。为 null 时用默认值，不读磁盘——单测不必
  /// 为了「不崩」去搭一套 SharedPreferences 假数据。
  final SettingsStore? _settings;

  // ---- 偏好设置 ----
  //
  // 音质偏好拆成两条独立上限（2026-10-11）：在线拉流看 [_onlineQuality]，
  // 落盘下载看 [_downloadQuality]。分开是因为代价不同——在线选高了只多花
  // 流量，下载选高了是把几十 MB 永久写进手机。
  QualityPreference _onlineQuality = QualityPreference.auto;
  QualityPreference _downloadQuality = QualityPreference.high;

  /// 在线音质上限。播放器拉流时按它挑音质。
  QualityPreference get onlineQuality => _onlineQuality;

  /// 在线音质上限的 B站音质 ID（0 = 不限制）
  int get qualityCeilingId => _onlineQuality.id;

  /// 下载音质上限。下载器（第二期）落盘时按它挑流；此处先只存偏好。
  QualityPreference get downloadQuality => _downloadQuality;

  /// 下载音质上限的 B站音质 ID（0 = 不限制）
  int get downloadQualityCeilingId => _downloadQuality.id;

  /// 改在线音质偏好：落盘 + 让**当前在播的这首**立刻按新上限重拉。
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
  Future<void> setOnlineQuality(QualityPreference q) async {
    if (_onlineQuality == q) return;
    _onlineQuality = q;
    // 必须先 notify：main.dart 的监听器据此把新值写进 Resolver，
    // 本次重拉与后续所有拉流都依赖这一步。
    notifyListeners();
    await _settings?.setOnlineQuality(q);

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
      final err = await p
          .playSong(song, forceRefresh: true)
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

  /// 改下载音质偏好：只落盘 + 通知 UI。
  ///
  /// 与在线档不同，这里**不碰正在播放的歌**：下载上限管的是「以后下载的
  /// 文件用什么码率」，跟当前这一次拉流无关，重拉只会白白打断收听。
  Future<void> setDownloadQuality(QualityPreference q) async {
    if (_downloadQuality == q) return;
    _downloadQuality = q;
    notifyListeners();
    await _settings?.setDownloadQuality(q);
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
  //
  // 实现拆在 state/bili_session.dart（P3 组合式拆分，**不是** part 文件）：
  // Cookie / 昵称头像 / nav 校验是一组自洽的登录态，只依赖 SettingsStore
  // 与 BiliCookieSession，不碰播放/曲库——这里只保留同名转发，
  // 让 UI 层与测试的 st.biliXxx 用法完全不变。

  late final BiliSessionBox _bili;

  /// 供扫码登录页复用同一个会话（登录成功后立刻生效）
  BiliCookieSession? get biliSession => _bili.session;

  /// true = 服务端明确说这个凭证已经不认了（详见 [BiliSessionBox.stale]）。
  bool get biliSessionStale => _bili.stale;
  bool get biliLoggedIn => _bili.loggedIn;
  String get biliUserName => _bili.userName;
  String get biliUserFace => _bili.userFace;

  /// 剩余天数；未登录返回 null
  int? get biliCookieDaysLeft => _bili.daysLeft;

  /// 已过提示有效期 → 界面催「重新扫码」（不强制登出：服务端可能仍认）
  bool get biliCookieExpired => _bili.expired;

  /// 距到期不足 7 天
  bool get biliCookieExpiringSoon => _bili.expiringSoon;

  /// 子模块状态变化的统一出口：dispose 之后静默忽略
  /// （等价于原 verify/apply 内联的 mounted 检查）。
  void _notifyIfMounted() {
    if (mounted) notifyListeners();
  }

  Future<void> verifyBiliSession() => _bili.verify();
  Future<void> applyBiliSession(String cookieHeader) =>
      _bili.apply(cookieHeader);
  Future<void> biliLogout() => _bili.logout();

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
  int _duration = 0;

  /// 播放位置（**毫秒**）的私有真值。
  ///
  /// 毫秒而不是秒：歌词校准有 ±50ms 档位，且 LRC 时间戳精确到 10ms，
  /// 秒级截断会让任何亚秒级微调失效（点 20 次 +50ms 才跨过一个秒边界）。
  int _positionMsRaw = 0;

  /// 当前播放位置（秒）。类内历史代码全部走秒口径，保留它避免逐处改。
  ///
  /// 写秒 = 写整秒毫秒（无播放器的模拟 ticker、切歌归零、续播等），
  /// 真实播放器的位置流走 [_positionMs] 毫秒口径。
  int get _position => _positionMsRaw ~/ 1000;

  set _position(int v) => _positionMs = v * 1000;

  /// 当前播放位置（毫秒）。**写位置与发 [posTick] 必须是同一个动作**：
  /// setter 统一发秒粒度通知（ValueNotifier 自带跨值去重，同秒内只通知一次）。
  int get _positionMs => _positionMsRaw;

  set _positionMs(int v) {
    if (_positionMsRaw == v) return;
    _positionMsRaw = v;
    _posSampleAtMs = _posClock.elapsedMilliseconds;
    posTick.value = v ~/ 1000;
  }

  /// 单调时钟（不受系统时间调整、NTP 校时影响）。
  final Stopwatch _posClock = Stopwatch()..start();

  /// [_positionMsRaw] 最后一次被赋值时的 [_posClock] 读数。
  int _posSampleAtMs = 0;

  /// 播放进度的**高频通知通道**（秒粒度）。
  ///
  /// ## 为什么不复用 [notifyListeners]（这是一处性能修复，别退回去）
  /// [notifyListeners] 最主要的订阅方是 `main.dart` 根部那个包住整个
  /// `MaterialApp` 的 `AnimatedBuilder`——它一响就是**整棵树重建**：
  /// `MaterialApp → Shell → IndexedStack → HomeScreen → TabBarView → 4 个目录 tab`。
  ///
  /// 而 `positionStream` 在播放中每秒推送多次（just_audio 约 200ms 一次）。
  /// 也就是说：**只要在放歌，整棵树每秒要重建好几次**。叠加刚改完的歌手库
  /// （100 行列表 + 每行网络头像）之后，真机表现就是用户反馈的
  /// 「UI 切换卡顿迟滞」——切 tab、滑列表都在跟进度重建抢帧
  /// （2026-09-30 定位并实测）。
  ///
  /// 进度本身是**纯局部状态**，消费方只有三处：
  ///   1. 播放页 `_ProgressBar`（时间文本 + 进度条 + 拖拽把手）
  ///   2. 播放页歌词列表（当前行高亮 + 自动滚动跟随）
  ///   3. 迷你播放条底部细进度条（Shell 内嵌条 / 次级页悬浮条）
  /// 让这三处各自 `ValueListenableBuilder` 订阅本通道，重建成本从
  /// 「整棵树」降到「几个小部件」。
  ///
  /// 曲目切换、播放/暂停、歌词文本替换等**低频**事件仍旧走
  /// [notifyListeners]，语义没有变化——本通道只管「秒数在走」。
  final ValueNotifier<int> posTick = ValueNotifier<int>(0);

  PlayMode _mode = PlayMode.sequential;
  Timer? _ticker;

  /// 全局随机源：next(shuffle) / 「猜你想听」的打散共用一个实例，避免每次
  /// new Random() 的轻量开销；next 还会主动排除当前 index，防止随机到同一首。
  final Random _rng = Random();

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
  // `_likedKeys` 只服务「没有 id 的歌」——mock 模式的演示歌、以及本机扫描
  //   出来但没入库的文件（见 [localEntryToSong]，那条 id 是 null）。
  //
  // ## 为什么红心按 id 判、不按 key（2026-10-11 修「收藏显示 1 首但列表空」）
  // 旧实现 `isLiked` 只查 key 集合，而 key 集合是**曲库窗口 ∩ 数据库**的产物：
  // `_library` 只装最近 500 行，在一首窗口外的歌（榜单点进来的、本机文件）
  // 上点心 → 计数 +1，可 `library.where(isLiked)` 里根本没有那首歌 →
  // 收藏页「暂无内容」。真机 2026-10-11 复现的就是这一对。
  // 现在计数、红心、列表三者**同源于数据库**，不再经过曲库窗口。
  // 歌被删时 liked 行随 CASCADE 一起走，也不会留下点不亮的孤儿计数。
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

  /// 在线搜索子模块（关键词 / 历史 / 四分类结果 / 竞态防护 / 导入进度）。
  /// 实现拆在 state/online_search.dart（P3 组合式拆分），这里只做同名转发。
  late final OnlineSearchBox _search;

  /// 「猜你想听」子模块（口味种子 → QQ 歌手热歌 + 榜单掺新 → 成队列起播）。
  /// 实现拆在 state/guess_for_you.dart，理由同上。
  late final GuessForYouBox _guess;

  /// 「歌曲目录」子模块（本地扫描范围 / 下载落点，两项都走 SAF 选择）。
  /// 实现拆在 state/music_dirs.dart——它有自己的失效语义（授权可能被动撤销）。
  late final MusicDirsBox _dirs;

  /// 本机音频清单（自带扫描 + app 下载）。实现在 state/local_library.dart。
  late final LocalLibraryBox _local;

  /// 播放页下载（解析下载地址 → 原生落盘 → 回推进度）。
  /// 实现在 state/download.dart。
  late final DownloadBox _download;

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
  String get query => _search.query;
  List<String> get history => List.unmodifiable(_search.history);
  Duration? get sleepTimer => _sleepTimer;

  /// 综合搜索结果（四分类聚合结构）。
  QQSearchResults get searchResults => _search.results;

  /// 在线搜索结果（歌曲 tab 用，带真实 songMid）。
  ///
  /// 从 [searchResults.songs] 转换为 OnlineSong——保留这个 getter 是为了
  /// 兼容既有代码路径。歌手 / 专辑 / 歌单分类请直接用
  /// `searchResults.singers` 等。
  List<OnlineSong> get onlineResults => _search.onlineResults;

  /// 在线搜索是否进行中
  bool get onlineSearching => _search.searching;

  /// 是否已经完成过一次在线搜索（用于区分「还没搜」和「搜了没结果」）
  bool get onlineSearched => _search.searched;

  /// 在线搜索的错误信息（网络 / 风控等），null 表示无错
  String? get onlineError => _search.error;

  /// 在线搜索是否可用：数据层未接入（单测/预览）时没有 QQ 接口，不可用
  bool get canSearchOnline => _repo != null;

  /// 这首歌当前是否显示红心。
  ///
  /// 有 id 一律按 id 判（数据库真相，覆盖「不在曲库窗口里」的歌）；
  /// 没 id 的（mock 演示歌 / 未入库的本机文件）才退回 `title|artist`。
  bool isLiked(Song s) => s.id != null
      ? _likedIds.contains(s.id)
      : _likedKeys.contains(s.key);
  double get progress =>
      _duration > 0 ? (_position / _duration).clamp(0.0, 1.0) : 0.0;

  /// 收藏数量 = **数据库里的收藏行数**，不是「当前曲库窗口里数得着的红心」。
  ///
  /// 两者不是一回事：曲库只加载最近 500 行（[loadLibrary]），收藏却可能
  /// 落在更早的歌上——按窗口数就会出现「列表页一首都没有、计数写着 1 首」。
  int get likedCount => usingMock ? _likedKeys.length : _likedIds.length;

  /// 收藏列表（按收藏时间倒序，最近在前），**现查数据库**。
  ///
  /// 与 [library] 无关：不受「最近 500 行」这个窗口限制。
  /// mock 模式（无数据层）退回内存里的演示歌，保证 UI 预览有内容。
  Future<List<Song>> likedSongsList({int limit = 500}) async {
    final repo = _repo;
    if (repo == null) return _library.where(isLiked).toList();
    try {
      return (await repo.likedSongs(limit: limit)).map((e) => e.song).toList();
    } catch (e) {
      _loadError = '收藏读取失败：$e';
      return const [];
    }
  }

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
    // ⚠️ 本方法会被多处 unawaited 调用（搜索导入回调、refreshLibrary、
    // confirmSource / rematchSong / bindManualSource / playOnline 等），
    // 期间 dispose 完全可能发生。下面 finally 的两处通知都判了 mounted，
    // 唯独这里漏了——必须同样挡住，否则「退出 app 时恰好在加载曲库」就崩。
    if (!mounted) return;
    notifyListeners();

    try {
      final items = await repo.listSongs(limit: 500);
      // ⚠️ 空库就是空库。**不要**回退 MockData——那会让用户以为已经导入了歌。
      _library = items.map((e) => e.song).toList();
      _loadState = LibraryLoadState.ready;

      // 同步收藏状态。收藏是持久化在 liked_song 表里的用户行为，
      // 不重新拉一次的话，重启 app 后红心会全部消失（看起来像「没存上」）。
      // ⚠️ 这里拿的是**全表** id，不按曲库窗口过滤：红心与计数都要覆盖
      // 「最近没导入进那 500 行窗口」的老收藏（见 [_likedIds] 的说明）。
      _likedIds.clear();
      _likedKeys.clear();
      _likedIds.addAll(await repo.likedIds());

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

      // 本机音频两份清单跟着曲库一起刷新：它们和曲库数字出现在同一批
      // 界面上（「我的」页的本地入口副标题），分两处加载会出现曲库新、
      // 本地条目旧。纯本地 SQLite 查询，不发任何请求。
      await _local.load();

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
          _playbackError = null; // 手动匹配成功 → 清除旧错误提示
          _pendingAlign = null; // 旧源时间轴上的半成品锚点作废
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
  ///  - **回填 Golden Dataset 反馈**：用户改选是对此前匹配快照的裁决——
  ///    选回快照 best 记 accept，选了别的记 reject（最有价值的负样本，
  ///    见 `MatchSampleDao.markUserChoice`）。
  Future<String> switchSource({
    required int songId,
    required String bvid,
  }) async {
    final repo = _repo;
    if (repo == null) return '数据层未接入';
    try {
      await repo.db.bindings.activate(songId, bvid);
      // 放在 activate 之后：绑定成功才回填反馈。DAO 内部静默失败，
      // 不影响换源主流程。
      await repo.db.matchSamples.markUserChoice(songId, bvid);
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
          _playbackError = null; // 换源成功 → 清除旧错误提示
          _pendingAlign = null; // 旧源时间轴上的半成品锚点作废
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
  String? get importMessage => _search.importMessage;

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
  void showToast(String msg) {
    // 防御：showToast 的调用点分散在多处 async 之后，调用方漏判 mounted
    // 时这里兜底，避免直接抛「used after being disposed」。
    if (!mounted) return;
    _toast = msg;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _toast = null;
      notifyListeners();
    });
  }

  bool get importing => _search.importing;

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

  /// 播放失败 / 音源失效的提示文案（UI 用顶部横幅展示）
  String? _playbackError;
  String? get playbackError => _playbackError;

  /// 仅用于测试：直接设置播放错误状态，模拟匹配失败 / 装载失败。
  @visibleForTesting
  set playbackError(String? value) => _playbackError = value;

  /// 仅用于测试：注入当前歌词（测试环境无 repo，歌词无法走网络加载）。
  @visibleForTesting
  set debugLyric(ParsedLyric lyric) {
    _lyric = lyric;
    _updateLyricLine();
  }

  /// 仅用于测试：直接设置播放位置（毫秒），模拟播放推进。
  @visibleForTesting
  set debugPositionMs(int ms) => _positionMs = ms;

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
  /// ## 为什么单独一个字段而不用 [OnlineSearchBox.importMessage]
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
  /// ## 两条来源，一个出口
  ///   - **AMLL TTML 命中**（约一半热门歌）：Apple Music 的真实逐字轴。
  ///     这份歌词**整体替换** LRC——行文本、行时间、字时间、译文是
  ///     自洽的一套，不能和 QQ 的 LRC 混拼（不同源，逐行对齐一错就是整句错位）。
  ///   - **只有 QQ 的逐行 LRC**：行级时间轴照常，字轴由 [applyWordTiming]
  ///     按字数均分推算，扫光仍能动，只是跟不上真实语速。
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
    _lyricWordSource = null;
    notifyListeners();

    try {
      final bundle = await repo.fetchLyric(
        song,
        // 本机歌（曲库里没有行 / 那行的 mid 是派生键）靠补到的 songMid 取词
        midFallback: _localSongMid(song),
      );
      final totalMs = song.duration * 1000;
      if (bundle == null) {
        _lyric = ParsedLyric.empty;
      } else {
        // ① 优先真实逐字轨
        ParsedLyric? parsed;
        if (bundle.hasWordTrack) {
          final ttml = parseTtmlLyric(bundle.wordLyric!);
          if (!ttml.isEmpty && ttml.hasWords) {
            parsed = ttml;
            _lyricWordSource = bundle.wordSource ?? 'amll';
          }
          // 解析不出可用字轴（站点改版 / 畸形文件）→ 静默回落到 LRC 轨
        }
        // ② 逐行 LRC + 译文
        parsed ??= attachTranslation(
            parseLrc(bundle.lrc), bundle.hasTranslation ? bundle.translation : null);
        // ③ 统一出口：给缺字轴的行补均分轴
        _lyric = applyWordTiming(parsed, totalDurationMs: totalMs);
      }
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

  /// 当前歌词的字轴来源：'amll'（真实逐字轴）/ null（均分推算或无字轴）。
  ///
  /// 只给歌词页的校准条展示。做成公开只读而不是塞进 ParsedLyric，
  /// 是因为它属于「这份数据从哪来」的运行时信息，与解析结果本身无关。
  String? _lyricWordSource;
  String? get lyricWordSource => _lyricWordSource;

  void _bindPlayer() {
    final p = _player;
    if (p == null) return;

    _posSub = p.positionStream.listen((d) {
      // 解析期间忽略位置事件：切歌 stop 的瞬间，just_audio 会把**上一首**
      // 的进度随 idle 平台装载广播回来，若照单全收，刚归零的进度条会被
      // 旧值覆盖（「停在上一首歌的时间」的直接来源）。此时的新歌进度
      // 只能是 0，等装载完成后位置流自然会恢复推送。
      if (_resolving) return;
      // 毫秒口径：歌词映射（mappedLyricMs）与 ±50ms 校准依赖亚秒精度。
      _positionMs = d.inMilliseconds;
      // 累计本次「实际听了多久」。用它而不是「点了多少次」来计播放次数——
      // 点开又秒切不该算听过（见 PlayStatsDao.countingThresholdMs）。
      _stats.accumulate(d);
      _updateLyricLine();
      // 进度打点（15 秒节流）：用户不暂停、直接划掉应用时没有任何
      // 回调机会，恢复进度只能靠最近一次落盘。SharedPreferences 写入
      // 是内存级操作 + 异步刷盘，15 秒一次的开销可忽略。
      // 恢复态续播未完成前不打点：装载初期的位置事件从 0 推进，
      // 会把快照里刚存的进度覆盖掉。
      if (_resumeSeekSec == null &&
          (_position - _lastPersistedPos).abs() >= 15) {
        unawaited(persistSession());
      }
      // ⚠️ 这里**故意不调 notifyListeners()**：位置在走是高频道事件，
      // 走全局通知会让整棵树每秒重建数次。进度相关的三处 UI 订阅
      // [posTick]（`_position` 的 setter 已随写随发），见该字段的说明。
      // 必须由本通道通知的低频事件（切歌 / 播放状态 / 歌词文本）在各自
      // 的代码路径上单独 notifyListeners()，与本行无关。
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

    // 通知栏/锁屏播放键在「handler 完全不记得当前歌」时（进程被杀后
    // 冷唤醒引擎）的兜底：委托给界面同一个 togglePlay——它的空源分支
    // 会走恢复态续播 / 失败态重播，与用户在应用里按播放完全同链路。
    p.onColdPlay = () => togglePlay();

    // 播放出错 → 大概率是 URL 过期，重解析一次（必要时自动重新匹配）
    p.onPlaybackError = (e) async {
      final song = current;
      if (song == null) return;
      final r = await p.resolver?.resolveAfterPlaybackError(song);
      // ⚠️ 上面的 resolve 会打网络 + 可能跑完整重匹配（数十秒），
      // 期间用户很可能已经把 app 退出了。这里必须挡一道，
      // 否则 notifyListeners() 抛「used after being disposed」。
      // 这是播放失败的**默认路径**（403 / URL 过期），最容易踩到。
      if (!mounted) return;
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

  /// 把播放器的真实播放位置（毫秒）映射到 **LRC 歌词时间轴空间**，
  /// 返回一个「应该用这个毫秒值去查歌词行」的 int。
  ///
  /// ## 为什么需要这层映射
  /// B站音源（MV/UP主上传）与 QQ音乐的歌曲时间轴不一定重合：
  /// - 官方 MV 有 3~15s 片头/片尾 → 真实音频整体平移
  /// - UP 主加速/减速过 → 两条时间轴斜率不同
  /// 直接把真实位置当 LRC 时间查，歌词会错位。
  ///
  /// ## 模型：一条直线 `lrcMs = realMs × slope + offsetMs`
  /// - **slope = 1.0（默认，纯平移）**：覆盖片头/片尾/尾奏——90% 的场景。
  ///   平移由自动片头预填（[_computeAutoLyricOffset]）或用户 ±按钮给出，
  ///   **一次校准全曲都准**，误差不会随播放位置累积。
  /// - **slope ≠ 1.0（两点校准）**：用户在歌曲两个位置各做一次
  ///   「本句对齐」（[alignLyricLine]），由两个锚点算出斜率，
  ///   覆盖 UP 主整曲变速。
  ///
  /// ## 为什么不再自动按 `lrcTail / realDuration` 缩放（旧实现的坑）
  /// 旧实现用「最后一行歌词时间 ÷ 视频总时长」做自动 scale：
  /// 最后一行唱词普遍早于音频结束（尾奏 10~20s），导致 scale 系统性偏小，
  /// 歌词在歌曲中段就偏几秒、越往后越偏；它与用户 offset 叠加后，
  /// 数学上只能对齐一个时间点——用户表现为「调完过一会又不匹配」。
  /// 自动 scale 只在「整曲均匀变速」下才正确，而那恰恰是少见场景，
  /// 且该场景现在由两点校准显式覆盖。
  /// 真实音频毫秒 → **LRC 时间空间**毫秒。
  ///
  /// 抽成方法而不是只留 `mappedLyricMs` getter：逐字扫光要拿「外推出来的
  /// 位置」去查字轴，必须和整行高亮走同一个映射。两处各写一遍
  /// `realMs * slope + offset` 迟早会漂移成「高亮在第二行、填充画在第一行」。
  int mappedLyricMsAt(int realMs) {
    final slope = current?.lyricSlope ?? 1.0;
    final userOffset = current?.lyricOffsetMs ?? 0;
    return (realMs * slope).round() + userOffset;
  }

  int get mappedLyricMs => mappedLyricMsAt(_positionMs);

  /// 逐字扫光用的「此刻在歌词时间轴的哪里」。
  ///
  /// ## 为什么要外推
  /// just_audio 的 `positionStream` 约 200ms 推一次，而扫光要 60fps
  /// （约 16ms 一帧）才看得出连续移动。为此加一条高频通知通道会直接
  /// 撞回 [posTick] 那条性能修复的注释——整棵树每秒重建好几次。
  ///
  /// 正确姿势是**只暴露锚点，让唯一要动的那一小块自己算**：
  ///   此刻位置 ≈ 上次推送的位置 + (单调时钟已走过的时间)
  /// 播放页歌词组件每帧调一次，代价是一次加法和一次乘法，
  /// 全程零 notifyListeners、零 ValueNotifier 写入。
  ///
  /// ## 为什么钳 1 秒
  /// 切后台、系统节流、播放器卡死时，`elapsed` 会一路涨而不伴随新的位置推送。
  /// 不设上限就会把歌词"空转"到末尾，用户切回来看到一句已经唱完的歌词。
  /// 钳在 1 秒内：短到不会明显跑偏，长到能覆盖 200ms 推送间隔的抖动。
  int karaokeLyricMs() {
    if (!_playing) return mappedLyricMs;
    final drift = _posClock.elapsedMilliseconds - _posSampleAtMs;
    if (drift <= 0) return mappedLyricMs;
    return mappedLyricMsAt(_positionMsRaw + (drift > 1000 ? 1000 : drift));
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
    final mapped = mappedLyricMs;
    var idx = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time.inMilliseconds <= mapped) {
        idx = i;
      } else {
        break;
      }
    }
    _lyricLine = idx.clamp(0, lines.length - 1);
  }

  // ── 歌词手动校准 ──────────────────────────────────────
  //
  // 模型：lrcMs = realMs × slope + offsetMs（见 mappedLyricMs）。
  // ±按钮改 offset（平移，覆盖片头/片尾/尾奏）；长按歌词行「本句对齐」
  // 做一次是平移、间隔较远做两次即可定出 slope（覆盖 UP 主整曲变速）。

  /// 两点校准中等待配对的第一个锚点（仅内存态，不持久化——校准是
  /// 十几秒内完成的连续动作；切歌 / 换源 / 手动平移都会令它作废）。
  ({int realMs, int lrcMs, int songId})? _pendingAlign;

  /// 是否有一个待配对的对齐锚点（歌词页校准条据此显示引导文案）。
  bool get lyricAlignPending => _pendingAlign != null;

  /// 两个锚点的最小间隔（毫秒）。间隔太近时，位置/时间戳的小误差会被
  /// 斜率放大到全曲，算出来的 slope 不可用。
  static const int alignMinGapMs = 20000;

  /// 斜率合理区间：正常变速很少超出 ±10%，放宽到 [0.5, 2.0] 仅为防误操作。
  static const double alignSlopeMin = 0.5;
  static const double alignSlopeMax = 2.0;

  /// 按 [deltaMs]（可正可负，通常 ±500）微调当前歌的歌词平移偏移。
  ///
  /// **语义**：正数 = 歌词整体后移（需要再推进一点播放位置才到这一句）；
  /// 负数 = 歌词整体前移。只改截距，slope 保持不变。
  ///
  /// 偏移写入数据库持久化，下次播放同一首歌自动生效。
  void adjustLyricOffset(int deltaMs) {
    final cur = current;
    if (cur == null || _index < 0) return;

    // 手动平移后，挂起的锚点基准已过时，作废重来
    _pendingAlign = null;
    _writeCalibration(cur, offsetMs: cur.lyricOffsetMs + deltaMs);
  }

  /// 把第 [lineIndex] 行歌词对准**当前播放位置**（长按歌词行触发）。
  ///
  /// - 第一次：立即按平移生效（沿用当前 slope 重算 offset），并挂起锚点；
  /// - 第二次：与首点间隔 ≥ [alignMinGapMs] 时由两点算出 slope 与 offset，
  ///   完成变速校准；太近 / 结果异常则保留第一次的平移，挂起锚点不清除，
  ///   用户可走到歌曲远处再试一次。
  ///
  /// 返回给用户看的提示文案；null 表示状态不允许（无歌 / 行号越界）。
  String? alignLyricLine(int lineIndex) {
    final cur = current;
    if (cur == null || cur.id == null || _index < 0) return null;
    final lines = lyrics;
    if (lineIndex < 0 || lineIndex >= lines.length) return null;

    final realNow = _positionMs;
    final lrcNow = lines[lineIndex].time.inMilliseconds;
    final pending = _pendingAlign;

    if (pending == null || pending.songId != cur.id) {
      // 第一次：保留 slope，只重算截距 → 平移立即生效
      final newOffset = lrcNow - (realNow * cur.lyricSlope).round();
      _writeCalibration(cur, offsetMs: newOffset);
      _pendingAlign = (realMs: realNow, lrcMs: lrcNow, songId: cur.id!);
      return '已把这句对准当前位置';
    }

    // 第二次：两点定斜率
    final dReal = realNow - pending.realMs;
    if (dReal.abs() < alignMinGapMs) {
      return '两个对齐点太近，请在间隔 20 秒以上的位置再对准一次';
    }
    final slope = (lrcNow - pending.lrcMs) / dReal;
    if (slope < alignSlopeMin || slope > alignSlopeMax) {
      return '校准结果异常（速度差过大），已保留第一次的对齐';
    }
    final newOffset = pending.lrcMs - (pending.realMs * slope).round();
    _writeCalibration(cur, offsetMs: newOffset, slope: slope);
    _pendingAlign = null;
    final pct = (slope - 1.0) * 100;
    final pctText = pct.abs() < 0.5
        ? ''
        : '（速度差 ${pct > 0 ? '+' : ''}${pct.toStringAsFixed(1)}%）';
    return '两点校准完成$pctText';
  }

  /// 统一的校准写入：更新队列引用 + 落库 + 刷新歌词行 + 通知 UI。
  void _writeCalibration(Song cur, {required int offsetMs, double? slope}) {
    _queue[_index] = cur.copyWith(
      lyricOffsetMs: offsetMs,
      lyricSlope: slope ?? cur.lyricSlope,
    );

    final repo = _repo;
    final id = cur.id;
    if (repo != null && id != null) {
      unawaited(
        repo.db.songs.updateLyricCalibration(
          id,
          offsetMs: offsetMs,
          slope: slope,
        ),
      );
    }

    _updateLyricLine();
    notifyListeners();
  }

  /// 重置当前歌的歌词校准：平移归零、斜率恢复 1.0、丢弃挂起锚点。
  void resetLyricOffset() {
    final cur = current;
    if (cur == null) return;
    if (cur.lyricOffsetMs == 0 &&
        cur.lyricSlope == 1.0 &&
        _pendingAlign == null) {
      return;
    }

    _pendingAlign = null;
    _writeCalibration(cur, offsetMs: 0, slope: 1.0);
  }

  /// 计算给定歌曲的"首次播放时自动预填歌词偏移量"。
  ///
  /// 返回 null 表示不需要预填（已有手动校准 / 时长差太小 / 没有音源）。
  /// 返回具体毫秒数时，是一个**负整数**——
  /// 视频比歌曲长（durationDelta > 0）说明有片头，歌词要整体后移（offset 为负）
  /// 才能让 mappedLyricMs 在片头期间返回 < 0（不高亮）、片头结束后才对齐。
  int? _computeAutoLyricOffset(Song song) {
    // 已经手动校准过了（平移非 0，或做过两点变速校准），尊重用户选择
    if (song.lyricOffsetMs != 0 || song.lyricSlope != 1.0) return null;
    final src = song.source;
    if (src == null) return null;
    final deltaSec = src.durationDelta;
    // 时长差 < 3s 属于正常的平台元数据粒度差异（QQ音乐给的是整秒，
    // B站视频时长精确到毫秒），不值得预填
    if (deltaSec.abs() < 3) return null;
    return -deltaSec * 1000;
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
    if (_playing) unawaited(_stats.flush());
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
        // `_position++` 走 setter，已同步发布 [posTick]。
        _position++;
        _updateLyricLine();
        // ⚠️ 这里**不要**加回 notifyListeners()。模拟计时器与真实播放器的
        // 位置流必须是同一口径（推进 = 只发秒级通道），否则测试里就再也
        // 复现不出「播放中整棵树被反复重建」这个真实缺陷——
        // 无播放器时恰好是测试唯一能驱动时间前进的路径。
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
      // 排除当前 index：随机播不应原地重播（除非队列只有 1 首）
      if (_queue.length == 1) {
        _index = 0;
      } else {
        var pick = _rng.nextInt(_queue.length - 1);
        if (pick >= _index) pick++;
        _index = pick;
      }
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
    // 切歌即清除上一首歌的错误提示——如果新歌也失败，_playResolved 会
    // 用新的错误覆盖；手动匹配成功后的播放不走这里，但在 bind/switch
    // 各自的成功路径里也会清。
    _playbackError = null;
    // 挂起的对齐锚点绑定旧歌/旧播放周期，切歌必须作废
    _pendingAlign = null;
    // 歌词与音源并行加载：歌词来自 QQ音乐，音源来自 B站，互不阻塞。
    // 先发歌词请求能盖住拉流的那几百毫秒，用户看到词比听到声音早一点，
    // 观感上比「先出声、过两秒才蹦出词」自然。
    unawaited(loadLyricForCurrent());

    // 切歌前先把上一首的收听时长结算掉，否则会丢一段。
    // ⚠️ 必须在 _stats.songId 被改掉**之前**调，所以放在最前面。
    unawaited(_stats.flush());

    final p = _player;
    var song = current;
    // 已下载的歌优先播本地文件（用户 2026-10-11 选的语义）：省流量、秒开，
    // 也躲开了 CDN 断流那一类毛病。判定是纯内存的（下载清单已在本地），
    // 不能在这里等一次数据库查询——那会让每次切歌都多一个 await。
    //
    // 换的是**队列里那一格**，不是临时变量：播放页、通知栏、音源详情面板
    // 都从 current 读，只换局部变量会出现「实际播文件、界面显示 B站源」。
    if (song != null && song.id != null) {
      final dl = _download.fileOf(song);
      if (dl != null && song.source?.sourceType != kLocalSourceType) {
        _replaceQueued(
          song.id!,
          song.copyWith(
            source: AudioSource.localFile(
              uri: dl.uri,
              qualityLabel: dl.qualityId == 0
                  ? '本地文件'
                  : '${audioQualityLabel(dl.qualityId)} · 本地',
              qualityId: dl.qualityId,
            ),
          ),
        );
        song = current;
      }
    }
    // 新歌开始，重置本次收听计数
    _stats.reset(song?.id);
    // 同步「最新点播目标」：ensurePlayableSource 的在途匹配靠它判断
    // 自己是否已被用户放弃（见字段注释）
    _pendingPlayId = song?.id;
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

    // —— 首次播放自动预填歌词 offset ——
    // 视频比歌曲长 N 秒（durationDelta > 0）= MV 有 N 秒片头，
    // 直接用 -durationDelta*1000 预填 userOffset，省掉用户几十次按钮点击。
    // 只在 offset==0 且 |delta|>3s 时做：已经手动校准过的不覆盖；
    // delta < 3s 属于正常平台差，不值得预填。
    final autoSeedMs = _computeAutoLyricOffset(target);
    if (autoSeedMs != null) {
      target = _queue[_index].copyWith(lyricOffsetMs: autoSeedMs);
      // 回写队列里的引用，确保后续 mappedLyricMs 读到新 offset
      _queue[_index] = target;
      final repo = _repo;
      final id = target.id;
      if (repo != null && id != null) {
        unawaited(
            repo.db.songs.updateLyricCalibration(id, offsetMs: autoSeedMs));
      }
      // 通知 UI 校准条显示新值（offset 从 0 变非 0）
      notifyListeners();
    }

    // 每曲音量：装载前先恢复该曲的记忆音量（见 _restoreTrackVolume 注释）。
    // 不参与 _playGen 竞态本身——它只动音量，晚到一次也只是多写一次 setVolume。
    await _restoreTrackVolume(target.id);
    if (!mounted || gen != _playGen) return;

    try {
      // 60s 兜底：resolve / setAudioSource 在极端弱网下可能长时间不返回，
      // 不能让 resolvingSource 的转圈无限期挂着（真机实测过「一直转圈」）。
      final err = await p.playSong(target).timeout(const Duration(seconds: 60));
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
        if (!activated) {
          // 「真没找到」的记账（引擎在无候选时已 warn，这里覆盖的是
          // 「有候选但激活失败」的 DB 层意外；debug 级，详细模式才可见）。
          DiagLog.instance.d(
            DiagCategory.match,
            '点播兜底失败：无可激活候选',
            {
              'event': 'ondemand_no_candidate',
              'songId': id,
              'song': song.title
            },
          );
          return null;
        }
        // 告知用户这是自动挑选的版本，不满意可以去人工换。
        // ⚠️ 上面 activateBestCandidate 是「网络 + 落库」的 await（点播首匹配
        // ≈20 秒），期间用户很可能已经退出。showToast 内部会 notifyListeners()
        // 并起 Timer，dispose 后调用直接抛「used after being disposed」。
        if (mounted) {
          unawaited(Future.microtask(
              () => showToast('已自动选择最相似的音源，可在播放页「手动更换音源」调整')));
        }
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
    } catch (e) {
      // 匹配失败（含被风控 / 网络异常）不该让播放抛错，
      // 交给调用方统一展示「没有找到可播放的音源」。
      // 引擎内部异常已由 MatchEngine 自己记录（'匹配过程异常'）；
      // 这里补的是匹配后处理（激活/回读/刷新）的异常盲区，并把
      // 「用户可见的失败结果」与引擎日志关联起来。
      DiagLog.instance.e(
        DiagCategory.match,
        '点播匹配失败：$e',
        {'event': 'ondemand_fail', 'songId': id, 'song': song.title},
      );
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

  /// 播放统计子模块（实现拆在 state/play_stats.dart，这里只做转发）。
  late final PlayStatsRecorder _stats;

  /// 手动结束本次收听并落库（暂停时调，让「最近播放」及时更新）
  Future<void> flushPlaybackStats() => _stats.flush();

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
    _resolving = v;
    notifyListeners();
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
    if (i < 0) {
      // source / _library 里没有这首歌（例如已被删除或在线歌单未入库）
      // —— 静默 fallback 到 index 0 会播错歌，直接 return。
      return;
    }
    _queue = [...q];
    _index = i;
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

  // ---- 猜你想听 ----
  //
  // 取代原「随便听一下」（`shufflePlay`：收藏 + 曲库前 15 首随机）。
  // 旧那套的问题是它只会回锅你库里已有的歌，听两周就永远是那十几首；
  // 新链路按口味去 QQ 音乐拿歌手热歌 + 榜单新歌，见 state/guess_for_you.dart。

  /// 推荐正在加载中（首页卡片据此转圈）。
  bool get guessing => _guess.busy;

  /// 组一批「猜你想听」并起播。返回 null = 已交给播放链路；
  /// 返回文案 = 失败原因，由调用方用 SnackBar 如实呈现（不做假数据兜底）。
  Future<String?> guessForYou() => _guess.run();

  // ---- 歌曲目录（本地扫描范围 / 下载落点）----
  //
  // 三项设置里的「目录」相关状态，实现与失效语义都在 state/music_dirs.dart，
  // 这里只做同名转发（与其它子模块一致）。

  /// 启动时核对已存目录的授权是否还在。main.dart 里 unawaited 调用。
  Future<void> restoreMusicDirs() => _dirs.restore();

  /// 最近一次核对/选择得到的提示（授权失效、提供方不支持持久化等）。
  String? get dirsNote => _dirs.note;

  String musicDirTrailing(MusicDirKind kind) => _dirs.trailingOf(kind);

  /// 这一项当前有没有值（UI 据此决定「直接去选」还是「先问换/清」）。
  bool musicDirSet(MusicDirKind kind) => _dirs.isSet(kind);

  String musicDirSubtitle(MusicDirKind kind) => _dirs.subtitleOf(kind);

  Future<String?> pickMusicDir(MusicDirKind kind) => _dirs.pick(kind);

  Future<String?> clearMusicDir(MusicDirKind kind) => _dirs.clear(kind);

  /// 下载落点当前是否真能用（第三阶段的下载按钮据此决定可否点击）。
  bool get downloadDirUsable => _dirs.downloadUsable;

  /// 本地扫描的路径前缀；null = 全盘。
  String? get localScanPath => _dirs.localScanPath;

  // ---- 本机音频（自带扫描 + app 下载）----
  //
  // 两份清单在产品上是两个入口，在数据上是同一张表的两个 kind。
  // 这里只转发，任何一处把两者合并展示都会破坏「两个目录隔开」的约定。

  List<LocalAudioEntry> get localTracks => _local.localTracks;
  List<LocalAudioEntry> get downloadedTracks => _local.downloadedTracks;
  int get localCount => _local.localCount;
  int get downloadCount => _local.downloadCount;
  bool get localScanning => _local.scanning;
  int get lastLocalScanAt => _local.lastScanAt;

  /// 读两份清单（不发网络请求）。曲库加载完成后调一次。
  Future<void> loadLocalLibrary() => _local.load();

  /// 本机/下载清单是否正在补全线上身份（封面与歌词共用这一条链路）。
  bool get localMetaSyncing => _local.metaSyncing;

  /// 后台补全本机清单的线上身份：换到了就有真实封面和歌词。
  ///
  /// 由「进入本机/下载列表」触发，**不阻塞界面**：分片打元数据源，每片
  /// 落库后刷一次清单，用户看到的是封面一首一首变真。已经在跑就直接返回，
  /// 反复进出页面不该叠出一串请求。
  /// 换不到身份的歌会写 `resolved_at` 冷却；断网时连续几首请求异常就收手，
  /// 剩下的下次进页面再试。
  Future<int> syncLocalMeta({int limit = 60}) =>
      _local.syncMissingMeta(limit: limit);

  /// 用本机清单换到的封面**就地补齐**队列里的本机歌。
  ///
  /// 只填 coverUrl / albumMid，而且只在原来为空时填：队列元素上还挂着
  /// `lyricOffsetMs` 这类运行时校准值，整体替换会把用户刚调好的歌词对齐冲掉
  /// （对比 [_syncQueueWithLibrary]，那条走曲库行，字段齐全所以能整换）。
  void _syncQueueCoverWithLocalLibrary() {
    if (_queue.isEmpty) return;
    for (var i = 0; i < _queue.length; i++) {
      final s = _queue[i];
      final src = s.source;
      if (src == null || src.sourceType != 'local') continue;
      final url = s.coverUrl;
      if (url != null && url.isNotEmpty) continue;
      final entry = _local.entryByUri(src.sourceKey);
      if (entry == null || entry.albumMid.isEmpty) continue;
      final fresh = localEntryToSong(entry);
      final cover = fresh.coverUrl;
      if (cover == null || cover.isEmpty) continue;
      _queue[i] = s.copyWith(coverUrl: cover, albumMid: fresh.albumMid);
    }
  }

  /// 本机歌补到的线上 songMid；非本机歌返回 null（它们走曲库行取 mid）。
  String? _localSongMid(Song song) {
    final src = song.source;
    if (src == null || src.sourceType != 'local') return null;
    return _local.songMidByUri(src.sourceKey);
  }

  /// 扫一次手机自带音频。返回 null = 正常；返回文案 = 需要告诉用户的事。
  Future<String?> scanLocalAudio() => _local.scan();

  /// 从「下载」清单里去掉一条记录（不动手机上的文件）。
  Future<void> forgetDownload(int id) => _local.forgetDownload(id);

  // ---- 播放页下载 ----
  //
  // 按钮的三态、在途任务、失败原因都由 DownloadBox 管（见其文件头）。

  /// 播放页那个按钮该显示成什么样。
  DownloadUi downloadUi(Song song) => _download.uiOf(song);

  /// 这首歌是否已经下载到本机。
  bool isDownloaded(Song song) => _download.isDownloaded(song);

  /// 开始下载当前这首歌。返回 null = 已受理；返回文案 = 没开始的原因。
  Future<String?> startDownload(Song song) => _download.start(song);

  /// 取消在途下载。
  Future<String?> cancelDownload() => _download.cancel();

  /// 移除已下载（删文件 + 删记录）。
  Future<String?> removeDownload(Song song) => _download.remove(song);

  /// 重试（失败态下按钮那句「重试」）。清掉失败标记后重新发起。
  Future<String?> retryDownload(Song song) async {
    await _download.resetFailed();
    return _download.start(song);
  }

  /// 从本机音频列表点歌播放。
  ///
  /// 队列仍然遵守「= 用户点击时所在上下文的全量列表」这条红线：整份
  /// [entries] 映射成 Song 后作为队列，沿列表顺序上下切。
  /// 本机文件不需要匹配音源，Song 直接带一个 [AudioSource.localFile]，
  /// 解析层见到 local 类型就用 uri，一次请求都不发。
  void playLocalTrack(
    LocalAudioEntry entry, {
    required List<LocalAudioEntry> source,
  }) {
    final songs = source.map(localEntryToSong).toList();
    // 按 uri 定位，不按 song.key（title|artist）：本机文件常见同名两版
    // （同一首歌的 128K 与 320K），按 key 找会播错那一版。
    final i = songs.indexWhere(
      (s) => s.source?.sourceKey == entry.uri,
    );
    playQueue(songs, i < 0 ? 0 : i);
    // 还没换到线上身份 → 单补这一首，不排在整批后面。补成功后清单回调
    // onChange 会把封面回填进队列；歌词必须在这里显式重取一次，因为
    // playQueue 里那次 loadLyricForCurrent 是带着空 mid 跑的（必然没词）。
    if (entry.songMid.isEmpty) {
      unawaited(_resolveMidForPlaying(entry));
    }
  }

  /// 给一条本机歌补线上身份，补到了且它还在播 → 重取歌词。
  Future<void> _resolveMidForPlaying(LocalAudioEntry entry) async {
    final ok = await _local.resolveOne(entry);
    if (!ok || !mounted) return;
    // 补全期间用户可能已经切歌，别把歌词刷到另一首上
    if (current?.source?.sourceKey != entry.uri) return;
    unawaited(loadLyricForCurrent(force: true));
  }

  /// 切换收藏。
  ///
  /// ## 为什么是 async 且要 mounted 守卫
  /// 真实模式下要写库（`liked_song` 表）。写法上先**乐观更新内存、
  /// 再落库**——红心必须在手指抬起的瞬间就变，等磁盘 IO 会让点击发飘。
  /// 落库失败才回滚（极少见，但静默失败会让用户以为收藏了其实没有）。
  ///
  /// ## 没有 song 行的歌不收（2026-10-11 决定）
  /// 本机扫描出来的文件在 `song` 表里没有行（id 为 null），收藏没有载体。
  /// 旧实现把这种红心塞进内存集合，于是「计数 +1、重启就掉、收藏列表里
  /// 又没有它」——一个只活在本次会话里的假收藏比明说不能收藏更糟。
  /// 现在如实给一句话，不动任何状态。
  Future<void> toggleLike(Song s) async {
    final repo = _repo;
    final id = s.id;

    if (repo != null && id == null) {
      showToast('「${s.title}」是本机文件，还没入库，暂时不能收藏');
      return;
    }

    // 乐观更新
    final wasLiked = isLiked(s);
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
  /// QQ音乐目录浏览 Provider（榜单 / 歌手 / 歌单 / 新歌榜）。
  /// 这些能力不在 MetadataProvider 接口里——未来换元数据源时可能根本没有「榜单」概念，
  /// 所以 AppState 直接持有原始 QQMusicProvider 实例（main.dart 注入 qqCatalog）。
  QQMusicProvider? get qq => _qqCatalog;

  /// 从目录列表（榜单 / 歌手歌曲 / 歌单）点歌播放。
  ///
  /// 链路：整批静默入库（拿到 id）→ playQueue → 既有按需匹配链路。
  /// 用户等的就是一首歌的时间，入库不发网络请求，不产生可感知延迟。
  ///
  /// [index] 是用户点的那首在 [items] 里的位置；入库去重后位置可能
  /// 前移（重复项被去掉），所以这里按 key 对齐而不是直接沿用 index：
  /// 找不到时（理论上不会）退化为从第一首开始播。
  ///
  /// 返回 false 表示「一条也没能走起来」（数据层未接入 / 入库全空），
  /// 调用方据此决定要不要给用户报错——「猜你想听」就是这么判断的。
  Future<bool> playOnline(List<OnlineSong> items, int index) async {
    final repo = _repo;
    if (repo == null || items.isEmpty) return false;
    final targetKey = items[index.clamp(0, items.length - 1)].song.key;

    final songs = await repo.persistOnline(items);
    if (songs.isEmpty) return false;

    // 曲库列表、统计数要跟上，否则「我的」页显示的还是旧数量，
    // 用户会以为入库没发生（真机上就出现了 3 首没变的情况）。
    unawaited(refreshLibrary());

    final start = songs.indexWhere((s) => s.key == targetKey);
    playQueue(songs, start < 0 ? 0 : start);
    return true;
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
    _search.resetOnClose();
    notifyListeners();
  }

  // ── 在线搜索（QQ音乐）──────────────────────────────────────
  //
  // 实现拆在 state/online_search.dart（P3 组合式拆分，**不是** part 文件）：
  // 关键词 / 历史 / 四分类结果 / 竞态防护 / 导入进度是一组自洽状态，
  // 只依赖 catalog（搜索接口）、repo（导入落库）与两个回调。
  // 这里保留同名转发，search_screen 的 st.query / st.searchResults 等用法不变。

  /// 搜索词只用于驱动「在线搜 QQ 音乐」。**不发全局通知**（性能修复）。
  /// 打字高频路径的完整设计说明见 [OnlineSearchBox.setQuery]。
  void setQuery(String q) => _search.setQuery(q);

  /// 回车确认：记历史 + 发一次远端请求（竞态防护见 [OnlineSearchBox.search]）。
  void commitSearch(String q) => _search.commit(q);

  void clearHistory() => _search.clearHistory();

  /// 手动触发一次在线搜索（四分类综合搜索）。
  Future<void> searchOnline([String? keyword]) => _search.search(keyword);

  /// 把在线搜索选中的条目导入曲库（导入后内部回调 loadLibrary 刷新）。
  Future<String> importOnline(List<OnlineSong> items) =>
      _search.importSelected(items);

  /// 清空在线搜索结果（关闭搜索页 / 清空输入时）
  void clearOnlineResults() => _search.clearResults();

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
        // ⚠️ 这里**必须**真正暂停播放器，不能只翻 _playing 标志位。
        // 之前只写 `_playing = false`，真机上音频会一直放到自然结束，
        // 而界面却显示成暂停态：playingStream 是**变更流**，只在状态变化时
        // 补发，自此不再回调 true → `_playing` 与 just_audio 永久失步，
        // 播放按钮再也按不动（只能去通知栏停）。顺带把播放时长结掉，
        // 否则这一段在「最近播放 / 常听」里要等到切歌才入账。
        if (_playing) unawaited(_stats.flush());
        _playing = false;
        _ticker?.cancel();
        unawaited(_player?.pause() ?? Future<void>.value());
        _sleepTimer = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 注销原生进度回调：留着它，下一次 attach 的下载会把进度推给
    // 这个已死的 AppState，在 super.dispose 之后 notifyListeners 必崩。
    _download.dispose();
    _ticker?.cancel();
    _sleepTicker?.cancel();
    _toastTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    posTick.dispose();
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
