import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/router.dart';

Future<String> _resolve(
  WidgetTester tester,
  String loc, {
  required bool showOnboarding,
}) async {
  final router = buildRouter(showOnboarding: showOnboarding);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      // AppTheme.light 提供 PaperColors 扩展:OnboardingPage 的 PaperArticle
      // 依赖 theme.extension<PaperColors>(),缺主题会 null-check 崩溃。
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: router,
      ),
    ),
  );
  router.go(loc);
  // 单帧 pump 让 redirect 决策写入 currentConfiguration.uri；
  // 不用 pumpAndSettle —— HomePage 的 Provider 异步链在测试环境永不 settle。
  await tester.pump();
  await tester.pump();
  return router.routerDelegate.currentConfiguration.uri.toString();
}

void main() {
  testWidgets('showOnboarding=true, 访问 / → redirect 到 /onboarding',
      (tester) async {
    final loc = await _resolve(tester, '/', showOnboarding: true);
    expect(loc, '/onboarding');
  });

  testWidgets('showOnboarding=false, 访问 /onboarding → redirect 到 /',
      (tester) async {
    final loc = await _resolve(tester, '/onboarding', showOnboarding: false);
    expect(loc, '/');
  });

  testWidgets('showOnboarding=false, 访问 / → 放行（null）', (tester) async {
    final loc = await _resolve(tester, '/', showOnboarding: false);
    expect(loc, '/');
  });

  testWidgets('showOnboarding=true, 访问 /onboarding → 放行', (tester) async {
    final loc = await _resolve(tester, '/onboarding', showOnboarding: true);
    expect(loc, '/onboarding');
  });
}
