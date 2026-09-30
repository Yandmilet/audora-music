/// 音效预设：频点 → 增益（dB）曲线。
///
/// ## 为什么预设是「频点曲线」而不是「第 i 段 = x dB」
/// Android 系统 EQ 的段数与频点**随设备不同**（多数 5 段，部分 10 段）。
/// 若按段序号存增益，换一台设备频段全部错位。把预设定义为一条
/// 「频点 → dB」曲线，应用时按每个 band 的中心频率在曲线上**取值**，
/// 任意段数的设备都能得到语义一致的曲线。
///
/// 曲线取值用**对数域（log）线性插值**（见 [FxCurves.interp]）：
/// 人耳对频率的感知是对数的，在对数域插出来的过渡才符合直觉。
///
/// 曲线设计原则（针对 B站音源）：
/// - 增益保守（|≤5dB|），避免削波与轰头；
/// - `biliBright` 专治 B站 64~192K AAC 砍高频后的发闷（真实听感痛点）；
/// - `live` 压中频让现场人声从观众噪声里浮出来。
library;

import 'dart:convert' show jsonDecode;
import 'dart:math' as math;

/// 一个预设 = id + 展示名 + 说明 + 曲线。
class FxPreset {
  final String id;
  final String label;
  final String desc;

  /// 频点(Hz) → 增益(dB)。空表 = 平直。
  final Map<double, double> curve;

  const FxPreset(this.id, this.label, this.desc, this.curve);

  // ── 预设 id 常量（持久化的取值，不可改名）────────────────
  static const flatId = 'flat';
  static const biliBrightId = 'bili_bright';
  static const vocalId = 'vocal';
  static const liveId = 'live';
  static const bassId = 'bass';
  static const customId = 'custom';

  /// 平直 = EQ 不做任何修饰。
  ///
  /// 它同时承担「关闭 EQ」的语义：预设胶囊第一位就是它，选中即旁路——
  /// 比「开关 + 预设」两层结构少一次点击，也不存在「开关关了但滑条
  /// 还挂着值」的困惑。
  ///
  /// ⚠️ 带增益的预设必须 `static final` 而非 const：曲线的 key 是
  /// double，Dart 不允许 const map 携带重写了 == 的 key（
  /// const_map_key_not_primitive_equality），语言硬约束不是风格。
  /// flat/custom 曲线为空表，可安全 const。
  static const flat = FxPreset(flatId, '平直', '不做修饰，原始听感', {});

  /// 针对 B站码率的提亮：补回 192K AAC（SBR）砍掉的高频。
  static final biliBright = FxPreset(
    biliBrightId,
    'B站提亮',
    '补回 AAC 砍掉的高频，治发闷',
    {2000: 1.0, 4000: 2.0, 8000: 3.5, 12000: 4.0, 16000: 3.0},
  );

  /// 人声：压低中低频浑浊，抬人声主干（600~3000Hz）。
  static final vocal = FxPreset(
    vocalId,
    '人声',
    '人声突出，伴奏退后',
    {100: -1.5, 250: -2.0, 600: 1.0, 1500: 2.5, 3000: 2.0, 8000: 0.5},
  );

  /// 现场：演唱会录像观众噪声多、混响大，压中频 + 两端放开。
  static final live = FxPreset(
    liveId,
    '现场',
    '压观众噪声，保留现场氛围',
    {100: 2.0, 500: 1.0, 2500: -1.5, 8000: 1.0, 12000: 2.0},
  );

  /// 低音增强：用 EQ 低频段近似 BassBoost（just_audio 不内置原生
  /// BassBoost，P1 自写 channel 前先用它顶住高感知需求）。
  static final bass = FxPreset(
    bassId,
    '低音增强',
    '低频收紧有力，中频让路',
    {60: 5.0, 150: 3.5, 400: 1.0, 1500: -1.0},
  );

  /// 自定义：用户拖动 EQ 滑条后生成，曲线来自
  /// [AudioFxService.customCurve]（此处仅作展示占位）。
  static const custom = FxPreset(customId, '自定义', '手动调节的曲线', {});

  static final List<FxPreset> presets = [flat, biliBright, vocal, live, bass, custom];

  /// 按 id 反查。找不到回落平直——持久化值损坏不该让面板打不开。
  static FxPreset byId(String id) =>
      presets.firstWhere((p) => p.id == id, orElse: () => flat);
}

/// 曲线取值 / 自定义曲线的序列化。
abstract final class FxCurves {
  /// 曲线在 [hz] 处的增益。
  ///
  /// - 曲线为空 → 0（平直）；
  /// - [hz] 越界 → 用最近端点值（不做外推）；
  /// - 落在两频点之间 → log 域线性插值。
  static double interp(Map<double, double> curve, double hz) {
    if (curve.isEmpty) return 0;
    final freqs = curve.keys.toList()..sort();
    if (hz <= freqs.first) return curve[freqs.first]!;
    if (hz >= freqs.last) return curve[freqs.last]!;
    for (var i = 0; i < freqs.length - 1; i++) {
      final a = freqs[i];
      final b = freqs[i + 1];
      if (hz >= a && hz <= b) {
        if (b == a) return curve[a]!;
        final la = math.log(a);
        final lb = math.log(b);
        final t = (math.log(hz) - la) / (lb - la);
        return curve[a]! + (curve[b]! - curve[a]!) * t;
      }
    }
    return 0;
  }

  /// 把自定义曲线编成可持久化的 JSON 字符串。
  ///
  /// JSON 的 key 必须是字符串：频点统一取整型 Hz（避免 60.0 / 60 的
  /// 序列化差异让同一个频点存出两份）。空曲线存空串。
  static String encode(Map<double, double> curve) {
    if (curve.isEmpty) return '';
    final entries = curve.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return '{${entries.map((e) => '"${e.key.round()}":${e.value.toStringAsFixed(1)}').join(',')}}';
  }

  /// [encode] 的逆操作。解析失败返回空表——损坏的偏好不该抛异常。
  static Map<double, double> decode(String raw) {
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <double, double>{};
      decoded.forEach((k, v) {
        final hz = double.tryParse('$k');
        final db = v is num ? v.toDouble() : null;
        if (hz != null && db != null && hz > 0) out[hz] = db;
      });
      return out;
    } catch (_) {
      return {};
    }
  }
}
