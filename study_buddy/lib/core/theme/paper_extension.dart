// 纸感学术主题层:PaperColors ThemeExtension。
// 承载 M3 ColorScheme 不覆盖的品牌语义色(提示金、印章红、暖阴影等)。
// 亮暗两套 const 值取自 task-2-spec.md §D。
library;

import 'package:flutter/material.dart';

/// 纸感品牌语义色扩展。
///
/// 读取方式:`Theme.of(context).extension<PaperColors>()!`
@immutable
class PaperColors extends ThemeExtension<PaperColors> {
  const PaperColors({
    required this.gold,
    required this.onGold,
    required this.goldContainer,
    required this.stampRed,
    required this.ruleSoft,
    required this.paperHighlight,
    required this.warmShadow,
    required this.polaroidBg,
  });

  /// 提示金(亮色 #B08938 / 暗色 #C9A45A)。
  final Color gold;

  /// 金色底上的文字色。
  final Color onGold;

  /// 金色浅底容器。
  final Color goldContainer;

  /// 印章红(=primary,但语义独立,便于将来与 primary 解耦)。
  final Color stampRed;

  /// 浅分隔线(纸面横线辅助)。
  final Color ruleSoft;

  /// drop-cap(首字下沉)底色高光。
  final Color paperHighlight;

  /// 暖色阴影(带 alpha)。
  final Color warmShadow;

  /// 拍立得白底。
  final Color polaroidBg;

  /// 亮色「日光纸」品牌语义色。
  static const PaperColors light = PaperColors(
    gold: Color(0xFFB08938),
    onGold: Color(0xFF6B5220),
    goldContainer: Color(0xFFF5EBD4),
    stampRed: Color(0xFFB8472D),
    ruleSoft: Color(0xFFE8DFCA),
    paperHighlight: Color(0xFFFAF6EC),
    // 暖色阴影:0x14 alpha(8%)+ 0x4C3C28 暖棕。
    warmShadow: Color(0x144C3C28),
    polaroidBg: Color(0xFFFFFFFF),
  );

  /// 暗色「夜读灯下纸」品牌语义色。
  static const PaperColors dark = PaperColors(
    gold: Color(0xFFC9A45A),
    onGold: Color(0xFF3A2E14),
    goldContainer: Color(0xFF3D3220),
    stampRed: Color(0xFFD9664A),
    ruleSoft: Color(0xFF3D3428),
    paperHighlight: Color(0xFF332B22),
    // 暗色暖阴影:0x66 alpha(40%)纯黑。
    warmShadow: Color(0x66000000),
    polaroidBg: Color(0xFF2B241C),
  );

  @override
  PaperColors copyWith({
    Color? gold,
    Color? onGold,
    Color? goldContainer,
    Color? stampRed,
    Color? ruleSoft,
    Color? paperHighlight,
    Color? warmShadow,
    Color? polaroidBg,
  }) =>
      PaperColors(
        gold: gold ?? this.gold,
        onGold: onGold ?? this.onGold,
        goldContainer: goldContainer ?? this.goldContainer,
        stampRed: stampRed ?? this.stampRed,
        ruleSoft: ruleSoft ?? this.ruleSoft,
        paperHighlight: paperHighlight ?? this.paperHighlight,
        warmShadow: warmShadow ?? this.warmShadow,
        polaroidBg: polaroidBg ?? this.polaroidBg,
      );

  @override
  PaperColors lerp(PaperColors? other, double t) {
    if (other is! PaperColors) return this;
    return PaperColors(
      gold: Color.lerp(gold, other.gold, t)!,
      onGold: Color.lerp(onGold, other.onGold, t)!,
      goldContainer: Color.lerp(goldContainer, other.goldContainer, t)!,
      stampRed: Color.lerp(stampRed, other.stampRed, t)!,
      ruleSoft: Color.lerp(ruleSoft, other.ruleSoft, t)!,
      paperHighlight: Color.lerp(paperHighlight, other.paperHighlight, t)!,
      warmShadow: Color.lerp(warmShadow, other.warmShadow, t)!,
      polaroidBg: Color.lerp(polaroidBg, other.polaroidBg, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaperColors &&
          gold == other.gold &&
          onGold == other.onGold &&
          goldContainer == other.goldContainer &&
          stampRed == other.stampRed &&
          ruleSoft == other.ruleSoft &&
          paperHighlight == other.paperHighlight &&
          warmShadow == other.warmShadow &&
          polaroidBg == other.polaroidBg;

  @override
  int get hashCode => Object.hash(
        gold,
        onGold,
        goldContainer,
        stampRed,
        ruleSoft,
        paperHighlight,
        warmShadow,
        polaroidBg,
      );
}
