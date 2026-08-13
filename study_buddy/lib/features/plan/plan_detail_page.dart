import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/plan_provider.dart';
import '../../core/theme/paper_extension.dart';
import 'assessment_entry_sheet.dart';
import 'day_task_calendar.dart';
import 'plan_chat_sheet.dart';
import 'progress_chart.dart';

class PlanDetailPage extends ConsumerWidget {
  const PlanDetailPage({super.key, required this.planId});
  final int planId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(planDetailProvider(planId));
    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(data: (d) => Text(d.plan.name), orElse: () => const Text('计划详情')),
        actions: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: '和 AI 调整',
            onPressed: () async {
              final name = detailAsync.maybeWhen(data: (d) => d.plan.name, orElse: () => null);
              await showPlanChat(context, planId: planId, planName: name);
              // 对话可能改了计划，刷新
              if (!context.mounted) return;
              ref.invalidate(planDetailProvider(planId));
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除计划',
            onPressed: () async {
              final name = detailAsync.maybeWhen(data: (d) => d.plan.name, orElse: () => null);
              if (name == null) return;
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('删除计划'),
                  content: Text('确定删除「$name」及其所有节点和测评记录？此操作不可撤销。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('删除')),
                  ],
                ),
              );
              if (ok != true) return;
              final repo = await ref.read(planRepositoryAsyncProvider.future);
              await repo.deletePlan(planId);
              if (!context.mounted) return;
              ref.invalidate(planListProvider);
              context.go('/today');
            },
          ),
        ],
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (detail) {
          final cs = Theme.of(context).colorScheme;
          final paper = Theme.of(context).extension<PaperColors>()!;
          final plan = detail.plan;
          final milestones = detail.milestones;
          final assessments = detail.assessments;
          final doneCount = milestones.where((m) => m.status == 'done').length;

          // 提醒横幅：距上次测评>14天
          final lastA = assessments.isNotEmpty ? assessments.last : null;
          final reminderDays = lastA == null ? 0 : DateTime.now().difference(lastA.assessedAt).inDays;
          final showReminder = reminderDays > 14;

          // 目标线分数：从 target 抽数字
          final targetScore = _extractScore(plan.target);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (showReminder)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: paper.goldContainer, borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: paper.gold),
                      const SizedBox(width: 8),
                      Expanded(child: Text('距上次测评已 $reminderDays 天，建议做一次测评。', style: TextStyle(color: paper.onGold))),
                    ],
                  ),
                ),
              // 曲线
              const Text('进步曲线', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ProgressChart(assessments: assessments, targetScore: targetScore),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('记录测评'),
                  onPressed: () async {
                    final ok = await showAssessmentEntry(context, planId);
                    if (!context.mounted) return;
                    if (ok == true) ref.invalidate(planDetailProvider(planId));
                  },
                ),
              ),
              const SizedBox(height: 16),
              // 里程碑时间线
              Text('里程碑（$doneCount/${milestones.length}）', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...milestones.map((m) {
                final isDone = m.status == 'done';
                final daysTo = m.targetDate.difference(DateTime.now()).inDays;
                final expired = daysTo < 0;
                // 临期仅指未来 0~3 天；过期单独走"已过期"分支，不显示负数天数
                final near = !isDone && !expired && daysTo <= 3;
                final overdue = !isDone && expired;
                return Card(
                  child: ListTile(
                    leading: IconButton(
                      icon: Icon(isDone ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: isDone ? cs.tertiary : (overdue ? cs.error : (near ? paper.gold : cs.onSurfaceVariant))),
                      onPressed: () async {
                        final repo = await ref.read(planRepositoryAsyncProvider.future);
                        await repo.updateMilestone(m.id!, status: isDone ? 'pending' : 'done');
                        if (!context.mounted) return;
                        ref.invalidate(planDetailProvider(planId));
                      },
                    ),
                    title: Text(
                      '${m.targetDate.month}/${m.targetDate.day} ${m.title}',
                      style: TextStyle(decoration: isDone ? TextDecoration.lineThrough : null, color: isDone ? cs.onSurfaceVariant : null),
                    ),
                    subtitle: Text(m.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    trailing: overdue
                        ? Text('已过期', style: TextStyle(color: cs.error, fontSize: 12))
                        : (near ? Text(daysTo == 0 ? '今天' : '$daysTo天', style: TextStyle(color: paper.gold, fontSize: 12)) : null),
                  ),
                );
              }),
              const SizedBox(height: 16),
              const Text('每日任务', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              DayTaskCalendar(planId: planId),
            ],
          );
        },
      ),
    );
  }

  int? _extractScore(String text) {
    // 仅认「X分」模式；纯数字回退会把日期/年份（如「2026年上岸」的 2026）误判为目标分。
    final m = RegExp(r'(\d+)\s*分').firstMatch(text);
    return m == null ? null : int.tryParse(m.group(1)!);
  }
}
