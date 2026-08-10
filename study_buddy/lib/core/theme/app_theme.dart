// 纸感学术主题层:AppTheme 组装。
// 把 ColorScheme + TextTheme + PaperColors + 各组件主题组装成 ThemeData。
// 亮暗两套静态 getter,供 Task 3 接入 app.dart。
// 组装骨架取自 task-2-spec.md §E,API 已按当前 Flutter SDK(3.35.7)核对。
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';
import 'paper_extension.dart';

/// 纸感学术主题入口。
///
/// ```dart
/// MaterialApp(
///   theme: AppTheme.light,
///   darkTheme: AppTheme.dark,
/// )
/// ```
class AppTheme {
  AppTheme._();

  /// 亮色「日光纸」主题。
  static ThemeData get light =>
      _build(lightColors, PaperColors.light, Brightness.light);

  /// 暗色「夜读灯下纸」主题。
  static ThemeData get dark =>
      _build(darkColors, PaperColors.dark, Brightness.dark);

  static ThemeData _build(
    ColorScheme colors,
    PaperColors paper,
    Brightness brightness,
  ) {
    final typography = AppTypography(colors, brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      brightness: brightness,
      fontFamily: 'NotoSansSC',
      textTheme: typography.textTheme,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: typography.textTheme.titleLarge,
      ),
      // 当前 Flutter SDK(3.35.7)已弃用 CardTheme,正确 API 为 CardThemeData。
      cardTheme: CardThemeData(
        color: colors.surfaceContainerLowest,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.onSurface, // 墨黑主按钮
          foregroundColor: colors.surface,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          textStyle: typography.textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: colors.primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: colors.outline),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        labelStyle: typography.textTheme.bodyMedium,
        hintStyle: typography.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: colors.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.onSurface,
        contentTextStyle:
            typography.textTheme.bodyMedium?.copyWith(color: colors.surface),
        behavior: SnackBarBehavior.floating,
      ),
      extensions: [paper],
    );
  }
}
