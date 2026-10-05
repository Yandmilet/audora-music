import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'data/db/app_database.dart';
import 'data/repository/library_repository.dart';
import 'screens/api_self_check_page.dart';
import 'services/bilibili/bili_api.dart';
import 'services/bilibili/bili_api_client.dart';
import 'services/diag/diag_log.dart';
import 'services/fx/audio_fx_service.dart';
import 'services/match/match_engine.dart';
import 'services/net/rate_limiter.dart';
import 'services/netease/netease_provider.dart';
import 'services/playback/audio_player_controller.dart';
import 'services/playback/source_resolver.dart';
import 'services/source/bili_audio_source_adapter.dart';
import 'services/metadata/qqmusic_metadata_adapter.dart';
import 'services/qqmusic/qqmusic_provider.dart';
import 'services/settings/settings_store.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'shell.dart';

// 应用外壳与路由基建在 shell.dart 实现；这里整体转出，
// 保证 test/ 里 `import 'package:audora2/main.dart'` 的用法不变。
export 'shell.dart';

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

  /// 主题按亮度缓存，只构建一次。
  ///
  /// ## 为什么不每次现算
  /// 根部包住 MaterialApp 的 AnimatedBuilder 在 AppState 每次
  /// notifyListeners()（71 处）时都会重建，_buildTheme 里是
  /// ColorScheme.fromSeed + ThemeData(...) 的真实构造开销——
  /// 之前等于每次状态变化都白跑两遍。
  /// 主题只依赖亮度（Tokens 全是编译期常量），与 AppState 无关，缓存零风险。
  ThemeData? _lightThemeCache;
  ThemeData? _darkThemeCache;

  ThemeData _themeFor(Brightness b) => b == Brightness.light
      ? (_lightThemeCache ??= _buildTheme(b))
      : (_darkThemeCache ??= _buildTheme(b));

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
  late final _routeObserver = SubRouteObserver((open) {
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
          androidNotificationChannelId: 'com.fly1pu.audoramusic.audio',
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

      // 适配器：让 BiliApi 实现 AudioSourceProvider 接口。
      // 未来换源时，这里换一个适配器实现即可（其他装配代码不动）。
      final biliAdapter = BiliAudioSourceAdapter(api);

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

      // QQMusicProvider 同时服务两条链路：
      //   1. LibraryRepository.metadata —— search / fetchDetail / fetchLyric（通过 Adapter）
      //   2. AppState.qq —— 目录浏览（fetchSingers / fetchPlaylists / fetchToplist*，不在接口里）
      final qqRaw = QQMusicProvider();
      final qqAdapter = QQMusicMetadataAdapter(qqRaw);

      final repo = LibraryRepository(
        db: db,
        engine: MatchEngine(biliAdapter, rateLimiter: limiter),
        metadata: qqAdapter,
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
        api: biliAdapter.fetchAudioStream,
        repo: repo,
        // CDN 拉流需要的请求头（B站要 Referer），由适配器提供
        sourceHeaders: biliAdapter.requiredHeaders,
        // -400「请求错误」自愈：video 行 cid 坏了时用详情接口修一次
        // （搜索接口不返回 cid，绕过详情落库的绑定每播必挂，真机已确诊）
        repairSourceSubKey: (sourceKey) async {
          final cid = await repo.refreshSourceCid(sourceKey);
          return cid?.toString();
        },
        qualityCeiling: settings.quality.id,
      );

      final st = AppState(
        repo: repo,
        player: player,
        settings: settings,
        qqCatalog: qqRaw,
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
        theme: _themeFor(Brightness.light),
        darkTheme: _themeFor(Brightness.dark),
        home: const ApiSelfCheckPage(),
      );
    }

    // 启动期：数据库还没就绪
    if (_bootError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _themeFor(Brightness.light),
        home: _BootError(message: _bootError!),
      );
    }
    final st = _st;
    if (st == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _themeFor(Brightness.light),
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
          theme: _themeFor(Brightness.light),
          darkTheme: _themeFor(Brightness.dark),
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
                      // 只订阅秒级进度通道：进度在走时重建范围限定在这条迷你条，
                      // 而不是整个 MaterialApp（见 [AppState.posTick]）。
                      child: ValueListenableBuilder<int>(
                        valueListenable: st.posTick,
                        builder: (_, __, ___) => MiniPlayer(
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