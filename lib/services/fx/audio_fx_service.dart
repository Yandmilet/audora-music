/// 音效服务 —— 持有 just_audio 的 Android 音效实例并统一管理参数。
///
/// ## 架构位置（P0 方案，2026-09-30 用户确认）
/// just_audio 0.10.6 原生内置 `AndroidEqualizer`（系统级多段 EQ，段数
/// 随设备）与 `AndroidLoudnessEnhancer`（±dB 全局响度），经
/// `AudioPipeline(androidAudioEffects:)` 在 [AudioPlayerController]
/// 构造时注入 —— **纯 Dart，零原生代码**。BassBoost / Virtualizer
/// 不在 just_audio 内置范围，留待 P1 自写 Kotlin channel。
///
/// ## 为什么是单例
/// 与 `DiagLog.instance` 同理：音效实例必须与 AudioPlayer 的生命周期
/// 一一对应，而 player 由 `AudioService.init` 最早创建（先于数据库与
/// settings 可用），构造 tearoff `AudioPlayerController.new` 又不允许
/// 带参注入。单例让「效果实例」与「参数加载」解耦：构造时引用实例，
/// `load(settings)` 在 settings 就绪后补一次参数恢复。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../settings/settings_store.dart';
import 'fx_preset.dart';

/// 全局响度增益的边界（dB）。超过 ±10 已经不叫微调，是失真制造机。
const double kLoudnessMinDb = -10;
const double kLoudnessMaxDb = 10;

class AudioFxService extends ChangeNotifier {
  AudioFxService._();

  static final AudioFxService instance = AudioFxService._();

  /// just_audio 内置效果实例。构造即创建（纯 Dart 对象），平台侧在
  /// AudioPlayer 构造激活时才真正分配。
  final ja.AndroidEqualizer equalizer = ja.AndroidEqualizer();
  final ja.AndroidLoudnessEnhancer loudnessEnhancer = ja.AndroidLoudnessEnhancer();

  SettingsStore? _settings;

  // ── 当前状态（UI 与应用共用）──────────────────────────────
  // 「平直」即关闭 EQ 的语义（见 FxPreset.flat 注释），无独立总开关。

  String presetId = FxPreset.flatId;

  /// 自定义曲线：频点(Hz，取整) → dB。只在 presetId == custom 时生效，
  /// 但持久化始终保留（切走再切回来不丢）。
  Map<double, double> customCurve = {};

  /// 全局响度微调（dB），LoudnessEnhancer 承载。
  double loudnessDb = 0;

  /// EQ band 参数缓存。null = 还没拿到（platform 未激活 / 非 Android）。
  ja.AndroidEqualizerParameters? _eqParams;
  Future<ja.AndroidEqualizerParameters?>? _paramsFuture;

  bool get isEqActive => presetId != FxPreset.flatId;
  bool get isFxActive => isEqActive || loudnessDb != 0;

  // ── 参数恢复 ─────────────────────────────────────────────

  /// 从 settings 恢复偏好。main.dart 装配时调用一次；settings 为 null
  /// （单测）时全部用默认值，不读盘。
  Future<void> load(SettingsStore? settings) async {
    _settings = settings;
    presetId = FxPreset.byId(settings?.fxPreset ?? FxPreset.flatId).id;
    customCurve = FxCurves.decode(settings?.fxCustomGains ?? '');
    loudnessDb = (settings?.fxLoudness ?? 0).clamp(kLoudnessMinDb, kLoudnessMaxDb).toDouble();
    notifyListeners();
  }

  // ── EQ band 参数（UI 渲染滑条用）─────────────────────────

  /// 拿设备 EQ band 参数（带缓存）。拿不到返回 null（非 Android /
  /// effect 未激活 / 超时），UI 据此显示「不支持」。
  Future<ja.AndroidEqualizerParameters?> ensureParams() {
    _paramsFuture ??= _loadParams();
    return _paramsFuture!;
  }

  Future<ja.AndroidEqualizerParameters?> _loadParams() async {
    try {
      _eqParams = await equalizer.parameters.timeout(const Duration(seconds: 8));
      return _eqParams!;
    } catch (_) {
      return null;
    }
  }

  /// 当前曲线在 [hz] 的期望增益（UI 滑条的显示值也用它）。
  double gainAt(double hz) {
    if (presetId == FxPreset.customId) {
      final exact = customCurve[hz];
      if (exact != null) return exact;
      return FxCurves.interp(customCurve, hz);
    }
    return FxCurves.interp(FxPreset.byId(presetId).curve, hz);
  }

  // ── 修改入口（UI 调用）───────────────────────────────────

  /// 切换预设。平直之外都会顺带打开 EQ（enabled=true）。
  Future<void> setPreset(String id) async {
    presetId = FxPreset.byId(id).id;
    notifyListeners();
    await _persist();
    await _applyEqualizer();
  }

  /// 用户拖动某个 band。首次拖动把当前预设固化进自定义曲线。
  Future<void> setBandGain(double hz, double db) async {
    if (presetId != FxPreset.customId) {
      // 固化：以设备实际 band 频点为准取样当前曲线；band 参数还没拿到
      // （罕见）就退化为只记这一个点，其余频点按曲线插值，语义不破。
      final params = _eqParams;
      if (params != null) {
        customCurve = {
          for (final b in params.bands) b.centerFrequency.round().toDouble(): gainAt(b.centerFrequency),
        };
      } else {
        customCurve = {};
      }
      presetId = FxPreset.customId;
    }
    final clamped = db.clamp(kLoudnessMinDb - 5, kLoudnessMaxDb + 5).toDouble();
    customCurve[hz.round().toDouble()] = clamped;
    notifyListeners();
    // 连续拖动：防抖落盘（见 _persist 注释）
    await _persist(immediate: false);
    // 只下发这一个 band，避免整条曲线重写（滑条连续拖动时更省通道）
    try {
      final params = _eqParams ?? await ensureParams();
      if (params == null) return;
      for (final b in params.bands) {
        if (b.centerFrequency.round() == hz.round()) {
          await b.setGain(clamped.clamp(params.minDecibels, params.maxDecibels).toDouble());
          break;
        }
      }
    } catch (_) {
      // 下发失败不阻塞 UI：下次 apply 会整体对齐
    }
  }

  /// 修改全局响度（dB）。调用方按场景决定是否渐变：
  /// UI 滑条本身就是连续手势，直接一步到位即可；程序化批量设置
  /// （未来若有的话）应自行分步调用，避免一次大跳变出「啪」声。
  Future<void> setLoudnessDb(double db) async {
    loudnessDb = db.clamp(kLoudnessMinDb, kLoudnessMaxDb).toDouble();
    notifyListeners();
    // 连续拖动：防抖落盘（见 _persist 注释）
    await _persist(immediate: false);
    try {
      await loudnessEnhancer.setTargetGain(loudnessDb);
    } catch (_) {
      // 非 Android / 未激活：静默
    }
  }

  /// 重置全部音效到默认（平直 + 响度 0）。保留自定义曲线供用户后悔。
  Future<void> resetAll() async {
    presetId = FxPreset.flatId;
    loudnessDb = 0;
    notifyListeners();
    await _persist();
    await _applyEqualizer();
    try {
      await loudnessEnhancer.setTargetGain(0);
    } catch (_) {}
  }

  // ── 平台下发的统一入口 ───────────────────────────────────

  /// 幂等下发全部音效状态。AudioPlayer 构造后即可安全调用：
  /// platform 未就绪时 just_audio 会暂存参数，激活时统一下发。
  Future<void> apply() async {
    await _applyEqualizer();
    try {
      await loudnessEnhancer.setTargetGain(loudnessDb);
    } catch (_) {}
  }

  /// EQ 的 enabled + 全部 band 增益。参数未就绪时等一次再下发。
  Future<void> _applyEqualizer() async {
    try {
      // 平直也要显式 setEnabled(false)：just_audio 激活时以 enabled
      // 状态初始化，不显式关掉的话设备上一次会话的 EQ 状态会残留。
      await equalizer.setEnabled(isEqActive);
    } catch (_) {}
    try {
      final params = _eqParams ?? await ensureParams();
      if (params == null || !isEqActive) return;
      for (final band in params.bands) {
        final g = gainAt(band.centerFrequency)
            .clamp(params.minDecibels, params.maxDecibels)
            .toDouble();
        await band.setGain(g);
      }
    } catch (_) {
      // 下发失败静默：UI 每次修改都会重试整体对齐
    }
  }

  /// 落盘（带防抖）。滑条连续拖动时每个 tick 都会触发修改，直接写
  /// SharedPreferences 会排队几百次 IO；600ms 内的连续修改只落最后一次。
  /// [immediate] 用于离散操作（切预设/重置），保证改动立刻可见于下次启动。
  Future<void> _persist({bool immediate = true}) async {
    if (immediate) {
      _persistTimer?.cancel();
      _persistTimer = null;
      await _doPersist();
      return;
    }
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(_doPersist());
    });
  }

  Timer? _persistTimer;

  Future<void> _doPersist() async {
    final s = _settings;
    if (s == null) return;
    await s.setFxPreset(presetId);
    await s.setFxCustomGains(FxCurves.encode(customCurve));
    await s.setFxLoudness(loudnessDb);
  }
}
