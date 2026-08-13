// 知识 Tab：分类树下钻 + 搜索 + 知识点列表。
//
// 替换原占位 stub。通过 Riverpod providers 驱动分类树（categoryChildrenProvider）、
// 某分类下知识点（topicsInCategoryProvider）、知识搜索（topicSearchProvider）与
// 掌握度（masteryOfProvider）。行内「下次复习时间」由本文件私有的 _scheduleOfProvider
// 从 TopicSchedule.dueAt 简单派生（未排期/到期），避免触发 Task 5.1 的 provider 改动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/topic_schedule_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import 'knowledge_providers.dart';

/// 各 topic 的 FSRS 调度行（可在文件内私有派生 dueAt；不存在返回 null）。
///
/// 刻意放在本文件而不并入 knowledge_providers.dart，避免触碰 Task 5.1 已 review 的接口。
final _scheduleOfProvider = FutureProvider.family<TopicSchedule?, int>(
  (ref, topicId) async {
    final repo = await ref.watch(topicScheduleRepositoryProvider.future);
    return repo.findByTopic(topicId);
  },
);

/// 知识 Tab 根页：顶部搜索框 + 分类树下钻/知识点列表。
class KnowledgePage extends ConsumerStatefulWidget {
  const KnowledgePage({super.key});

  @override
  ConsumerState<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends ConsumerState<KnowledgePage> {
  /// 当前所在分类；null = 根（显示顶级分类入口）。
  int? _selectedCategoryId;

  /// 搜索关键字；非空即进入搜索态，覆盖分类树。
  String _keyword = '';

  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onKeywordChanged(String v) {
    setState(() => _keyword = v.trim());
  }

  void _enterCategory(int? id) {
    setState(() => _selectedCategoryId = id);
  }

  @override
  Widget build(BuildContext context) {
    final searching = _keyword.isNotEmpty;
    return PaperScaffold(
      appBar: AppBar(title: const Text('知识')),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchField(),
            Expanded(
              child: searching ? _buildSearchList() : _buildCategoryTree(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onKeywordChanged,
        decoration: InputDecoration(
          hintText: '搜索知识点…',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: rule ?? theme.colorScheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: rule ?? theme.colorScheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
          ),
        ),
      ),
    );
  }

  /// 搜索态：topicSearchProvider(_keyword) 列表。
  Widget _buildSearchList() {
    final searchAsync = ref.watch(topicSearchProvider(_keyword));
    return searchAsync.when(
      loading: () => const _CenterBusy(),
      error: (e, _) => _ErrorHint('搜索失败: $e'),
      data: (result) {
        if (result.items.isEmpty) {
          return const _EmptyHint('没有匹配的知识点');
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          children: [
            for (final item in result.items)
              _TopicRow(
                key: ValueKey('search-${item.id}'),
                topicId: item.id,
                title: item.title,
              ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  /// 分类树下钻视图：根(null)显示顶级分类；已选中显示「返回上级」+ 知识点列表。
  Widget _buildCategoryTree() {
    if (_selectedCategoryId == null) {
      return _buildRootCategories();
    }
    return _buildSelectedCategory(_selectedCategoryId!);
  }

  /// 根：只显示顶级分类入口（下钻后才有知识点列表）。
  Widget _buildRootCategories() {
    final childrenAsync = ref.watch(categoryChildrenProvider(null));
    return childrenAsync.when(
      loading: () => const _LoadingBusy(),
      error: (e, _) => _Error(message: '加载分类失败: $e'),
      data: (categories) {
        if (categories.isEmpty) {
          return const _EmptyHint('还没有分类');
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          children: [
            for (final c in categories)
              _CategoryRow(category: c, onTap: c.id == null ? null : () => _enterCategory(c.id)),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  /// 已选中分类：顶部「返回上级」+ 子分类入口 + 该分类直接挂载的知识点。
  ///
  /// 支持无限层下钻：分类可逐级进入（数学 → 高等数学 → 极限…），
  /// 知识点挂在任意深度都能通过浏览到达（修复 agent 按嵌套 path 建知识点
  /// 后浏览不到的问题）。子分类与直挂知识点皆空时才提示空态。
  Widget _buildSelectedCategory(int categoryId) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    final childrenAsync = ref.watch(categoryChildrenProvider(categoryId));
    final topicsAsync = ref.watch(topicsInCategoryProvider(categoryId));
    final hasChildren = childrenAsync.maybeWhen(
      data: (c) => c.isNotEmpty,
      orElse: () => false,
    );
    final hasTopics = topicsAsync.maybeWhen(
      data: (t) => t.isNotEmpty,
      orElse: () => false,
    );
    final showEmpty = !hasChildren && !hasTopics;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      children: [
        // 返回上级：置 null 回到根。
        InkWell(
          key: const ValueKey('back-to-root'),
          onTap: () => _enterCategory(null),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: rule ?? theme.colorScheme.outlineVariant, width: 0.6),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.arrow_upward, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  '返回上级',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        ..._categorySection(childrenAsync),
        if (showEmpty) ...[
          const SizedBox(height: 24),
          _EmptyHint('该分类暂无知识点'),
        ],
        ..._topicSection(topicsAsync),
        const SizedBox(height: 24),
      ],
    );
  }

  /// 当前分类的直接子分类入口（可继续下钻）。
  List<Widget> _categorySection(AsyncValue<List<Category>> childrenAsync) {
    return childrenAsync.when(
      loading: () => const [SizedBox(height: 16), _LoadingBusy(compact: true)],
      error: (e, _) => [_Error(message: '加载分类失败: $e')],
      data: (children) => [
        for (final c in children)
          _CategoryRow(category: c, onTap: () => _enterCategory(c.id)),
      ],
    );
  }

  List<Widget> _topicSection(AsyncValue<List<Topic>> topicsAsync) {
    return topicsAsync.when(
      loading: () => const [SizedBox(height: 40), _LoadingBusy(compact: true)],
      error: (e, _) => [_Error(message: '加载知识点失败: $e')],
      data: (topics) => [
        for (final t in topics)
          _TopicRow(
            key: ValueKey('topic-${t.id}'),
            topicId: t.id!,
            title: t.title,
          ),
      ],
    );
  }
}

/// 分类行：文件夹图标 + 名称 + 右箭头，点按进入该分类（下钻）。
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, required this.onTap});

  final Category category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    return InkWell(
      key: ValueKey('cat-${category.id}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: rule ?? theme.colorScheme.outlineVariant, width: 0.6),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 22, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                category.name,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 知识行：标题 + 掌握度标签 + 下次复习时间提示，点按进详情。
class _TopicRow extends ConsumerWidget {
  const _TopicRow({super.key, required this.topicId, required this.title});

  final int topicId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    final masteryAsync = ref.watch(masteryOfProvider(topicId));
    final scheduleAsync = ref.watch(_scheduleOfProvider(topicId));

    return InkWell(
      onTap: () => context.push('/topic/$topicId'),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: rule ?? theme.colorScheme.outlineVariant, width: 0.6),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 22, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    scheduleAsync.when(
                      data: (s) => _dueText(s?.dueAt),
                      loading: () => '…',
                      error: (_, __) => '排期读取失败',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _MasteryChip(status: masteryAsync.maybeWhen(
              data: (m) => m,
              orElse: () => MasteryStatus.unknown,
            )),
            Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }

  /// 由 dueAt 派生「x/y 到期」或「未排期」。
  String _dueText(DateTime? due) {
    if (due == null) return '未排期';
    return '${due.month}/${due.day} 到期';
  }
}

/// 纸感小圆角掌握度标签：仅描边/文字用 colorScheme 语义色，不硬编码。
class _MasteryChip extends StatelessWidget {
  const _MasteryChip({required this.status});

  final MasteryStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (status) {
      MasteryStatus.mastered => theme.colorScheme.tertiary,
      MasteryStatus.learning => theme.colorScheme.primary,
      MasteryStatus.weak => theme.colorScheme.error,
      MasteryStatus.unknown => theme.colorScheme.outline,
    };
    final label = switch (status) {
      MasteryStatus.mastered => '已掌握',
      MasteryStatus.learning => '学习中',
      MasteryStatus.weak => '待加强',
      MasteryStatus.unknown => '未学',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 行内小加载指示。
class _LoadingBusy extends StatelessWidget {
  const _LoadingBusy({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: SizedBox(
          width: compact ? 18 : 24,
          height: compact ? 18 : 24,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// 居中加载占位。
class _CenterBusy extends StatelessWidget {
  const _CenterBusy();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}

/// 空态提示。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 错误提示（List 子项用，含上下留白）。
class _Error extends StatelessWidget {
  const _Error({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      ),
    );
  }
}

/// 错误提示（整块搜索态用）。
class _ErrorHint extends StatelessWidget {
  const _ErrorHint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
        ),
      ),
    );
  }
}