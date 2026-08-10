// 纸感学术主题层:亮色「日光纸」与暗色「夜读灯下纸」两套完整 ColorScheme。
// 所有色值逐字取自 task-2-spec.md §A/§B,不做任何调整。
library;

import 'package:flutter/material.dart';

/// 亮色「日光纸」ColorScheme:朱砂红主强调、米黄纸面、暖色阴影。
const ColorScheme lightColors = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFFB8472D),
  onPrimary: Color(0xFFFAF6EC),
  primaryContainer: Color(0xFFF0DBD0),
  onPrimaryContainer: Color(0xFF8F3520),
  secondary: Color(0xFF3A5A7A),
  onSecondary: Color(0xFFFAF6EC),
  secondaryContainer: Color(0xFFDDE6EF),
  onSecondaryContainer: Color(0xFF2A4259),
  tertiary: Color(0xFF5A7D4A),
  onTertiary: Color(0xFFFAF6EC),
  tertiaryContainer: Color(0xFFE6EEDE),
  onTertiaryContainer: Color(0xFF3F5A33),
  error: Color(0xFFB8472D),
  onError: Color(0xFFFAF6EC),
  errorContainer: Color(0xFFF0DBD0),
  onErrorContainer: Color(0xFF8F3520),
  surface: Color(0xFFF5F0E6),
  onSurface: Color(0xFF2C2620),
  onSurfaceVariant: Color(0xFF6B5D4F),
  surfaceContainerLowest: Color(0xFFFAF6EC),
  surfaceContainerLow: Color(0xFFF2ECDF),
  surfaceContainer: Color(0xFFEEE6D4),
  surfaceContainerHigh: Color(0xFFE8DFCA),
  surfaceContainerHighest: Color(0xFFEBE3D2),
  outline: Color(0xFFA89880),
  outlineVariant: Color(0xFFD9CFB8),
  inverseSurface: Color(0xFF2C2620),
  onInverseSurface: Color(0xFFF5F0E6),
  inversePrimary: Color(0xFFD9886A),
  scrim: Color(0xFF2C2620),
  // 暖色阴影:8 位十六进制,前两位 0x14 为 alpha(约 8%),后六位 0x4C3C28 为暖棕。
  shadow: Color(0x144C3C28),
);

/// 暗色「夜读灯下纸」ColorScheme:朱砂提亮降饱和、深墨棕纸面,保持暖调不冷灰。
const ColorScheme darkColors = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFD9664A),
  onPrimary: Color(0xFF3A1A10),
  primaryContainer: Color(0xFF6B2A18),
  onPrimaryContainer: Color(0xFFF5DCCF),
  secondary: Color(0xFF7BA0C0),
  onSecondary: Color(0xFF0F1F2E),
  secondaryContainer: Color(0xFF2A3F52),
  onSecondaryContainer: Color(0xFFCFDDE9),
  tertiary: Color(0xFF8FB07A),
  onTertiary: Color(0xFF16240E),
  tertiaryContainer: Color(0xFF2E4226),
  onTertiaryContainer: Color(0xFFD6E5C8),
  error: Color(0xFFE08070),
  onError: Color(0xFF3A1A10),
  errorContainer: Color(0xFF5A2418),
  onErrorContainer: Color(0xFFF5DCCF),
  surface: Color(0xFF1F1A14),
  onSurface: Color(0xFFE8DCC4),
  onSurfaceVariant: Color(0xFFB8A888),
  surfaceContainerLowest: Color(0xFF17130E),
  surfaceContainerLow: Color(0xFF251F18),
  surfaceContainer: Color(0xFF2B241C),
  surfaceContainerHigh: Color(0xFF332B22),
  surfaceContainerHighest: Color(0xFF3D3428),
  outline: Color(0xFF7A6A52),
  outlineVariant: Color(0xFF3D3428),
  inverseSurface: Color(0xFFE8DCC4),
  onInverseSurface: Color(0xFF1F1A14),
  inversePrimary: Color(0xFFB8472D),
  scrim: Color(0xFF000000),
  // 黑色阴影:0x99 为 alpha(60%)。
  shadow: Color(0x99000000),
);
