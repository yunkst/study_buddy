import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/database_provider.dart';

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
        data: (db) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '地基已就绪 ✅\n数据库已连接。\n\n'
              '（业务功能将在后续子项目迭代中加入）',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
