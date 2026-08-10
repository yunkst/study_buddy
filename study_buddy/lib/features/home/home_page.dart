import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_update_provider.dart';
import '../../core/providers/database_provider.dart';
import '../../core/update/app_update_service.dart';
import '../../core/update/models/update_check_result.dart';
import '../../core/update/ui/app_update_dialog.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (db) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '地基已就绪 ✅\n数据库已连接。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('进入题库'),
                  onPressed: () => context.go('/external-qbank'),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('检查更新'),
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
