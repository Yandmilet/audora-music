/// 播放器控制器 —— 全应用唯一的音频出口。
///
/// ## 为什么它同时是 `BaseAudioHandler`
/// `audio_service` 要求后台播放必须由一个 `BaseAudioHandler` 子类驱动：
/// 它跑在**独立的 Isolate / 前台 Service**里，负责通知栏、锁屏、
/// 耳机线控，并在系统回收界面后继续持有播放状态。
///
/// 把「just_audio 的播放控制」和「audio_service 的媒体会话」写成一个类
/// 而不是两个，是因为它们共享同一份状态：如果拆开，任何一次
/// `play()` 都要手动同步两边的 `playing` 标记，漏一处就会出现
/// 「界面显示在播、通知栏显示暂停」这类难复现的错位。
///
/// ## 对外接口
/// UI 侧只碰这几个方法/流：`playSong` / `togglePlay` / `next` / `previous`
/// / `seek` / `positionStream` / `durationStream` / `playingStream`。
/// just_audio 与 audio_service 的细节全部封在内部。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
// ⚠️ just_audio 里也有个 `AudioSource`（流描述），与本项目的领域模型
// `models.dart` 的 `AudioSource`（B站音源）同名。用前缀 `ja.` 引用，
// 避免在这一层读代码时把两者看混。
import 'package:just_audio/just_audio.dart' as ja;

import '../../models/models.dart';
import '../diag/diag_log.dart';
import '../fx/audio_fx_service.dart';
import '../playback/source_resolver.dart';

/// 播放结束 / 出错时的回调，由 AppState 注入（避免本类反向依赖 AppState）
typedef OnTrackEnded = Future<void> Function();
typedef OnPlaybackError = Future<void> Function(Object error);

/// 通知栏 / 锁屏展示的元数据
MediaItem _toMediaItem(Song song) => MediaItem(
      // 用 key（title|artist）而非数据库 id：通知栏 id 只要求稳定唯一，
      // 而 mock 兜底数据没有 id（为 null），用它当 id 会撞成同一个。
      id: song.key,
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: Duration(seconds: song.duration),
      // 真实专辑封面（QQ 音乐 CDN，由 SongRow 从 album_mid 拼出）。
      // 加载失败时系统回退默认图标，不会崩；mock/来源不明的歌为 null
      // 仍走系统默认图标。
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
    );

/// 停滞看门狗的判定逻辑（纯状态机，无 I/O，可独立单测）。
///
/// ## 为什么需要它（2026-10-07 魅族 21 实测确诊）
/// Flyme 的后台网络封锁会在暂停/熄屏后掐断 CDN 拉流：播放键恢复后
/// ExoPlayer 状态是 PLAYING、无任何报错，但 position 原地冻结——
/// 「假播放」。这种死流不触发 403/异常，只能靠位置读数发现。
///
/// 判定规则：playing 期间每 2s 读一次 position，连续
/// [stallThreshold] 次位移 < 500ms 判为停滞，请求自愈；自愈成功次数
/// 超过 [maxReviveAttempts] 后放弃（典型即 ROM 断网，重试只会白烧
/// playurl 配额），等下一次人工 play / 切歌重整旗鼓。
class StallWatchdog {
  StallWatchdog({
    this.stallThreshold = 5,
    this.maxReviveAttempts = 3,
  });

  /// 连续多少个 tick（tick 周期 2s）位置不动才判死。
  /// 5 × 2s = 10s：短于它会误伤弱网下的正常缓冲，长于它用户已经切走了。
  final int stallThreshold;

  /// 一段播放周期内最多自愈几次。
  final int maxReviveAttempts;

  Duration? _lastPos;
  int _stallTicks = 0;
  int _reviveAttempts = 0;

  /// 已完成的本次周期内自愈次数（诊断日志用）
  int get attempts => _reviveAttempts;

  /// 记账一次自愈（控制器在真正发起重载前调用）
  void countRevive() => _reviveAttempts++;

  /// 自愈次数用尽：再判停滞也不重试，等 [resetAttempts] 后才恢复
  bool get exhausted => _reviveAttempts >= maxReviveAttempts;

  /// 开始新的播放周期（人工播放/切歌）：自愈预算清零。
  /// 自愈内部走的 playSong（控制器里以 `_reviving` 标记）会跳过这里，
  /// 防止预算被自愈自己的重载偷偷回满、变成无限循环。
  void resetAttempts() {
    _reviveAttempts = 0;
    _stallTicks = 0;
    _lastPos = null;
  }

  /// 自愈重载期间/之后调用：作废位置基线与连击计数。
  /// 重载后位置会跳变（回到 resumePos），旧基线比对无意义。
  void suspend() {
    _stallTicks = 0;
    _lastPos = null;
  }

  /// 喂一次位置读数。返回 true 表示停滞已达标、应触发自愈。
  ///
  /// [playing] = false（暂停/空载）时清零基线直接返回：暂停时位置
  /// 不动是正常的，绝不能攒停滞计数。
  bool tick({required bool playing, required Duration position}) {
    if (!playing) {
      _stallTicks = 0;
      _lastPos = null;
      return false;
    }
    final prev = _lastPos;
    _lastPos = position;
    // seek / 回环造成的跳变（含倒退）都算「流是活的」
    if (prev != null && (position - prev).abs() > const Duration(milliseconds: 500)) {
      _stallTicks = 0;
      return false;
    }
    _stallTicks++;
    return _stallTicks >= stallThreshold;
  }
}

class AudioPlayerController extends BaseAudioHandler with SeekHandler {
  /// [fx] 缺省取 [AudioFxService.instance] 单例。省略参数让
  /// `AudioService.init(builder: AudioPlayerController.new)` 的 tearoff
  /// 继续可用（音效实例必须与 player 同生命周期，见 fx service 注释）。
  ///
  /// 初始化列表里不能引用实例字段，所以 pipeline 的组装走静态方法
  /// [_buildPipeline] 传参。
  AudioPlayerController({AudioFxService? fx})
      : _fx = fx ?? AudioFxService.instance,
        _player = ja.AudioPlayer(
          audioPipeline: _buildPipeline(fx ?? AudioFxService.instance),
        ) {
    // 停滞看门狗：常驻 2s 一拍，自身不做任何判定外动作，见 _watchdogTick。
    _stallTimer = Timer.periodic(const Duration(seconds: 2), (_) => _watchdogTick());
  }

  static ja.AudioPipeline _buildPipeline(AudioFxService fx) {
    // 音效经 AudioPipeline 注入：just_audio 内部有平台守卫（非 Android
    // 不下发），效果参数在 platform 未就绪时会暂存、激活时统一应用——
    // 构造期注入是官方推荐姿势，不需要等异步初始化。
    return ja.AudioPipeline(
      androidAudioEffects: [fx.equalizer, fx.loudnessEnhancer],
    );
  }

  final AudioFxService _fx;

  /// 音效状态源（音效面板直接读它的字段）。
  AudioFxService get fx => _fx;

  final ja.AudioPlayer _player;

  /// 当前正在播放的歌（用于播放结束后取下一首、以及重建 MediaItem）
  Song? _current;

  /// 播放器里是否装载着可播的音源。
  ///
  /// ## 为什么自己记账而问 just_audio
  /// just_audio 的 `stop()` **不清空**已装载的音源：它把旧源连同旧进度
  /// 转入 idle 平台保存，`_playlist` 依然非空——此后调 `play()` 会把
  /// 旧源按旧进度原地复活。所以「播放器是不是真的空了」只能由这里
  /// 在 setAudioSource / 清空动作处自己维护。
  bool _sourceLoaded = false;

  /// true = 播放器装载着音源（含暂停态）；false = 空播放器（初始 /
  /// 切歌后 / 解析失败后）。UI 与 AppState 据此决定播放键的行为。
  bool get hasLoadedSource => _sourceLoaded;

  /// playSong 代次：快速连点时旧任务在 resolve 返回后发现代次已变，
  /// 就地作废——否则旧的 setAudioSource 会排进方法通道，把新歌顶掉。
  int _playSongGen = 0;

  /// 音源解析器，由 AppState 在装配完成后注入。
  /// 之所以用可空字段而非构造参数：audio_service 的 handler 必须在
  /// `AudioService.init()` 时就构造出来，而那时数据库还没开好。
  SourceResolver? resolver;

  OnTrackEnded? onTrackEnded;
  OnPlaybackError? onPlaybackError;

  /// 通知栏「下一首/上一首」按钮、耳机线控、蓝牙控制的切歌回调，
  /// 由 AppState 注入（与 onTrackEnded 同理，本类不反向依赖它）。
  ///
  /// ## 为什么必须覆写而不是用默认实现
  /// audio_service 0.18 的 `BaseAudioHandler.skipToNext/skipToPrevious`
  /// 默认是**空操作**（源码 `async {}`）——不注入回调的话，通知栏两个
  /// 切歌键、耳机双击/三击、蓝牙 AVRCP 全部点了没反应。
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;

  /// 「播放键来了但本类完全不记得在放什么」时的兜底回调，由 AppState 注入。
  ///
  /// ## 什么时候会走到这一步
  /// 进程被系统杀死后，MediaButtonReceiver 冷唤醒引擎：main() 重跑、
  /// [AudioService.init] 重建本类——`_current` 为 null、无音源，但
  /// AppState 的会话恢复已把队列和待续播进度备好。此时播放键必须
  /// 委托回应用内同一条恢复链路（togglePlay 的空源分支），否则锁屏
  /// 卡片上的播放键就是死的（真机/魅族 21 实测）。
  Future<void> Function()? onColdPlay;

  // ── 停滞看门狗（后台断流自愈，见 StallWatchdog 类注释）──────────
  Timer? _stallTimer;
  final StallWatchdog _watchdog = StallWatchdog();

  /// [bind] 里那两个 just_audio 流的订阅句柄。
  ///
  /// 之前直接 `.listen(...)` 把返回值丢了，于是**没有任何取消入口**：
  /// 本类的 [dispose] 即使被调用也只停了看门狗 Timer，订阅仍在收事件、
  /// 继续往已经 dispose 的 playbackState / handler 推数据。这里存起来
  /// 才能真正释放（并且用 `??=` 让 [bind] 可重复调用而不重复订阅）。
  StreamSubscription<ja.PlaybackEvent>? _stateSub;
  StreamSubscription<ja.ProcessingState>? _procStateSub;

  /// [shutdown] 的幂等标志：重复调用无副作用。
  bool _disposed = false;

  /// true = 看门狗正在重载音源自愈。重载内部走 playSong，用这个标记
  /// 让 playSong 跳过 watchdog.resetAttempts（否则自愈预算永远回不满，
  /// 后台断网时 3 次上限形同虚设，playurl 会被无限重放）。
  bool _reviving = false;

  /// 当前这首歌实际解析到的音质（通知栏/详情面板可读）
  int currentQualityId = 0;
  int currentBandwidth = 0;

  /// 是否正在「加载中」（拉流 + 缓冲）。UI 据此显示转圈。
  final _resolving = StreamController<bool>.broadcast();
  Stream<bool> get resolvingStream => _resolving.stream;
  bool _isResolving = false;
  bool get isResolving => _isResolving;

  void _setResolving(bool v) {
    if (_isResolving == v) return;
    _isResolving = v;
    _resolving.add(v);
  }

  // ── 生命周期 ────────────────────────────────────────────

  /// 把 just_audio 的流转发到 audio_service 的标准流上。
  ///
  /// ⚠️ 这一步不能省：`playbackState` 是通知栏/锁屏的数据源，
  /// 不转发的话系统只知道「有声在响」，按钮状态全是错的。
  void bind() {
    _stateSub ??= _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) => onPlaybackError?.call(e),
    );

    // 播放自然结束 → 交给上层决定下一首（尊重 PlayMode）
    _procStateSub ??= _player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) {
        onTrackEnded?.call();
      }
    });
  }

  void _broadcastState(ja.PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (_player.processingState) {
          ja.ProcessingState.idle => AudioProcessingState.idle,
          ja.ProcessingState.loading => AudioProcessingState.loading,
          ja.ProcessingState.buffering => AudioProcessingState.buffering,
          ja.ProcessingState.ready => AudioProcessingState.ready,
          ja.ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: null,
      ),
    );
  }

  // ── 状态流（UI 直接订阅） ─────────────────────────────────

  Stream<Duration> get positionStream => _player.positionStream;

  /// 注意上游是 `Stream<Duration?>`（音频未加载完时 duration 为 null），
  /// 这里过滤掉 null，让订阅方不必处理：UI 只关心「已知的真实时长」。
  Stream<Duration> get durationStream =>
      _player.durationStream.where((d) => d != null).cast<Duration>();
  Stream<bool> get playingStream => _player.playingStream;
  Stream<ja.PlayerState> get playerStateStream => _player.playerStateStream;

  Duration get position => _player.position;
  Duration get duration => _player.duration ?? Duration.zero;
  bool get playing => _player.playing;

  // ── 核心：播放一首歌 ─────────────────────────────────────

  /// 解析音源并开始播放。
  ///
  /// 返回 null 表示成功；非 null 是给用户看的错误文案。
  ///
  /// [initialPosition]：装载完成后从该进度起播（看门狗自愈用——死流
  /// 重载必须原地复活，从头播会把用户的进度丢掉）。普通播歌不传。
  Future<String?> playSong(
    Song song, {
    bool forceRefresh = false,
    Duration? initialPosition,
  }) async {
    final r = resolver;
    if (r == null) return '播放器未初始化';

    // 外部发起的播放 = 新的看门狗周期，自愈预算回满。
    // 自愈自己走的 playSong 由 _reviving 拦下，防止预算被自己回满。
    if (!_reviving) _watchdog.resetAttempts();
    final gen = ++_playSongGen;
    _current = song;
    // 装载开始：旧源已随上一次 stopForSwitch / cancelLoad 清掉，
    // 在装载完成前播放器是「空」的——此窗口内 play() 会被空态守卫拦下。
    _sourceLoaded = false;
    _setResolving(true);

    // 通知栏先切到新歌（此时还没拉到流，但标题/歌手已知，
    // 让用户在等待缓冲时就看到正确的信息）
    mediaItem.add(_toMediaItem(song));

    try {
      final res = await r.resolve(song, forceRefresh: forceRefresh);
      // ⚠️ await 期间可能已经被更晚的 playSong / stopForSwitch 顶掉。
      // 必须在这里退出，否则旧的 setAudioSource 会排进方法通道，
      // 按到达顺序在新歌之后执行——「点了 B 却播 A」。
      if (gen != _playSongGen) {
        _setResolving(false);
        return '已切换到其他歌曲';
      }
      if (!res.ok) {
        _setResolving(false);
        return res.error ?? '音源解析失败';
      }

      currentQualityId = res.qualityId;
      currentBandwidth = res.bandwidth;

      // 自动重匹配换了音源：通知栏与当前歌对象都要跟上，
      // 否则「正在播 A 的视频、界面显示 B」——很难查的错位。
      // 步骤 7：用通用字段比较（sourceKey），不再硬编码 bvid
      if (res.rematched && res.sourceKey != (song.source?.sourceKey ?? song.source?.bvid)) {
        _current = song.copyWith(
          source: song.source?.copyWith(
            bvid: res.sourceKey,
            cid: int.tryParse(res.sourceSubKey) ?? 0,
            sourceKey: res.sourceKey,
            sourceSubKey: res.sourceSubKey,
          ),
        );
        mediaItem.add(_toMediaItem(_current!));
      }

      // ★ 关键：CDN 拉流可能需要请求头（B站要 Referer）
      // 从 resolver.sourceHeaders 读，不再硬编码 bilibili.com
      //
      // ⚠️ **本机文件不能带 headers**（2026-10-11 真机确诊）。
      // just_audio 一旦收到 headers 就把流改走它自己的 Dart 端代理
      // （_proxyHandlerForUri → _HttpClient.getUrl），而 HttpClient 只认
      // http/https——content:// 直接抛
      //   Invalid argument(s): Unsupported scheme 'content' in URI
      //   content://media/external/audio/media/xxxx
      // 表现就是「本地/下载的歌曲点开没声」。本机文件本来也不需要任何头，
      // 所以按 uri 的 scheme 决定传不传，而不是无脑传。
      final url = Uri.parse(res.url!);
      final needsHeaders = url.scheme == 'http' || url.scheme == 'https';
      await _player.setAudioSource(
        ja.AudioSource.uri(
          url,
          headers: needsHeaders ? r.sourceHeaders : null,
        ),
        initialPosition: initialPosition,
      );
      // 装载成功：从这一刻起播放器「有源」，play() 的空态守卫放行
      _sourceLoaded = true;

      // ⚠️ 不 await play()：它的 Future 要等到「真正开始出声」才完成。
      // 弱网缓冲停滞 / 起播瞬间被音频焦点打断 / 起播阶段报错时，这个
      // Future 可能永远不完成——上层 playSong 的 await 随之挂起，
      // AppState.resolvingSource 永远复位不了，播放按钮的转圈就不停转
      // （真机实测：切歌后按钮一直显示加载圈）。音源装载完成即视为
      // 就绪，起播状态由 playingStream 驱动 UI；起播失败仍会经
      // playbackEventStream / catchError 走 onPlaybackError。
      unawaited(
        _player.play().catchError((Object e) => onPlaybackError?.call(e)),
      );
      return null;
    } catch (e) {
      _setResolving(false);
      // 播放失败（多为 403：URL 过期或音源失效）→ 交给上层走重解析/重匹配
      onPlaybackError?.call(e);
      return '播放失败：$e';
    }
  }

  // ── 播放控制 ────────────────────────────────────────────

  @override
  Future<void> play() async {
    // 人工按下播放 = 新的看门狗周期（自愈预算回满）
    _watchdog.resetAttempts();
    // 空播放器（初始 / 切歌后 / 解析失败后）没有音源可播，just_audio 对
    // 空 playlist 的 play() 会先把 playing 置 true 再挂起——不拦的话，
    // 通知栏/界面会显示「播放中」却永远无声的假播放态。
    //
    // 但不能纯静默：解析失败后通知栏仍挂着这首歌、按钮是「播放」，
    // 静默 return 会造成「通知栏播放键点了没反应」的死角。此时只要
    // 还记得当前歌，就重走 playSong 自愈（默认不 forceRefresh：多数
    // 失败是 URL 过期，resolver 内部本就会重匹配；正在切歌/解析中则
    // 不掺和，避免代次竞争把新歌顶掉）。
    if (!_sourceLoaded) {
      if (!_isResolving) {
        final song = _current;
        if (song != null && resolver != null) {
          // 还记得当前歌：重走 playSong 自愈（默认不 forceRefresh：
          // 多数失败是 URL 过期，resolver 内部本就会重匹配）。
          await playSong(song);
        } else {
          // 冷启动/全新会话：委托 AppState 的恢复接力（续播/重播）。
          await onColdPlay?.call();
        }
      }
      return;
    }
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  // ── 停滞看门狗（后台断流自愈）────────────────────────────

  /// 看门狗心跳：只在「真实出声中」判断位置是否冻结（判定规则见
  /// [StallWatchdog]）。判死后用同一条 URL 重装音源自愈——停滞的本质
  /// 是旧 CDN 连接死透且 ExoPlayer 已放弃重试，重开一条新连接即可复活；
  /// URL 本身被吊销的情形会以 403 异常暴露，走 onPlaybackError 的强制
  /// 重解析路径，不归这里管。
  void _watchdogTick() {
    // 没在真实出声（空载/装载中/重载中/暂停/已播完）时不做任何判定。
    // 特别注意 completed：曲目自然播完后 position 冻结在末尾是正常的，
    // 绝不能判成死流把已结束的歌原地复活。
    if (!_sourceLoaded ||
        _reviving ||
        !_player.playing ||
        _player.processingState == ja.ProcessingState.completed) {
      return;
    }
    if (!_watchdog.tick(playing: true, position: _player.position)) return;
    _watchdog.suspend();
    if (_watchdog.exhausted) {
      // 连续自愈仍停滞（典型：ROM 掐断后台网络）。放弃到下一次人工
      // play / 切歌为止，避免每 10s 白烧一次 playurl 配额。
      return;
    }
    _watchdog.countRevive();
    unawaited(_reviveStalledStream());
  }

  /// 自愈：记下停滞进度 → 重装音源 → 从原进度起播。
  /// 不 forceRefresh：缓存 URL 只要还在有效期内就是好的，重开会话
  /// （新 TCP/TLS）才是对症的药；顺带省一次 playurl 配额。
  Future<void> _reviveStalledStream() async {
    final song = _current;
    if (song == null || resolver == null) return;
    final resumePos = _player.position;
    DiagLog.instance.w(
      DiagCategory.playback,
      '播放停滞，看门狗重载音源：${song.key} @${resumePos.inMilliseconds}ms',
      {
        'event': 'stall_watchdog',
        'songKey': song.key,
        'positionMs': resumePos.inMilliseconds,
        'attempt': _watchdog.attempts,
      },
    );
    _reviving = true;
    try {
      await playSong(song, initialPosition: resumePos);
    } finally {
      _reviving = false;
    }
  }

  /// 通知栏 / 线控 / 蓝牙的切歌请求 → 交给 AppState 的 next/previous
  /// （尊重播放模式：单曲循环重播、随机乱序），与界面按钮同一条链路。
  @override
  Future<void> skipToNext() => onSkipToNext?.call() ?? Future.value();

  @override
  Future<void> skipToPrevious() => onSkipToPrevious?.call() ?? Future.value();

  // ── 每曲音量（音效功能 P0）────────────────────────────────

  /// 当前播放器的软件音量（0~1）。切歌恢复记忆值、调音都走这里。
  ///
  /// ## 为什么「每曲音量」用 player.setVolume 而不是 LoudnessEnhancer
  /// LoudnessEnhancer 是全局的（一套参数所有歌共享）；「这首歌要放多
  /// 响」是按曲记忆的——切歌时由 AppState 查库回放。两者叠加使用：
  /// 每曲音量管「这首相对其他首」，全局响度管「整体听感补偿」。
  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0.0, 1.0));

  double get volume => _player.volume;

  @override
  Future<void> stop() async {
    // 通知栏「停止」按钮 / onNotificationDeleted（划掉通知）都汇到这里。
    // 必须同步清掉「有源」记账并清空 playlist：just_audio 的 stop()
    // 不清源，残留的旧源会在下一次 play() 时按旧进度原地复活
    // （详见 stopForSwitch 注释），hasLoadedSource 也会骗过 togglePlay。
    _playSongGen++;
    _sourceLoaded = false;
    await _player.stop();
    try {
      await _player.setAudioSources(const [], preload: false);
    } catch (_) {
      // 清空失败不阻塞停止主流程：下一次 setAudioSource 会整体覆盖
    }
    await super.stop();
  }

  /// 切歌时立即停掉当前音频并**清空已装载的音源**。
  ///
  /// ## 为什么不能只用 stop
  /// just_audio 的 `stop()` 只停不解绑：旧音源连同旧播放进度被转入
  /// idle 平台保存，`_playlist` 依然非空。后果有两个：
  ///   1. 此后再调 `play()`，just_audio 会把旧源按旧进度**原地复活**
  ///      ——界面已切到新歌、耳朵听到的是上一首（真机实测）；
  ///   2. idle 平台还会按旧进度广播一次位置事件，把 UI 的进度条
  ///      回写成上一首的时间（「切歌失败停在旧进度」的来源）。
  /// 所以 stop 之后必须显式清空 playlist，播放器才算真正空了：
  /// 按播放不会出声，进度事件也不再带旧值。
  ///
  /// ## 为什么不走 audio_service 的 `super.stop()`
  /// 那会撤掉通知栏并结束前台 Service，而切歌后马上就要继续播放。
  /// 媒体会话保持存活，通知栏在等待期间只是短暂显示「已暂停」。
  Future<void> stopForSwitch() async {
    // 作废在途装载：旧歌的 setAudioSource 若还在路上，其恢复后会被
    // playSong 的代次检查拦下，不会把旧源装进已经停掉的播放器。
    _playSongGen++;
    _sourceLoaded = false;
    await _player.stop();
    try {
      // 空列表 + 不预载 = 仅清空 playlist，不触发任何装载
      await _player.setAudioSources(const [], preload: false);
    } catch (_) {
      // 清空失败不阻塞切歌主流程：下一次 setAudioSource 会整体覆盖
    }
  }

  /// 放弃在途的播放装载（超时兜底用）：作废当前代次并停掉播放器，
  /// 防止「已经超时报错，挂起的装载完成后又突然出声」。
  /// 与 [stopForSwitch] 同样必须清空音源，理由一致。
  Future<void> cancelLoad() async {
    _playSongGen++;
    _sourceLoaded = false;
    await _player.stop();
    try {
      await _player.setAudioSources(const [], preload: false);
    } catch (_) {
      // 同上，不阻塞
    }
  }

  /// 切歌瞬间先把通知栏元数据换成新歌（标题/歌手已知，流还没拉到）。
  ///
  /// [playSong] 内部也会 add 一次，但那要等到解析完成——没音源的歌
  /// 最长晚 20 秒。这里提前换，让通知栏与界面信息同步切换。
  void previewMediaItem(Song song) => mediaItem.add(_toMediaItem(song));

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// 任务被划掉（用户在最近任务里滑走应用）。
  ///
  /// ## 后台播放的核心语义：划掉界面 ≠ 停止播放
  /// - **播放中**：什么都不做——前台 Service 与通知栏继续存在，音频照常
  ///   出声。平台层（AudioService.kt 的 onTaskRemoved）同样只在非播放时
  ///   才 stopSelf，Dart 侧绝不能主动叫停；旧实现在这里无条件 `stop()`，
  ///   导致「一划掉最近任务就没声、通知栏消失」，后台播放形同虚设。
  /// - **非播放**（暂停/空闲）：停掉 Service 并撤通知——没有正在放的东西，
  ///   空占前台进程反而招系统与 ROM 的激进查杀。
  @override
  Future<void> onTaskRemoved() async {
    if (!_player.playing) {
      await stop();
      // 非播放态被划掉 = 前台 Service 要停Self。这时候把资源一并释放：
      // 播放态不能这么做（会掐断正在放的歌），但这时也没有正在放的东西，
      // 留着看门狗 Timer 和流订阅只是白白占着进程。
      await shutdown();
    }
    await super.onTaskRemoved();
  }

  /// 释放自身持有的资源（看门狗 Timer、just_audio 流订阅、播放器）。
  ///
  /// ## 生命周期与调用方
  /// 本类是 **AudioService 持有的单例**：它的生命周期跟前台 Service 走，
  /// 比界面（AppState）长得多。`main.dart` 刻意**不**调它 —— 界面被划掉
  /// 时音频还要继续放，这里 dispose 就等于把后台播放掐了。
  ///
  /// 真正的调用点是 audio_service 的 [onTaskRemoved] 之外的 Service 销毁
  /// 路径：`BaseAudioHandler` 没有 dispose 钩子，但 audio_service 在
  /// 自定义 `stop()` / Service 被真正销毁时会调 `onTaskRemoved`。
  /// 因此这里同时提供 [shutdown]：把「停 Service」和「释放资源」串成
  /// 一条不会漏的路，且**可重入**（重复调用无副作用）。
  ///
  /// 之前有一个 `dispose()`，但它是**死代码**（lib/ 内无任何调用点），
  /// 后果是 2 秒看门狗 Timer 与两个流订阅没有任何回收路径。
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;

    _stallTimer?.cancel();
    _stallTimer = null;

    await _stateSub?.cancel();
    _stateSub = null;
    await _procStateSub?.cancel();
    _procStateSub = null;

    await _resolving.close();
    await _player.dispose();
  }
}
