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
  // 不用 pumpAndSettle —— shell 页的 Provider 异步链在测试环境永不 settle。
  await tester.pump();
  await tester.pump();
  return router.routerDelegate.currentConfiguration.uri.toString();
}

void main() {
  // 3.1 起 shell 接管落地页，初始路由由 / 改为 /today；redirect 的"非 onboarding
  // 落点"也由 / 改为 /today。下面四例覆盖 redirect 的两条分支 + 两条放行分支。
  testWidgets('showOnboarding=true, 访问 /today → redirect 到 /onboarding',
      (tester) async {
    final loc = await _resolve(tester, '/today', showOnboarding: true);
    expect(loc, '/onboarding');
  });

  testWidgets('showOnboarding=false, 访问 /onboarding → redirect 到 /today',
      (tester) async {
    final loc = await _resolve(tester, '/onboarding', showOnboarding: false);
    expect(loc, '/today');
  });

  testWidgets('showOnboarding=false, 访问 /today → 放行（null）', (tester) async {
    final loc = await _resolve(tester, '/today', showOnboarding: false);
    expect(loc, '/today');
  });

  testWidgets('showOnboarding=true, 访问 /onboarding → 放行', (tester) async {
    final loc = await _resolve(tester, '/onboarding', showOnboarding: true);
    expect(loc, '/onboarding');
  });
}
