import 'package:flutter/material.dart';

/// Centralized design tokens.
///
/// A clean, light, professional palette (macOS / Linear / Notion flavor): white
/// and soft-grey surfaces, a single calm blue accent, hairline borders, and
/// gentle shadows. No gradients or glow.
class AppColors {
  AppColors._();

  // Backgrounds / surfaces. All opaque so pages never bleed through each other.
  static const bg = Color(0xfff5f6f8); // app background (soft grey)
  static const surface = Color(0xffffffff); // cards, panels
  static const surfaceMuted = Color(0xfff0f2f5); // inputs, subtle fills
  static const sidebar = Color(0xfffafbfc); // left navigation column

  // Hairline borders / dividers.
  static const border = Color(0xffe4e7ec);
  static const borderStrong = Color(0xffd5d9e0);

  // Calm blue accent (Linear/macOS-ish).
  static const accent = Color(0xff3b6ef5);
  static const accentHover = Color(0xff315fe0);
  static const accentSoft = Color(0xffe9effe); // tinted fill behind accent
  static const accentBorder = Color(0xffbcd0fb);

  // Text.
  static const textPrimary = Color(0xff1c2333);
  static const textSecondary = Color(0xff5b6472);
  static const textMuted = Color(0xff9099a8);

  // Status.
  static const live = Color(0xffe5484d);
  static const good = Color(0xff17a05a);
  static const danger = Color(0xffe5484d);

  // Selected-row / active tint.
  static const selected = Color(0xffeaf0fe);
}

/// Standard soft card shadow (very subtle, single layer).
List<BoxShadow> cardShadow() => const [
      BoxShadow(
        color: Color(0x0f1c2333),
        blurRadius: 12,
        offset: Offset(0, 3),
      ),
    ];

/// Flat white card decoration with a hairline border.
BoxDecoration cardDecoration({double radius = 12, bool shadow = true}) {
  return BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: AppColors.border, width: 1),
    boxShadow: shadow ? cardShadow() : null,
  );
}
