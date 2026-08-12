import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/screenshot_provider.dart';
import 'core/services/logger_service.dart';
import 'core/services/llm_logger/llm_logger.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/focus_session_provider.dart';
import 'features/external_qbank/ai_panel_sheet.dart';
import 'router.dart';
import 'main.dart';

class StudyBuddyApp extends ConsumerStatefulWidget {
  const StudyBuddyApp({super.key, required this.showOnboarding});
  final bool showOnboarding;
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
      if (mounted) bootstrapOverlay(ref, context);
      // 恢复或清理上次未结束的专注会话
      ref.read(focusSessionProvider.notifier).recoverOrphan();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 截图回流场景：launchMainApp 拉回前台 → _checkPending 消费 pending → 不隐藏悬浮球。
      // 非截图回流：App 回前台 → 隐藏悬浮球。
      _handleResumed();
    } else if (state == AppLifecycleState.paused) {
      // 进后台：恢复悬浮球（轻量 ACTION_SHOW_OVERLAY，保留 FGS 通知）。
      // 相机/相册 Activity 期间由 pickImage 置 suppressOverlayOnPauseProvider=true 抑制。
      if (!ref.read(suppressOverlayOnPauseProvider)) {
        ref.read(screenshotProvider).showOverlay();
      }
      // 应用进入后台/失焦 → 主动 flush 日志，避免未持久化丢失
      LoggerService.instance.flush();
    }
  }

  Future<void> _handleResumed() async {
    final consumed = await _checkPending();
    if (!consumed) {
      // 非截图回流：App 回前台，隐藏悬浮球（轻量 ACTION_HIDE_OVERLAY，保留 FGS 通知）。
      ref.read(screenshotProvider).hideOverlay();
    }
    // 截图回流：面板已弹，悬浮球保持截图前的隐藏态（triggerScreenshot 已 hideOverlay）。
  }

  /// 取并消费待处理截图。
  /// - 返回 true：有 pending 已消费（截图回流场景），调用方不应再 hideOverlay。
  /// - 返回 false：无 pending（普通回前台），调用方应 hideOverlay。
  Future<bool> _checkPending() async {
    final sp = ref.read(screenshotProvider);
    final pending = await sp.takePendingScreenshot();
    if (pending == null) return false;
    // 截图回流：直接弹 AI 面板（不再写静态字段等 home 读取——home 的 initState 只在冷启动跑一次，
    // 热回流时 resumed 不重跑 initState，静态 pending 会被永久搁置 → 无动作）。
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      await showAiPanel(ctx, screenshot: pending);
    } else {
      // 兜底：context 不可用（极早期 resumed）→ 落静态字段，待 home 首帧消费
      PendingScreenshotStore.pending = pending;
    }
    return true;
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
      routerConfig: buildRouter(showOnboarding: widget.showOnboarding),
    );
  }
}