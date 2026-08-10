import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/knowledge_providers.dart';

class KnowledgeBasePage extends ConsumerStatefulWidget {
  const KnowledgeBasePage({super.key});
  @override
  ConsumerState<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends ConsumerState<KnowledgeBasePage> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<String> _path = []; // 当前分类路径，空表根级
  int? _currentCategoryId; // 当前层 parentId
  final List<int> _depthIds = []; // 逐级下钻保存的层级 id 链，面包屑回退用

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _keyword => _searchCtrl.text.trim();

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() {});
    });
  }

  void _drillDown(CategoryChild child) {
    setState(() {
      _path = [..._path, child.name];
      _depthIds.add(child.id);
      _currentCategoryId = child.id;
    });
  }

  /// 面包屑回退到指定深度。depth=0 回根级。
  void _goToDepth(int depth) {
    setState(() {
      _path = _path.sublist(0, depth);
      _depthIds.removeRange(depth, _depthIds.length);
      _currentCategoryId = depth == 0 ? null : _depthIds[depth - 1];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('知识库')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                hintText: '搜索知识点',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(child: _keyword.isEmpty ? _buildBrowse() : _buildSearch()),
        ],
      ),
    );
  }

  Widget _buildBrowse() {
    final childrenAsync = ref.watch(categoryChildrenProvider(_currentCategoryId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBreadcrumb(),
        Expanded(
          child: childrenAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorRetry(
              message: '加载失败: $e',
              onRetry: () => setState(() {}),
            ),
            data: (list) {
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    _currentCategoryId == null
                        ? '知识库还是空的，用悬浮窗截图让 AI 帮你存知识点'
                        : '这个分类下还没有知识点',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final child = list[i];
                  if (child.isCategory) {
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(child.name),
                      trailing: child.hasChildren
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: () => _drillDown(child),
                    );
                  }
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(child.name),
                    onTap: () => context.push('/topic/${child.id}'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBreadcrumb() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          TextButton(
            onPressed: _path.isEmpty
                ? null
                : () => _goToDepth(0),
            child: const Text('全部'),
          ),
          for (var i = 0; i < _path.length; i++)
            TextButton(
              onPressed: () => _goToDepth(i),
              child: Text(_path[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    final resultsAsync = ref.watch(knowledgeSearchProvider(_keyword));
    return resultsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorRetry(
        message: '搜索失败: $e',
        onRetry: () => setState(() {}),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const Center(
            child: Text('未找到相关知识点', style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, i) {
            final r = results[i];
            return ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(r.title),
              subtitle: Text(r.path.join(' / ')),
              onTap: () => context.push('/topic/${r.id}'),
            );
          },
        );
      },
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
