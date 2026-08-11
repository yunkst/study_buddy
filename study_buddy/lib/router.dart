import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'features/focus/daily_report_page.dart';
import 'features/focus/focus_page.dart';
import 'features/home/home_page.dart';
import 'features/overlay/permission_guide_page.dart';
import 'features/plan/plan_detail_page.dart';

/// 全局 NavigatorState key：截图回流时（App 从后台 resumed）需要在无 widget 上下文处
/// 弹出 AI 面板，挂此 key 供 app.dart 取用。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
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
    ],
  );
}
