import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'data/db/app_database.dart';
import 'data/repository/library_repository.dart';
import 'screens/api_self_check_page.dart';
import 'screens/home_screen.dart';
import 'screens/mine_screen.dart';
import 'screens/player_screen.dart';
import 'screens/search_screen.dart';
import 'services/bilibili/bili_api.dart';
import 'services/bilibili/bili_api_client.dart';
import 'services/diag/diag_log.dart';
import 'services/fx/audio_fx_service.dart';
import 'services/match/match_engine.dart';
import 'services/net/rate_limiter.dart';
import 'services/netease/netease_provider.dart';
import 'services/playback/audio_player_controller.dart';
import 'services/playback/source_resolver.dart';
import 'services/qqmusic/qqmusic_provider.dart';
import 'services/settings/settings_store.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 临时开关：true 时启动进入接口自检页（真机验证用）。
///
/// 接口层已完成真机验证（B站 Wbi/搜索/详情/拉流 + QQ音乐元数据全链路通过），
/// 故置回 false。需要复检时改 true 即可，自检页本身保留不删。
const bool kApiSelfCheckMode = false;

Future<void> main() async {
  // 数据库与网络初始化都需要 binding，必须先确保初始化完成
  WidgetsFlutterBinding.ensureInitialized();
  // Android 13+ 通知权限运行时申请。
  //
  // ## 为什么必须申请
  // audio_service 的前台 Service 不需要通知权限也能跑（播放照样进行），
  // 但通知栏 / 锁屏媒体卡片要 POST_NOTIFICATIONS 才能显示——
  // 没通知栏的话后台播放的体验就是"听到声音但切不了歌"，等于半残。
  //
  // ## 为什么用 unawaited
  // 申请是异步 IO，弹窗在 Activity resume 后才显示。阻塞启动等它
  // 完成会让冷启动多几百毫秒，期间整个 UI 是白的。fire-and-forget
  // 让首帧先出来，权限弹窗跟在后面——和原生 Android App 的体感一致。
  //
  // ## 为什么拒绝后不退出
  // 用户拒了也能后台播放（无通知栏而已）。退出反而强行剥夺功能。
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    unawaited(_ensureNotificationPermission());
  }

  // 诊断日志必须在 runApp **之前**就绪：崩溃钩子装上后随时可能被触发，
  // 那时若目录还没拿到，崩溃现场就写不下去了。
  await DiagLog.instance.init(dir: await _diagDir());
  _installErrorHandlers();

  runApp(const AudoraApp());
}

/// 诊断日志目录：优先 app 专属外部存储（用户在文件管理器里能看到，
/// 且不需要任何权限），拿不到就退回应用文档目录。
///
/// 失败一律返回 null —— 日志写不了不该让应用起不来，退化成「仅内存」即可。
Future<String?> _diagDir() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) return '${ext.path}/diag';
    final doc = await getApplicationDocumentsDirectory();
    return '${doc.path}/diag';
  } catch (_) {
    return null;
  }
}

/// 全局崩溃捕获。
///
/// ## 为什么两个钩子都要装
/// - [FlutterError.onError]：框架与 build / layout 期的错误（红屏那一路）
/// - [PlatformDispatcher.instance.onError]：其余**未捕获的异步异常**——
///   这才是 release 真机上最常见的崩溃源（`await` 之后的抛错、定时器回调）。
///   只装第一个等于漏掉一半。
///
/// ## 为什么 onError 返回 true
/// 返回 true 表示「已处理」，平台不再走默认行为（直接把异常抛给 zone 上层）。
/// 个人自用场景下，记录完毕继续跑比直接死掉有用得多——
/// 代价是错误被静默，所以必须靠日志页的「崩溃」筛选来兜住可见性。
void _installErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    DiagLog.instance.crash(
      details.exceptionAsString(),
      kind: 'flutter',
      error: details.exception,
      stack: details.stack,
      fields: {
        if (details.library != null) 'library': details.library!,
        'silent': details.silent,
      },
    );
    // 保留默认输出：debug 下是红屏，release 下打到系统日志
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    DiagLog.instance.crash(
      error.toString(),
      kind: 'async',
      error: error,
      stack: stack,
    );
    return true;
  };
}

/// 申请 Android 13+ 的 POST_NOTIFICATIONS。
///
/// 仅在 Android 平台调用，且只在用户尚未决定时弹窗（已永久拒绝则不再骚扰）。
/// 失败/被拒都静默——通知栏不可见但播放仍可用。
Future<void> _ensureNotificationPermission() async {
  try {
    final status = await Permission.notification.status;
    if (status.isGranted || status.isPermanentlyDenied) return;
    await Permission.notification.request();
  } catch (e) {
    // 申请失败不阻断启动。后台播放是核心功能，通知栏只是辅助。
    debugPrint('通知权限申请失败：$e');
  }
}

class AudoraApp extends StatefulWidget {
  const AudoraApp({super.key});

  @override
  State<AudoraApp> createState() => _AudoraAppState();
}

class _AudoraAppState extends State<AudoraApp> with WidgetsBindingObserver {
  AppState? _st;
  String? _bootError;

  /// 全局 ScaffoldMessengerKey。
  ///
  /// ## 为什么需要
  /// Shell 把全屏播放页 / 搜索页叠在 IndexedStack 之上，**它们各自的 ScaffoldMessenger
  /// 看到的最近 Scaffold 是 HomeScreen/MineScreen 那一层**——用它们的 messenger 弹
  /// SnackBar，提示会被全屏层挡住看不见。
  /// 把 messenger 注册到 MaterialApp 顶层，弹出来的 SnackBar 就能盖在所有层之上，
  /// 用于"右滑退出"的二次确认提示。
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// 根 Navigator 的 key（传给 MaterialApp，保留给需要的全局导航场景）。
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// 次级路由观察者：有页面压在 Shell 上时通知 [AppState.setSubPageOpen]，
  /// 驱动悬浮迷你条的出现/消失。
  late final _routeObserver = _SubRouteObserver((open) {
    _st?.setSubPageOpen(open);
  });

  @override
  void initState() {
    super.initState();
    // 生命周期监听：app 退到后台 / 被收回时落盘播放会话快照，
    // 保证冷启动能恢复到上次的界面与进度（见 AppState.restoreSession）。
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // paused = 退到后台 / Activity finish（含「再次右滑退出」的
    // SystemNavigator.pop）。inactive 不落盘：它只是电话打进来这类
    // 短暂中断，马上回前台，没必要多写一次盘。
    if (state == AppLifecycleState.paused) {
      unawaited(_st?.persistSession());
    }
  }

  /// 启动引导：起播放服务 → 开库 → 装配数据层 → 加载曲库。
  ///
  /// 用 async 而非在构造里同步做，是因为开库与查询都是 IO。
  /// 期间界面显示启动占位，避免闪一下 mock 数据再跳成真实数据。
  ///
  /// ## 装配顺序为什么是「播放器 → 仓库 → Resolver」
  /// Resolver 同时需要「拉流的 api」和「重匹配用的 repo」，而 repo 反过来
  /// 不依赖 Resolver，所以先建 repo；player 必须最先建，因为
  /// `AudioService.init` 会在 Android 上拉起前台 Service，
  /// 晚建会出现"前几秒播放没有通知栏"。
  Future<void> _boot() async {
    try {
      // audio_service 的前台 Service。必须在任何播放前完成初始化。
      // 用 AudioService.init 拿到的实例就是我们的 handler 本身。
      final player = await AudioService.init(
        builder: AudioPlayerController.new,
        config: const AudioServiceConfig(
          // ⚠️ 这个 id 用于在系统里标识媒体会话，**发布后不可更改**——
          // 改了会被系统当成一个全新的媒体应用，旧的通知栏控制会失效。
          androidNotificationChannelId: 'com.audora.audora2.audio',
          androidNotificationChannelName: 'Audora 播放',
          // 播放中通知设为 ongoing（不可下滑划掉）：划掉通知会触发
          // onNotificationDeleted → stop()，等于把后台播放连同控制入口
          // 一起毁掉。暂停态下 audio_service 自动放开 ongoing，用户
          // 听完不想听了可以从通知栏划掉来停止播放。
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      player.bind();

      final db = await AppDatabase.open();
      final settings = await SettingsStore.open();

      // 音效偏好恢复：效果实例在 AudioPlayer 构造时已随 pipeline 注入
      // （AudioFxService 单例），这里只补「上次会话的参数」。
      // apply 不必等 player 激活：platform 未就绪时 just_audio 会暂存
      // 参数，激活时统一下发（服务内部已 try/catch，失败不阻断启动）。
      await AudioFxService.instance.load(settings);
      unawaited(AudioFxService.instance.apply());

      // 三个服务共用一个限流器：B站接口有频率限制，
      // 分开实例会导致「匹配」和「拉流」各算各的额度，实际超限仍被 -412。
      final limiter = RateLimiter(maxRequests: 30, window: const Duration(minutes: 1));
      final client = BiliApiClient(rateLimiter: limiter);
      final api = BiliApi(client);

      // 预热 B站会话：匿名指纹 Cookie（TTL 1h）+ Wbi 签名密钥（TTL 10min）。
      // 不预热的话，首次搜索/匹配要**串行**多打 fingerprint + nav 两个前置
      // 请求（约 1~2s），表现为「进 app 后第一次搜索特别慢」。
      // 后台异步预热，失败也无妨（Cookie 有伪指纹兜底；key 缺了下次现取）。
      // 这两个接口走 session 的裸 dio，不占 30 次/分钟的限流额度。
      unawaited(() async {
        try {
          await client.session.effectiveCookies();
          await client.session.fetchWbiKeys();
        } catch (_) {
          // 预热失败无害：指纹有伪指纹兜底；key 缺失时由首次签名请求现取
        }
      }());

      final repo = LibraryRepository(
        db: db,
        engine: MatchEngine(api, rateLimiter: limiter),
        qq: QQMusicProvider(),
        // 仅用于补非华语歌的中文译文，拿不到就降级成只有原文
        netease: NeteaseProvider(),
      );

      // Resolver 需要 repo（失效时自动重匹配），repo 不依赖 Resolver，
      // 所以这里手动补上引用，避免构造顺序上的循环依赖。
      //
      // ⚠️ 音质偏好在拉流那一刻才生效，所以每次「拉流」都要读当时的设置。
      // 这里传的是启动时的快照 + 一个 getter，设置改了无需重建 Resolver。
      player.resolver = SourceResolver(
        videos: db.videos,
        api: api.fetchAudioStream,
        repo: repo,
        // -400「请求错误」自愈：video 行 cid 坏了时用详情接口修一次
        // （搜索接口不返回 cid，绕过详情落库的绑定每播必挂，真机已确诊）
        repairCid: repo.refreshSourceCid,
        qualityCeiling: settings.quality.id,
      );

      final st = AppState(
        repo: repo,
        player: player,
        settings: settings,
        // 扫码登录拿到的 SESSDATA 直接注入这个会话，无需重启应用
        biliSession: client.session,
      );
      // 设置变更后让 Resolver 跟上（偏好是「下次拉流生效」，不打断正在播的）
      st.addListener(() {
        player.resolver?.qualityCeiling = st.qualityCeilingId;
      });
      await st.loadLibrary();
      // 会话恢复：曲库就绪后按上次的歌 key 在队列里找回播放位置。
      // 主题 / tab 的恢复在 AppState 构造里已完成（不依赖曲库）。
      await st.restoreSession();

      if (!mounted) return;
      setState(() => _st = st);

      // 后台校验本地凭证是否还被服务端认账（不影响启动速度，
      // 只为让「已登录」这个状态可信——否则界面说登录着，实际一直在降质）
      unawaited(st.verifyBiliSession());
    } catch (e) {
      if (!mounted) return;
      setState(() => _bootError = '$e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _st?.dispose();
    // 播放器由 AudioService 托管，其生命周期与前台 Service 绑定，
    // 这里不主动 dispose —— 否则从最近任务划掉应用时会立即停止播放，
    // 而后台播放的意义恰恰是"划掉界面还继续放"。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kApiSelfCheckMode) {
      final st = _st ?? AppState();
      return MaterialApp(
        title: 'Audora 接口自检',
        debugShowCheckedModeBanner: false,
        themeMode: st.themeMode,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: const ApiSelfCheckPage(),
      );
    }

    // 启动期：数据库还没就绪
    if (_bootError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        home: _BootError(message: _bootError!),
      );
    }
    final st = _st;
    if (st == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        home: const _BootSplash(),
      );
    }

    return AnimatedBuilder(
      animation: st,
      builder: (context, _) {
        return MaterialApp(
          title: 'Audora',
          debugShowCheckedModeBanner: false,
          themeMode: st.themeMode,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          scaffoldMessengerKey: _messengerKey,
          navigatorKey: _navigatorKey,
          navigatorObservers: [_routeObserver],
          home: Shell(st: st, messengerKey: _messengerKey),
          // 悬浮迷你播放条：包在 Navigator **外层**，所以能盖住所有 push
          // 出来的次级页面（Shell 内嵌条会被路由盖住，这正是真机反馈的问题）。
          //
          // 只在次级页面 / 搜索页出现：一级 tab 页用 Shell 内嵌条
          // （在 tab 栏上方，位置不变）。播放页全屏打开时两个条都隐藏。
          builder: (context, child) {
            final song = st.current;
            // fit: expand 保证 Navigator 铺满全屏（Stack 默认 loose，
            // 路由内容可能被收缩到自身首选尺寸）。
            return Stack(
              fit: StackFit.expand,
              children: [
                if (child != null) child,
                // 全屏播放页打开时（含其上的弹层）一律隐藏悬浮迷你条：
                // 播放页自己有完整控制区，迷你条只会挡内容。
                if (song != null &&
                    !st.playerOpen &&
                    (st.subPageOpen || st.searchOpen))
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      child: MiniPlayer(
                          song: song,
                          playing: st.playing,
                          progress: st.progress,
                          onToggle: st.togglePlay,
                          onNext: st.next,
                          // 播放页是根 Navigator 上的路由（见 _PlayerRouteSync），
                          // 直接压在当前页面之上即可——**绝不能 popUntil 清路由栈**，
                          // 否则榜单/歌单等次级页会被销毁，关闭播放页后回不去
                          // （真机实测「返回固定在歌手库」的根因）。
                          onTap: st.openPlayer,
                        ),
                      ),
                    ),
              ],
            );
          },
        );
      },
    );
  }

  ThemeData _buildTheme(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: Tokens.brand,
      brightness: b,
    ).copyWith(
      surface: dark ? Tokens.surfaceDark : Tokens.surface,
      onSurface: dark ? const Color(0xFFEDF0F5) : const Color(0xFF1C2230),
      onSurfaceVariant: dark ? const Color(0xFF9AA4B2) : const Color(0xFF6B7280),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: dark ? Tokens.lineDark : Tokens.line,
    );
  }
}

/// 启动占位（数据库打开期间）
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Tokens.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Audora',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: Tokens.brand,
              ),
            ),
            SizedBox(height: 18),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          ],
        ),
      ),
    );
  }
}

/// 启动失败兜底（数据库损坏 / 权限问题等）
class _BootError extends StatelessWidget {
  final String message;
  const _BootError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Tokens.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44),
              const SizedBox(height: 14),
              const Text(
                '初始化失败',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 应用外壳：底部 tab + 迷你播放条 + 全屏播放页 + 搜索页
class Shell extends StatefulWidget {
  final AppState st;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  const Shell({
    super.key,
    required this.st,
    required this.messengerKey,
  });

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  AppState get st => widget.st;

  /// 上次「再滑退出」提示的时间（系统返回路径的二次确认计时）。
  /// 与 ExitConfirm 的窗口逻辑一致，但两者各自独立计时——
  /// 系统返回与页内右滑是两条不同的触发路径，混用一个计时器
  /// 反而会出现「页内滑一下 + 系统返回一下就退出」的怪异组合。
  DateTime? _lastExitHint;

  /// 「再次右滑退出」的二次确认提示。
  ///
  /// 用 SnackBar 而不是 Toast：
  ///   - SnackBar 自带滑动关闭、与 Material 风格一致
  ///   - 通过全局 messengerKey 弹出，能盖在所有叠加层之上
  /// 时长 1.4 秒——比 [ExitConfirm.window] 短一点点，给用户预留提前量。
  void _onExitHint() {
    final m = widget.messengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      const SnackBar(
        content: Text('再次右滑退出 Audora'),
        duration: Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _confirmExit() => SystemNavigator.pop();

  /// 系统返回手势/返回键（PopScope 拦截）。
  ///
  /// ## 为什么必须有这个
  /// 屏幕左缘的右滑是 Android 系统返回手势，不经过我们的 SwipeBack，
  /// 直接走 Navigator.maybePop。根路由（本 Shell）没有可弹的页面时，
  /// Flutter 默认调 [SystemNavigator.pop] —— App 整个退到桌面。所以必须在
  /// 根路由拦下返回事件，按层级分发：先关搜索页，最后才是两段式退出。
  ///
  /// 播放页已改为根 Navigator 上的路由（_PlayerRouteSync）：它是栈顶时，
  /// 系统返回先命中它自己的 PopScope（→ closePlayer），轮不到这里。
  /// playerOpen 分支仅作竞态兜底保留。
  /// 次级页面（榜单详情等）在栈顶时可正常 pop，同样不会到这里。
  Future<void> _onSystemBack(bool didPop) async {
    if (didPop) return;
    if (st.playerOpen) {
      st.closePlayer();
      return;
    }
    if (st.searchOpen) {
      st.closeSearch();
      return;
    }
    final now = DateTime.now();
    final last = _lastExitHint;
    if (last != null && now.difference(last) <= const Duration(seconds: 2)) {
      _lastExitHint = null;
      _confirmExit();
    } else {
      _lastExitHint = now;
      _onExitHint();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final song = st.current;

    // ExitConfirm（页内右滑的退出确认）只在主内容层武装：
    // 播放页 / 搜索页打开时必须禁用，那两层的右滑归各自的 SwipeBack 管。
    // —— enabled=false 时它完全不注册手势识别器，竞技场里没有它。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _onSystemBack(didPop),
      child: _PlayerRouteSync(
        st: st,
        child: Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      body: ExitConfirm(
        onFirstTrigger: _onExitHint,
        onConfirmExit: _confirmExit,
        enabled: !st.playerOpen && !st.searchOpen,
        child: Stack(
          children: [
            // 主内容
            Column(
              children: [
                Expanded(
                  child: SafeArea(
                    bottom: false,
                    child: IndexedStack(
                      index: st.tabIndex,
                      children: [
                        // 音乐页 = 目录浏览（歌手库/歌单/榜单/新歌）。
                        // 点歌即播（后台静默入库 + 按需匹配），没有导入入口。
                        HomeScreen(st: st),
                        MineScreen(st: st),
                      ],
                    ),
                  ),
                ),

                // 按需匹配的全局进度条（批量匹配已移除，匹配统一走播放页按需路径）。
                //
                // ## 为什么不能只放在「我的」页里
                // 匹配一首约 20 秒，用户点了播放往往就切到别的 tab 去干别的。
                // 进度只在一个页面里可见的话，切走就完全不知道还在不在跑
                // —— 这正是「感觉卡死」的来源。放在外壳层，任何 tab 都能看到。
                if (st.matchingOnDemand) MatchBanner(st: st),

                // 全局轻提示（播放失败 / 自动选源提示等）。
                // 必须放外壳层：用户在浏览列表点歌，不一定打开播放页，
                // 失败只写 playbackError 的话用户看到的是「点了没反应」。
                if (st.toast != null)
                  Material(
                    color: dark ? Tokens.surface2Dark : Tokens.surface2,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 15,
                              color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              st.toast!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: t.colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 迷你播放条
                if (song != null)
                  MiniPlayer(
                    song: song,
                    playing: st.playing,
                    progress: st.progress,
                    onToggle: st.togglePlay,
                    onNext: st.next,
                    onTap: st.openPlayer,
                  ),

                // 底部 tab
                SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    color: dark ? Tokens.surfaceDark : Tokens.surface,
                    child: Row(
                      children: [
                        _TabItem(
                          icon: Icons.library_music_outlined,
                          activeIcon: Icons.library_music_rounded,
                          label: '音乐',
                          active: st.tabIndex == 0,
                          onTap: () => st.setTab(0),
                        ),
                        _TabItem(
                          icon: Icons.person_outline_rounded,
                          activeIcon: Icons.person_rounded,
                          label: '我的',
                          active: st.tabIndex == 1,
                          onTap: () => st.setTab(1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // 搜索页（右滑入）。右滑关闭。
            // 播放页**不在**这一层——它已改为根 Navigator 上的路由（见
            // _PlayerRouteSync），压在搜索页/次级页面之上，关闭即逐级返回，
            // 不会像旧实现那样需要清空路由栈导致「返回回不到榜单详情」。
            AnimatedSlide(
              offset: st.searchOpen ? Offset.zero : const Offset(1, 0),
              duration: Tokens.dur,
              curve: Curves.easeOutCubic,
              child: st.searchOpen
                  ? SwipeBack(onBack: st.closeSearch, child: SearchScreen(st: st))
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// 播放页路由同步器：把 [AppState.playerOpen] 状态翻译成根 Navigator 的
/// push / pop。这是「状态 → 路由」的唯一桥梁。
///
/// ## 为什么播放页必须是路由而不是 Shell 里的 AnimatedSlide
/// 旧实现把播放页画在 Shell 内部，而榜单/歌单/歌手详情是压在根 Navigator
/// 上的路由——播放页永远被次级页面盖住，次级页面里打开播放页只能
/// `popUntil(isFirst)` 清空路由栈，**榜单详情页因此被销毁**：关闭播放页
/// 后回到的是音乐首页一级视图，而不是之前浏览的列表（真机实测的
/// 「返回固定在歌手库」）。改为路由后，播放页压在当前页面之上，
/// 关闭即逐级返回，路由栈与页面滚动位置原样保留。
///
/// ## 为什么仍保留 playerOpen 状态
/// 会话恢复（lastPlayerOpen，冷启动直接落在播放页）需要它；
/// 悬浮迷你条 / ExitConfirm / _onSystemBack 的门控也读它。
/// 两个方向的转换都在这里：
///   - openPlayer()（playerOpen true）→ push [_PlayerRoute]
///   - closePlayer()（playerOpen false）→ pop 该路由
/// 路由内部的返回路径（SwipeBack 右滑 / 系统返回 / 播放页关闭按钮）
/// 统一调 st.closePlayer()，由本同步器执行 pop，保证状态与路由永不脱节。
class _PlayerRouteSync extends StatefulWidget {
  final AppState st;
  final Widget child;

  const _PlayerRouteSync({required this.st, required this.child});

  @override
  State<_PlayerRouteSync> createState() => _PlayerRouteSyncState();
}

class _PlayerRouteSyncState extends State<_PlayerRouteSync> {
  Route<void>? _playerRoute;

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_sync);
    // 冷启动恢复：restoreSession 可能在首帧前已置 playerOpen=true，
    // 此时 Navigator 还没挂载，必须等首帧后再 push。
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    widget.st.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (widget.st.playerOpen && _playerRoute == null) {
      // push 前先登记，防止 notifyListeners 密集期间重复 push（连点迷你条）。
      _playerRoute = _PlayerRoute(widget.st);
      nav.push(_playerRoute!);
    } else if (!widget.st.playerOpen && _playerRoute != null) {
      final r = _playerRoute!;
      _playerRoute = null;
      // 播放页上面还压着弹层（音源面板 / 音质偏好等）时 isCurrent 为
      // false，pop 不到它——只能 removeRoute（无动画）。正常路径都是 pop。
      if (r.isCurrent) {
        nav.pop();
      } else {
        nav.removeRoute(r);
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 全屏播放页的路由形态：上滑入场 / 下滑退场，与旧 AnimatedSlide 手感一致。
///
/// PopScope 拦截系统返回但不直接 pop：统一走 st.closePlayer()，
/// 由 _PlayerRouteSync 执行 pop——否则路由弹了、状态还停在 playerOpen=true，
/// 迷你条 / 悬浮条的门控会全部错乱。
class _PlayerRoute extends PageRouteBuilder {
  _PlayerRoute(AppState st)
      : super(
          opaque: true,
          transitionDuration: Tokens.durSlow,
          reverseTransitionDuration: Tokens.durSlow,
          pageBuilder: (_, __, ___) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) st.closePlayer();
            },
            child: SwipeBack(
              onBack: st.closePlayer,
              child: PlayerScreen(st: st),
            ),
          ),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          ),
        );
}

/// 全局匹配状态条（所有 tab 都可见）。
///
/// 只服务**按需匹配**（首播一首还没匹配的歌）：一首、约 20 秒。
/// 必须全局可见——用户点了播放往往就切到别的 tab 了，没有反馈
/// 就只能看到「点了没反应」。
/// （原批量匹配状态已随「批量匹配音源」功能一起移除，匹配统一走播放页按需路径。）
class MatchBanner extends StatelessWidget {
  final AppState st;
  const MatchBanner({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Material(
      color: dark ? Tokens.surfaceDark : Tokens.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: null,
            minHeight: 2,
            backgroundColor: dark ? Tokens.lineDark : Tokens.line,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 6, 5),
            child: Row(
              children: [
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在匹配音源：${st.onDemandMatchTitle ?? ''}'
                        '（首次播放约需 20 秒）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = active ? Tokens.brand : t.colorScheme.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(active ? activeIcon : icon, size: 23, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 次级路由观察者：判断「是否有**整页**压在 Shell 之上」。
///
/// ## 为什么不能直接用 canPop()
/// `showModalBottomSheet`（音源详情、手动搜索、音质偏好等弹层）也会往
/// Navigator 压入 `ModalBottomSheetRoute`。若只看 canPop()，用户在一级页
/// 打开一个弹层就会被误判成「在次级页面」，悬浮迷你条会盖在弹层上——
/// 这正是真机反馈的两个问题（播放页弹层、音质偏好弹层被迷你条干扰）。
///
/// ## 修正：只数 PageRoute 深度
/// 只有 `PageRoute`（MaterialPageRoute 等整页跳转）才计入深度；
/// `PopupRoute` 家族（ModalBottomSheetRoute / DialogRoute）不算。
/// 这样：一级页上的弹层 → 深度 0，无迷你条；次级页上的弹层 → 深度仍 1，
/// 迷你条保留（整页上下文没变）。
class _SubRouteObserver extends NavigatorObserver {
  _SubRouteObserver(this._onChange);

  final void Function(bool subPageOpen) _onChange;

  int _pageDepth = 0;

  void _pushIfPage(Route? route) {
    if (route is PageRoute) _pageDepth++;
  }

  void _popIfPage(Route? route) {
    if (route is PageRoute && _pageDepth > 0) _pageDepth--;
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    // 初始路由（Shell）isFirst == true，不算「次级页面」；
    // 其余 PageRoute（含次级页再 push 的嵌套页）逐层计数。
    if (route is PageRoute && !route.isFirst) _pageDepth++;
    _report();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is PageRoute && !route.isFirst && _pageDepth > 0) _pageDepth--;
    _report();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (route is PageRoute && !route.isFirst && _pageDepth > 0) _pageDepth--;
    _report();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _popIfPage(oldRoute);
    _pushIfPage(newRoute);
    _report();
  }

  void _report() => _onChange(_pageDepth > 0);
}
