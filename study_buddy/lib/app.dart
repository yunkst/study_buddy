import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/screenshot_provider.dart';
import 'core/services/logger_service.dart';
import 'core/services/llm_logger/llm_logger.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/focus_session_provider.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 日志系统初始化（SP 加载历史 + LLM 日志目录）
      await LoggerService.instance.init();
      await LlmLogger.instance.initialize();
      LoggerService.instance.i('应用启动', category: LogCategory.general, tags: const ['app-start']);
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
    // 应用进入后台/失焦 → 主动 flush 日志，避免未持久化丢失
    if (state == AppLifecycleState.paused) {
      LoggerService.instance.flush();
    }
  }

  Future<void> _checkPending() async {
    final sp = ref.read(screenshotProvider);
    final pending = await sp.takePendingScreenshot();
    if (pending != null && mounted) {
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