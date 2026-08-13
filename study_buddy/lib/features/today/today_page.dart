// 今日 Tab：学习闭环（问 AI · 计划 · 专注 · 复习）入口。
//
// 取代原 home_page 成为 App 首屏（3 Tab 壳的第一个 branch）。继承 home_page
// 的关键行为：冷启动分享图片消费（PendingScreenshotStore）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';
import '../../core/providers/topic_schedule_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../../features/plan/plan_chat_sheet.dart';
import '../../features/share/share_flow.dart';
import '../../main.dart' show PendingScreenshotStore;

/// 今日 Tab 根页：学习闭环（问 AI · 计划 · 专注 · 复习）入口。
///
/// 冷启动时若 [PendingScreenshotStore.pending] 有分享冷启动降级写入的图片，
/// 在 [initState] 消费并跳转到 AI 对话页（`/ai`）——这是该 holder 的唯一消费者。
class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key});

  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage> {
  @override
  void initState() {
    super.initState();
    _consumePendingScreenshot();
  }

  /// 分享冷启动降级：从相册/浏览器分享图片唤起 App → 跳 AI 对话页并预填截图。
  ///
  /// 调用 showAiPanel（签名保持，等价于 context.push('/ai', extra: ...)）。
  Future<void> _consumePendingScreenshot() async {
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
    final plansAsync = ref.watch(planListProvider);
    final dueAsync = ref.watch(dueNowCountProvider);
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('今日'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '分享今日学习到小红书',
            onPressed: () => showShareSheet(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          children: [
            _NavRow(
              icon: Icons.smart_toy_outlined,
              title: '问 AI',
              subtitle: '拍照 · 相册 · 直接聊',
              onTap: () => context.push('/ai'),
            ),
            const _SectionLabel('今日计划'),
            _PlanSummaryRow(
              plansAsync: plansAsync,
              onEmptyCreate: () async {
                await showPlanChat(context);
                if (context.mounted) ref.invalidate(planListProvider);
              },
            ),
            const _SectionLabel('今日专注'),
            _NavRow(
              icon: Icons.timer_outlined,
              title: '开始专注',
              onTap: () => context.push('/focus'),
            ),
            _NavRow(
              icon: Icons.assignment_outlined,
              title: '学习日报',
              onTap: () => context.push('/daily-report'),
            ),
            const _SectionLabel('今日复习'),
            _DueReviewRow(dueAsync: dueAsync),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// 纸感小节标签：NotoSerifSC 字重加粗 + 下沿双线分隔。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: rule ?? theme.colorScheme.outlineVariant,
            width: 2,
          ),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.titleMedium?.copyWith(
          fontFamily: 'NotoSerifSC',
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

// 注：旧的 _AskAiSection / _AskBtn / _pickImageAndAskAi / _directChat 已删除。
// 入口合并为单个 _NavRow「问 AI」→ context.push('/ai')，进入全屏对话页后
// 由 _EmptyState 提供拍照/相册/直接输入三个入口。

/// 今日计划摘要行：取第一个计划的名称 + 考试日期，点按进详情；空态引导去创建。
class _PlanSummaryRow extends StatelessWidget {
  const _PlanSummaryRow({
    required this.plansAsync,
    required this.onEmptyCreate,
  });

  final AsyncValue<List<Plan>> plansAsync;
  final Future<void> Function() onEmptyCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return plansAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '加载计划失败: $e',
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12.5),
        ),
      ),
      data: (plans) {
        if (plans.isEmpty) {
          return _NavRow(
            icon: Icons.add_circle_outline,
            title: '还没有学习计划，去创建',
            onTap: () => onEmptyCreate(),
          );
        }
        final p = plans.first;
        final d = p.examDate;
        final dateStr = '${d.year}/${d.month}/${d.day}';
        return _NavRow(
          icon: Icons.event_outlined,
          title: p.name,
          subtitle: '考试 $dateStr · 目标 ${p.target}',
          onTap: () => context.push('/plan/${p.id}'),
        );
      },
    );
  }
}

/// 今日复习：待复习张数（FSRS due now）。
class _DueReviewRow extends StatelessWidget {
  const _DueReviewRow({required this.dueAsync});

  final AsyncValue<int> dueAsync;

  @override
  Widget build(BuildContext context) {
    return dueAsync.when(
      loading: () =>
          const _NavRow(icon: Icons.hourglass_empty, title: '今日待复习 …'),
      error: (e, _) => _NavRow(
        icon: Icons.error_outline,
        title: '待复习数量读取失败',
        subtitle: '$e',
      ),
      data: (count) {
        final done = count == 0;
        return _NavRow(
          icon: done ? Icons.check_circle_outline : Icons.style_outlined,
          title: done ? '今日待复习 0 张' : '今日待复习 $count 张',
          subtitle: done ? null : '点按开始复习',
          onTap: done ? null : () => context.push('/review'),
        );
      },
    );
  }
}

/// 通用纸感导航行：Icon + 主标题(+副标题) + chevron，下沿细分隔线。
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = theme.extension<PaperColors>()?.ruleSoft;
    final chevron = onTap != null;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: rule ?? theme.colorScheme.outlineVariant,
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFamily: 'NotoSerifSC',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (chevron)
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
