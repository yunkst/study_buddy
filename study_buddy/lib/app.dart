import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/chat_session_provider.dart';
import 'core/providers/share_intent_provider.dart';
import 'core/providers/theme_mode_provider.dart';
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
  /// 接收 EventChannel(`study_buddy/share`) 分享字节流；dispose 时取消避免泄漏。
  StreamSubscription<dynamic>? _shareSub;

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
      // 启动分享接收订阅：Native 冷/热路径统一汇入 EventChannel stream，
      // 收到 bytes → shareIntentProvider，resumed 时由 _promptShareIfAny 弹 AI 面板。
      _shareSub = bootstrapShareIntent(
        notifier: ref.read(shareIntentProvider.notifier),
      );
      // 恢复或清理上次未结束的专注会话
      ref.read(focusSessionProvider.notifier).recoverOrphan();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 应用回前台：检查分享图片（外部 App 在 App 已在前台时继续分享触发）。
      _promptShareIfAny();
    } else if (state == AppLifecycleState.paused) {
      // 应用进入后台/失焦 → 主动 flush 日志，避免未持久化丢失
      LoggerService.instance.flush();
    } else if (state == AppLifecycleState.detached) {
      // App 引擎即将销毁 → 清空内存会话。
      // detached 在 Android/iOS 不会在系统强杀时触发（强杀时进程直接死亡，
      // 下次冷启动 ProviderScope 重建本就是空白），故这不是 100% 可靠的清空点；
      // 但凡能触发，都能避免「临时 detach 后又 attach」期间复用陈旧消息。
      ref.read(currentChatProvider.notifier).clear();
    }
  }

  /// 取并消费 shareIntentProvider 的图片。
  /// - 返回 true：有消费（弹 AI 面板）。
  /// - 返回 false：无待处理（普通回前台）。
  Future<bool> _promptShareIfAny() async {
    final shot = ref.read(shareIntentProvider.notifier).consume();
    if (shot == null) return false;
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      await showAiPanel(ctx, screenshot: shot);
    } else {
      // 兜底：context 不可用（极早期 resumed）→ 落静态字段，待 TodayPage 首帧消费
      PendingScreenshotStore.pending = shot;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '时习',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // 偏好异步加载期间回退跟随系统(与改动前硬编码一致,无闪烁);
      // 加载完成后 ref.watch 驱动 MaterialApp 重建切到用户选择。
      themeMode: ref.watch(themeModeProvider).value ?? ThemeMode.system,
      routerConfig: buildRouter(showOnboarding: widget.showOnboarding),
    );
  }
}