import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/knowledge_providers.dart';

class TopicDetailPage extends ConsumerWidget {
  const TopicDetailPage({super.key, required this.topicId});
  final int topicId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(topicDetailProvider(topicId));
    return Scaffold(
      appBar: AppBar(title: const Text('知识点')),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $e'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(topicDetailProvider(topicId)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (detail) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(detail.topic.title,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(detail.path.join(' / '),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const Divider(height: 24),
            const Text('📖 引子', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(detail.topic.question,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            const Text('💡 答案', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(detail.topic.summary,
                style: Theme.of(context).textTheme.bodyLarge),
            if (detail.edges.isNotEmpty) ...[
              const Divider(height: 32),
              const Text('🔗 关联', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...detail.edges.map((e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      e.type == 'prerequisite'
                          ? Icons.subdirectory_arrow_right
                          : Icons.link,
                      size: 20,
                    ),
                    title: Text(e.otherTitle),
                    subtitle: Text(
                      e.type == 'prerequisite' ? '前置依赖' : '相关',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => context.push('/topic/${e.otherId}'),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}
