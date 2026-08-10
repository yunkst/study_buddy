import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/app_update_provider.dart';
import '../../core/providers/database_provider.dart';
import '../../core/providers/plan_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../core/update/app_update_service.dart';
import '../../core/update/models/update_check_result.dart';
import '../../core/update/ui/app_update_dialog.dart';
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../../features/plan/plan_chat_sheet.dart';
import '../../main.dart' show PendingScreenshotStore;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool? _overlayGranted;

  @override
  void initState() {
    super.initState();
    _checkPermission();
    _consumePendingScreenshot();
  }

  Future<void> _checkPermission() async {
    final granted = await ref.read(screenshotProvider).checkOverlayPermission();
    if (mounted) setState(() => _overlayGranted = granted);
    if (granted) {
      await ref.read(screenshotProvider).showOverlay();
    }
  }

  Future<void> _consumePendingScreenshot() async {
    // 冷启动降级：弹出待处理截图的 AI 面板
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null) {
        PendingScreenshotStore.pending = null;
        if (mounted) await showAiPanel(context, screenshot: pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dbAsync = ref.watch(databaseProvider);
    final plansAsync = ref.watch(planListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (_) => plansAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载计划失败: $e')),
          data: (plans) => RefreshIndicator(
            onRefresh: () async => ref.invalidate(planListProvider),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('我的学习计划', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...plans.map((p) => _PlanCard(plan: p, onTap: () => context.go('/plan/${p.id}'))),
                if (plans.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('还没有计划，新建一个吧', style: TextStyle(color: Colors.grey.shade600))),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('新建计划'),
                  onPressed: () async {
                    await showPlanChat(context);
                    ref.invalidate(planListProvider);
                  },
                ),
                const SizedBox(height: 24),
                // 悬浮窗状态降到底部次要区
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_overlayGranted == true ? Icons.screenshot_monitor : Icons.screenshot_monitor_outlined,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      _overlayGranted == null ? '检查悬浮窗权限中...' : _overlayGranted == true ? '悬浮窗已开启' : '悬浮窗未开启',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ],
                ),
                if (_overlayGranted == false)
                  TextButton(
                    onPressed: () => context.go('/permission-guide'),
                    child: const Text('去开启悬浮窗权限', style: TextStyle(fontSize: 11)),
                  ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.system_update_alt, size: 14),
                    label: const Text('检查更新', style: TextStyle(fontSize: 11)),
                    onPressed: () => _checkForUpdate(context, ref),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context, WidgetRef ref) async {
    final service = ref.read(appUpdateServiceProvider);
    final preview = await AppUpdateService.isPreviewChannelEnabled();
    final result = await service.checkForUpdateDetailed(
      forceCheck: true,
      includePrerelease: preview,
    );
    if (!context.mounted) return;
    switch (result) {
      case AppUpdateAvailable(:final version):
        await showAppUpdateDialog(context, version: version, updateService: service);
      case AppUpdateUpToDate():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已是最新版本')),
        );
      case AppUpdateCheckFailed(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查失败：$reason')),
        );
    }
  }
}

class _PlanCard extends ConsumerWidget {
  const _PlanCard({required this.plan, required this.onTap});
  final Plan plan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = plan;
    return Card(
      child: ListTile(
        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('考试 ${p.examDate.year}/${p.examDate.month}/${p.examDate.day} · 目标 ${p.target}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
