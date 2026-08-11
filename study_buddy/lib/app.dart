import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/screenshot_provider.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/focus_session_provider.dart';
import 'features/external_qbank/ai_panel_sheet.dart';
import 'router.dart';
import 'main.dart';

class StudyBuddyApp extends ConsumerStatefulWidget {
  const StudyBuddyApp({super.key});
  @override
  ConsumerState<StudyBuddyApp> createState() => _StudyBuddyAppState();
}

class _StudyBuddyAppState extends ConsumerState<StudyBuddyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 延迟到首帧后初始化（router 就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bootstrapOverlay(ref, context);
      // 恢复或清理上次未结束的专注会话
      ref.read(focusSessionProvider.notifier).recoverOrphan();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从设置返回 / 被截图拉回前台 → 重新检查待处理截图
    if (state == AppLifecycleState.resumed) {
      _checkPending();
    }
  }

  Future<void> _checkPending() async {
    final sp = ref.read(screenshotProvider);
    final pending = await sp.takePendingScreenshot();
    if (pending == null) return;
    // 截图回流：直接弹 AI 面板（不再写静态字段等 home 读取——home 的 initState 只在冷启动跑一次，
    // 热回流时 resumed 不重跑 initState，静态 pending 会被永久搁置 → 无动作）。
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      await showAiPanel(ctx, screenshot: pending);
    } else {
      // 兜底：context 不可用（极早期 resumed）→ 落静态字段，待 home 首帧消费
      PendingScreenshotStore.pending = pending;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Study Buddy',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: buildRouter(),
    );
  }
}