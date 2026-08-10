// 纸感学术主题层色值/角色锁定测试。
//
// 防止 token 被无意识修改:亮色 primary #B8472D(朱砂)和暗色 surface #1F1A14(夜读灯下纸)
// 是设计语言的两个锚点,任何改动必须显式决策。
//
// 也锁住一组语义成员:PaperColors 主品牌色 + AppTheme 各组件主题关键token。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:study_buddy/core/theme/app_colors.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/core/theme/paper_extension.dart';

void main() {
  group('亮色「日光纸」', () {
    test('primary 是朱砂红 #B8472D', () {
      expect(lightColors.primary, const Color(0xFFB8472D));
    });
    test('surface 是米黄纸 #F5F0E6', () {
      expect(lightColors.surface, const Color(0xFFF5F0E6));
    });
    test('onSurface 墨黑 13:1 高对比', () {
      expect(lightColors.onSurface, const Color(0xFF2C2620));
    });
    test('tertiary 是苔绿 #5A7D4A(印章/成功)', () {
      expect(lightColors.tertiary, const Color(0xFF5A7D4A));
    });
  });

  group('暗色「夜读灯下纸」', () {
    test('primary 是朱砂提亮 #D9664A', () {
      expect(darkColors.primary, const Color(0xFFD9664A));
    });
    test('surface 是深墨棕 #1F1A14', () {
      expect(darkColors.surface, const Color(0xFF1F1A14));
    });
    test('onSurface 米白 11:1 高对比', () {
      expect(darkColors.onSurface, const Color(0xFFE8DCC4));
    });
  });

  group('AppTheme 装配', () {
    test('AppTheme.light 拿到亮色 ColorScheme', () {
      expect(AppTheme.light.colorScheme.primary, const Color(0xFFB8472D));
      expect(AppTheme.light.brightness, Brightness.light);
    });
    test('AppTheme.dark 拿到暗色 ColorScheme', () {
      expect(AppTheme.dark.colorScheme.primary, const Color(0xFFD9664A));
      expect(AppTheme.dark.brightness, Brightness.dark);
    });
    test('AppTheme 注册 PaperColors extension', () {
      expect(AppTheme.light.extension<PaperColors>(), isNotNull);
      expect(AppTheme.dark.extension<PaperColors>(), isNotNull);
    });
    test('AppTheme 使用双字体基底(NotoSansSC)', () {
      expect(AppTheme.light.textTheme.bodyLarge?.fontFamily, 'NotoSansSC');
    });
    test('AppTheme 标题角色用衬线(NotoSerifSC)', () {
      expect(AppTheme.light.textTheme.displayLarge?.fontFamily, 'NotoSerifSC');
      expect(AppTheme.light.textTheme.titleLarge?.fontFamily, 'NotoSerifSC');
    });
  });

  group('PaperColors 品牌语义', () {
    test('亮色 stampRed = primary', () {
      expect(PaperColors.light.stampRed, const Color(0xFFB8472D));
      expect(PaperColors.light.stampRed, lightColors.primary);
    });
    test('亮色 gold 提示金 #B08938', () {
      expect(PaperColors.light.gold, const Color(0xFFB08938));
    });
    test('暗色 stampRed = dark primary', () {
      expect(PaperColors.dark.stampRed, const Color(0xFFD9664A));
      expect(PaperColors.dark.stampRed, darkColors.primary);
    });
  });
}
