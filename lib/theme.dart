import 'package:flutter/material.dart';

/// Audora 2.0 设计令牌 —— 与 HTML 原型 1:1 对齐
/// 参考千千音乐视觉语言：暖红品牌色 + 中性灰底 + 大圆角
class Tokens {
  // 亮色
  static const brand = Color(0xFFE5484D);
  static const brandDark = Color(0xFFC93A3F);
  static const brandSoft = Color(0xFFFDECED);
  static const brandSofter = Color(0xFFFEF6F6);
  // 暗色主题下的品牌弱底：深酒红。与 SemColor 暗色语义色同一设计思路
  // （暗底亮字）——若在暗色下沿用亮色的 brandSoft 浅粉底，配 onSurface
  // 近白文字会浅底白字不可读（2026-09-30 真机截图实证）
  static const brandSoftDark = Color(0xFF3A1E21);

  static const bg = Color(0xFFF5F6F8);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFF1F3F7);
  static const line = Color(0xFFE8EBF0);
  static const lineStrong = Color(0xFFDCE0E7);

  // 暗色
  static const bgDark = Color(0xFF0B0D11);
  static const surfaceDark = Color(0xFF15181E);
  static const surface2Dark = Color(0xFF1C2027);
  static const lineDark = Color(0xFF252A33);
  static const lineStrongDark = Color(0xFF323A48);

  // 圆角
  static const rSm = 10.0;
  static const rMd = 14.0;
  static const rLg = 18.0;
  static const rXl = 24.0;
  static const rFull = 999.0;

  // 间距（8pt 基准）
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s6 = 24.0;
  static const s8 = 32.0;
  static const s12 = 48.0;

  // 时长
  static const durFast = Duration(milliseconds: 160);
  static const dur = Duration(milliseconds: 240);
  static const durSlow = Duration(milliseconds: 420);
}

/// 语义色（状态徽章：已匹配 / 待确认 / 无音源）
class SemColor {
  static const okBg = Color(0xFFE7F6EE);
  static const okInk = Color(0xFF11875A);
  static const pendingBg = Color(0xFFFEF3E2);
  static const pendingInk = Color(0xFFB4680C);
  static const noneBg = Color(0xFFF0F1F4);
  static const noneInk = Color(0xFF858C99);

  static const okBgDark = Color(0xFF14301F);
  static const okInkDark = Color(0xFF4ADE80);
  static const pendingBgDark = Color(0xFF3A2A12);
  static const pendingInkDark = Color(0xFFFBBF24);
  static const noneBgDark = Color(0xFF23272E);
  static const noneInkDark = Color(0xFF8A93A0);
}
