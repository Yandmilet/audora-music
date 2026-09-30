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
        );

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
    _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) => onPlaybackError?.call(e),
    );

    // 播放自然结束 → 交给上层决定下一首（尊重 PlayMode）
    _player.processingStateStream.listen((state) {
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
  Future<String?> playSong(Song song, {bool forceRefresh = false}) async {
    final r = resolver;
    if (r == null) return '播放器未初始化';

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
      if (res.rematched && res.bvid != song.source?.bvid) {
        _current = song.copyWith(
          source: song.source?.copyWith(bvid: res.bvid, cid: res.cid),
        );
        mediaItem.add(_toMediaItem(_current!));
      }

      // ★ 关键：B站 CDN 校验 Referer，不带就 403
      // 用完整前缀写 just_audio 的 AudioSource，与领域模型的 AudioSource 区分
      await _player.setAudioSource(
        ja.AudioSource.uri(
          Uri.parse(res.url!),
          headers: SourceResolver.audioHeaders,
        ),
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
    // 空播放器（初始 / 切歌后 / 解析失败后）忽略播放请求。
    // 原因有二：① 没有音源可播，出声是不可能的；② just_audio 对空
    // playlist 的 play() 会先把 playing 置 true 再挂起——不拦的话，
    // 通知栏/界面会显示「播放中」却永远无声的假播放态。
    // 有源的暂停态不受影响，正常透传给 just_audio。
    if (!_sourceLoaded) return;
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

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
    }
    await super.onTaskRemoved();
  }

  Future<void> dispose() async {
    await _resolving.close();
    await _player.dispose();
  }
}
