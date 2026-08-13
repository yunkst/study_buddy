// 知识点详情：面包屑 → 标题 → 掌握度 → 引子 → 答案 → 关联 → 掌握度轨迹 + 底部三操作。
//
// 数据加载用 FutureBuilder 直连 study_engine repos（topic / category path / edge /
// mastery timeline），掌握度徽标走 masteryOfProvider（FSRS schedule 派生），与
// knowledge_page 的行内 _MasteryChip 同源。底部「问 AI 深度交流」在 v1 先接
// showAiPanel 无截图入口（/topic/:id/chat 路由尚未存在，留待后续任务）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/widgets/markdown_latex.dart';
import '../external_qbank/ai_panel_sheet.dart';
import 'knowledge_providers.dart';

/// 单次数据快照：topic + 面包屑 + 关联 + 轨迹。
class _TopicDetail {
  const _TopicDetail({
    required this.topic,
    required this.breadcrumb,
    required this.edges,
    required this.timeline,
  });

  final Topic topic;
  final List<String> breadcrumb;
  final List<TopicEdgeView> edges;
  final List<MasteryLog> timeline;
}

/// 知识点详情页，由路由 `/topic/:id` 注入 [topicId]。
class TopicDetailPage extends ConsumerStatefulWidget {
  const TopicDetailPage({super.key, required this.topicId});

  final int topicId;

  @override
  ConsumerState<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends ConsumerState<TopicDetailPage> {
  /// 详情数据 future。每次构造后由 initState 首次赋值；编辑保存成功后于 setState
  /// 内重新赋值以触发 FutureBuilder 重查（不能 `late final`：旧值已 done，
  /// 重建 build 不会重新发查询，页面会一直显示旧 summary）。
  late Future<_TopicDetail> _detailFuture;

  @override
  void initState() {
    super.initState();
    _detailFuture = _loadDetail();
  }

  Future<_TopicDetail> _loadDetail() async {
    final db = await ref.read(databaseProvider.future);
    final topic = await TopicRepository(db).findById(widget.topicId);
    if (topic == null) {
      // 数据源缺失：查询类抛错，让 FutureBuilder 走错误态「知识点不存在」。
      throw ArgumentError('topic $widget.topicId not found');
    }
    final breadcrumb = await CategoryRepository(db).pathOf(topic.categoryId);
    final edges = await TopicEdgeRepository(db).findByTopic(widget.topicId);
    final timeline = await MasteryRepository(db).timeline(widget.topicId);
    return _TopicDetail(
      topic: topic,
      breadcrumb: breadcrumb,
      edges: edges,
      timeline: timeline,
    );
  }

  /// 编辑答案：简单 AlertDialog + TextFormField（预填 summary）→ updateSummary →
  /// 成功重新赋值 `_detailFuture` 触发 FutureBuilder 重查，失败 SnackBar 提示不崩。
  Future<void> _editSummary(String currentSummary) async {
    final controller = TextEditingController(text: currentSummary);
    final newSummary = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑答案'),
        content: TextFormField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          decoration: const InputDecoration(hintText: '粘贴新的答案本体，支持 Markdown/LaTeX'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newSummary == null || !mounted) return;

    final db = await ref.read(databaseProvider.future);
    try {
      await TopicRepository(db).updateSummary(widget.topicId, newSummary);
      if (!mounted) return;
      setState(() {
        _detailFuture = _loadDetail();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final masteryAsync = ref.watch(masteryOfProvider(widget.topicId));

    return PaperScaffold(
      appBar: AppBar(title: const Text('知识点')),
      body: SafeArea(
        child: FutureBuilder<_TopicDetail>(
          future: _detailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            if (snapshot.hasError) {
              return _MissingHint(
                message: '知识点不存在',
                onBack: () => context.pop(),
              );
            }
            final detail = snapshot.data!;
            final topic = detail.topic;
            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              children: [
                if (detail.breadcrumb.isNotEmpty)
                  _Breadcrumb(segments: detail.breadcrumb),
                const SizedBox(height: 8),
                Text(
                  topic.title,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                _MasteryBadge(
                  status: masteryAsync.maybeWhen(
                    data: (m) => m,
                    orElse: () => MasteryStatus.unknown,
                  ),
                ),
                // 互动式教学入口【为什么？】：带 topicId 进入 AI 对话，AI 自动从该知识点
                // 诞生的具体场景/解决的问题出发，用启发式方式引导用户理解。
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  key: const ValueKey('why-button'),
                  onPressed: () => showAiPanel(context, topicId: widget.topicId),
                  icon: const Icon(Icons.emoji_objects_outlined),
                  label: const Text(
                    '为什么？',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const _SectionLabel('引子'),
                MarkdownLatex(data: topic.question, selectable: true),
                const _SectionLabel('答案'),
                MarkdownLatex(data: topic.summary, selectable: true),
                if (detail.edges.isNotEmpty) ...[
                  const _SectionLabel('关联'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final edge in detail.edges)
                        _EdgeChip(
                          type: edge.type,
                          title: edge.otherTitle,
                          onTap: () => context.push('/topic/${edge.otherId}'),
                        ),
                    ],
                  ),
                ],
                if (detail.timeline.isNotEmpty) ...[
                  const _SectionLabel('掌握度轨迹'),
                  _Timeline(timeline: detail.timeline),
                ],
                const SizedBox(height: 24),
                // 底部三操作。背诵/编辑 固定；问 AI 已放 AppBar actions。
                OutlinedButton.icon(
                  onPressed: () => context.push('/review'),
                  icon: const Icon(Icons.replay),
                  label: Text('背诵'),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _editSummary(topic.summary),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 面包屑：onSurfaceVariant 小字，当前段加深。
///
/// 注：/knowledge Tab 无分类 deep-link 路由（分类树是页面内状态），v1 先做展示性
/// 面包屑，不做可点击段；待分类路由落地后再接跳转。
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.segments});

  final List<String> segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0)
            Text(
              '›',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Text(
              segments[i],
              style: theme.textTheme.bodySmall?.copyWith(
                color: i == segments.length - 1
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: i == segments.length - 1
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 掌握度徽标：配色与 _MasteryChip 同源（tertiary/primary/error/outline）。
class _MasteryBadge extends StatelessWidget {
  const _MasteryBadge({required this.status});

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
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1),
          color: color.withValues(alpha: 0.08),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 关联芯片：type 前置/相关，点按进对端详情。
class _EdgeChip extends StatelessWidget {
  const _EdgeChip({required this.type, required this.title, required this.onTap});

  final String type;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    final label = type == 'prerequisite' ? '前置' : '相关';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: rule ?? theme.colorScheme.outlineVariant, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: theme.textTheme.labelMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// 掌握度轨迹：逐行「日期 + status 中文 + 可选 reason」。
class _Timeline extends StatelessWidget {
  const _Timeline({required this.timeline});

  final List<MasteryLog> timeline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final log in timeline)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: rule ?? theme.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(log.changedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusLabel(log.status),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (log.reason != null && log.reason!.isNotEmpty)
                        Text(
                          log.reason!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _statusLabel(MasteryStatus status) => switch (status) {
        MasteryStatus.mastered => '已掌握',
        MasteryStatus.learning => '学习中',
        MasteryStatus.weak => '待加强',
        MasteryStatus.unknown => '未学',
      };

  /// yyyy-MM-dd HH:mm，避免依赖 intl 格式化（精简依赖）。
  String _label(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// 纸感小节标签。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: rule ?? theme.colorScheme.outlineVariant, width: 2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}

/// 知识点不存在（被删）：提示 + 返回按钮。
class _MissingHint extends StatelessWidget {
  const _MissingHint({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onBack, child: const Text('返回')),
        ],
      ),
    );
  }
}