// 纸感学术主题层:双字体 TextTheme。
// 标题角色用 NotoSerifSC(衬线),正文角色用 NotoSansSC(无衬线)。
// 数值逐字取自 task-2-spec.md §C,直接在 textTheme 写 fontFamily,不走 primaryTextTheme 双轨。
library;

import 'package:flutter/material.dart';

/// 根据给定 [ColorScheme] 与 [Brightness] 构造双字体 TextTheme。
///
/// 标题角色(display/headline/titleLarge)绑定 `NotoSerifSC`,
/// 其余角色(titleMedium 以下)绑定 `NotoSansSC`。
class AppTypography {
  AppTypography(this.colors, this.brightness);

  final ColorScheme colors;
  final Brightness brightness;

  /// 默认前景色:暗色下用 onSurface,亮色下用 onSurface。
  Color get _defaultFg => colors.onSurface;

  TextTheme get textTheme => TextTheme(
        // —— 标题角色:NotoSerifSC 衬线 ——
        displayLarge: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w700,
          fontSize: 30,
          letterSpacing: 2.0,
          color: _defaultFg,
          height: _lineHeight,
        ),
        displayMedium: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w600,
          fontSize: 24,
          letterSpacing: 1.5,
          color: _defaultFg,
          height: _lineHeight,
        ),
        displaySmall: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w600,
          fontSize: 20,
          letterSpacing: 1.0,
          color: _defaultFg,
          height: _lineHeight,
        ),
        headlineLarge: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w600,
          fontSize: 22,
          letterSpacing: 1.0,
          color: _defaultFg,
          height: _lineHeight,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w600,
          fontSize: 18,
          letterSpacing: 0.5,
          color: _defaultFg,
          height: _lineHeight,
        ),
        headlineSmall: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w600,
          fontSize: 16,
          letterSpacing: 0.5,
          color: _defaultFg,
          height: _lineHeight,
        ),
        titleLarge: TextStyle(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w600,
          fontSize: 18,
          letterSpacing: 0.5,
          color: _defaultFg,
          height: _lineHeight,
        ),

        // —— 正文/标签角色:NotoSansSC 无衬线 ——
        titleMedium: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w500,
          fontSize: 16,
          letterSpacing: 0.15,
          color: _defaultFg,
          height: _lineHeight,
        ),
        titleSmall: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w500,
          fontSize: 14,
          letterSpacing: 0.1,
          color: _defaultFg,
          height: _lineHeight,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w400,
          fontSize: 16,
          letterSpacing: 0.5,
          color: _defaultFg,
          height: _lineHeight,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w400,
          fontSize: 14,
          letterSpacing: 0.25,
          color: _defaultFg,
          height: _lineHeight,
        ),
        bodySmall: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w400,
          fontSize: 12,
          letterSpacing: 0.4,
          color: colors.onSurfaceVariant,
          height: _lineHeight,
        ),
        labelLarge: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w500,
          fontSize: 14,
          letterSpacing: 1.0,
          color: _defaultFg,
          height: _lineHeight,
        ),
        labelMedium: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w500,
          fontSize: 12,
          letterSpacing: 0.5,
          color: _defaultFg,
          height: _lineHeight,
        ),
        labelSmall: TextStyle(
          fontFamily: 'NotoSansSC',
          fontWeight: FontWeight.w500,
          fontSize: 11,
          letterSpacing: 0.5,
          color: colors.onSurfaceVariant,
          height: _lineHeight,
        ),
      );

  /// 行高统一 1.4,纸感排版舒展、不拥挤。
  static const double _lineHeight = 1.4;
}
