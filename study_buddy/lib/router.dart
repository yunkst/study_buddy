import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'features/focus/daily_report_page.dart';
import 'features/focus/focus_page.dart';
import 'features/home/home_page.dart';
import 'features/overlay/permission_guide_page.dart';
import 'features/plan/plan_detail_page.dart';
import 'features/settings/settings_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
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
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsPage(),
      ),
    ],
  );
}
