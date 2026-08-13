import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/providers/captured_image.dart';
import 'core/theme/paper_scaffold.dart';
import 'features/crop/image_crop_page.dart';
import 'features/external_qbank/ai_panel_sheet.dart';
import 'features/focus/daily_report_page.dart';
import 'features/focus/focus_page.dart';
import 'features/knowledge/knowledge_page.dart';
import 'features/knowledge/topic_detail_page.dart';
import 'features/logs/app_log_viewer_page.dart';
import 'features/logs/llm_log_detail_page.dart';
import 'features/logs/llm_log_viewer_page.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/plan/plan_detail_page.dart';
import 'features/review/review_session_page.dart';
import 'features/settings/prompt_editor_page.dart';
import 'features/settings/settings_page.dart';
import 'features/today/today_page.dart';

/// 全局 NavigatorState key：分享冷启动降级时（App 被杀后从分享菜单唤起）需要在无
/// widget 上下文处弹 AI 面板，挂此 key 供 share_intent_provider / app.dart 取用。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// 首启引导是否仍待显示。main() 预取 prefs 初始化，OnboardingPage._finish 翻转。
/// redirect 读它而非 build 期参数，确保 _finish 写 prefs 后 go('/today') 不被弹回。
final ValueNotifier<bool> onboardingActive = ValueNotifier<bool>(false);

GoRouter buildRouter({bool showOnboarding = false}) {
  // 把传入参数同步到 live 标志，redirect 读 onboardingActive.value 决策；
  // OnboardingPage._finish 写 prefs 成功后会翻转此标志，避免 redirect 把 go('/today') 弹回。
  onboardingActive.value = showOnboarding;
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/today',
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (onboardingActive.value && loc != '/onboarding') return '/onboarding';
      // 旧 '/' 路由已下线（StatefulShellRoute 接管为 /today）。
      if (!onboardingActive.value && loc == '/onboarding') return '/today';
      return null;
    },
    routes: [
      // Onboarding 在最前：redirect 按 onboardingActive 决策放行/弹回。
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingPage(),
      ),
      // 3 Tab 根壳：StatefulShellRoute.indexedStack 为每个 branch 保留独立导航栈，
      // 切 Tab 不重建页面，与 PaperScaffold 配合保留各 Tab 滚动/输入态。
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _RootShell(shell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/today',
                builder: (_, __) => const TodayPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/knowledge',
                builder: (_, __) => const KnowledgePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, __) => const SettingsPage(),
                routes: [
                  GoRoute(
                    path: 'prompt',
                    builder: (_, __) => const PromptEditorPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/plan/:id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          if (id == null) {
            // 非数字 id（deeplink/通知误传）：回 /today，避免 FormatException 红屏
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => context.go('/today'),
            );
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
        path: '/topic/:id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          if (id == null) {
            // 非数字 id（deeplink/通知误传）：回 /today，避免 FormatException 红屏
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => context.go('/today'),
            );
            return const SizedBox.shrink();
          }
          return TopicDetailPage(topicId: id);
        },
      ),
      GoRoute(
        path: '/review',
        builder: (context, state) => const ReviewSessionPage(),
      ),
      // 全屏 AI 对话页：顶层 GoRoute（root navigator 承载 → 全屏盖住底部导航）。
      // state.extra 透传 AiPanelLaunch（按引用传递，不序列化）：screenshot 非空 =
      // 拍题/分享冷启动预填截图；topicId 非空 = 知识点【为什么？】教学入口；两者皆空
      // = 纯文字入口（直接聊）。
      GoRoute(
        path: '/ai',
        builder: (context, state) {
          final launch = state.extra is AiPanelLaunch
              ? state.extra as AiPanelLaunch
              : const AiPanelLaunch();
          return AiChatPage(
            initialScreenshot: launch.screenshot,
            initialTopicId: launch.topicId,
          );
        },
      ),
      // 拍题裁剪页：state.extra 透传 Uint8List（按引用传递，不序列化），
      // 非 Uint8List（deeplink/误传）回 /today，避免红屏。
      GoRoute(
        path: '/crop',
        builder: (context, state) {
          final bytes = state.extra;
          if (bytes is! Uint8List) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => context.go('/today'),
            );
            return const SizedBox.shrink();
          }
          return ImageCropPage(sourceBytes: bytes);
        },
      ),
      GoRoute(
        path: '/logs/app',
        builder: (_, __) => const AppLogViewerPage(),
      ),
      GoRoute(
        path: '/logs/llm',
        builder: (_, __) => const LlmLogViewerPage(),
      ),
      GoRoute(
        path: '/logs/llm/:id',
        builder: (_, state) =>
            LlmLogDetailPage(recordId: state.pathParameters['id']!),
      ),
    ],
  );
}

/// 3 Tab 根壳：PaperScaffold（保留纸感渐变底）+ 底部 NavigationBar。
///
/// shell 由 StatefulShellRoute.indexedStack 提供；点击当前 Tab 再次跳到该 Tab
/// 根路由（initialLocation: true 弹回分支栈顶），与 Material 3 NavigationBar 语义一致。
class _RootShell extends StatelessWidget {
  const _RootShell({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) => shell.goBranch(
          i,
          initialLocation: i == shell.currentIndex,
        ),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '知识',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
