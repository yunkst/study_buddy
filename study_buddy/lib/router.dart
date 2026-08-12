import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'features/focus/daily_report_page.dart';
import 'features/focus/focus_page.dart';
import 'features/home/home_page.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/overlay/permission_guide_page.dart';
import 'features/plan/plan_detail_page.dart';

/// 全局 NavigatorState key：截图回流时（App 从后台 resumed）需要在无 widget 上下文处
/// 弹出 AI 面板，挂此 key 供 app.dart 取用。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// 首启引导是否仍待显示。main() 预取 prefs 初始化，OnboardingPage._finish 翻转。
/// redirect 读它而非 build 期参数，确保 _finish 写 prefs 后 go('/') 不被弹回。
final ValueNotifier<bool> onboardingActive = ValueNotifier<bool>(false);

GoRouter buildRouter({bool showOnboarding = false}) {
  // 把传入参数同步到 live 标志，redirect 读 onboardingActive.value 决策；
  // OnboardingPage._finish 写 prefs 成功后会翻转此标志，避免 redirect 把 go('/') 弹回。
  onboardingActive.value = showOnboarding;
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (onboardingActive.value && loc != '/onboarding') return '/onboarding';
      if (!onboardingActive.value && loc == '/onboarding') return '/';
      return null;
    },
    routes: [
      // Onboarding 在最前:若需要且当前是 /onboarding,放行;否则由 redirect 接管(Task 7 加)。
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingPage(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: '/permission-guide',
        builder: (context, state) => const PermissionGuidePage(),
      ),
      GoRoute(
        path: '/plan/:id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          if (id == null) {
            // 非数字 id（deeplink/通知误传）：回首页，避免 FormatException 红屏
            WidgetsBinding.instance.addPostFrameCallback((_) => context.go('/'));
            return const SizedBox.shrink();
          }
          return PlanDetailPage(planId: id);
        },
      ),
      GoRoute(
        path: '/focus',
        builder: (context, state) => const FocusPage(),
      ),
      GoRoute(
        path: '/daily-report',
        builder: (context, state) => const DailyReportPage(),
      ),
    ],
  );
}
