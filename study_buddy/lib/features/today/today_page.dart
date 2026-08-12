// 今日 Tab：Ask-AI 三入口 + 今日计划摘要 + 今日专注 + 今日复习。
//
// 取代原 home_page 成为 App 首屏（3 Tab 壳的第一个 branch）。继承 home_page
// 的两个关键行为：冷启动待处理截图消费（PendingScreenshotStore）与拍题时
// suppressOverlayOnPause 抑制（避免相机 Activity 期间悬浮球闪现）。悬浮窗权限
// 与 overlay 暖机逻辑已迁移到 Settings（Task 8.2）/ app.dart，此处仅保留截图消费。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/image_pick_provider.dart';
import '../../core/providers/plan_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../core/providers/topic_schedule_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../../features/plan/plan_chat_sheet.dart';
import '../../main.dart' show PendingScreenshotStore;

/// 今日 Tab 根页：学习闭环（问 · 计划 · 专注 · 复习）入口。
///
/// 冷启动时若原生持有待处理截图（悬浮球截完图 App 被杀），在 [initState]
/// 消费并弹出 AI 面板——这是 [PendingScreenshotStore.pending] 的唯一消费者，
/// 让热路径（悬浮球回前台）与冷路径（被杀后重开）回流一致。
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

  /// 冷启动降级：弹出待处理截图的 AI 面板。
  Future<void> _consumePendingScreenshot() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null) {
        PendingScreenshotStore.pending = null;
        if (mounted) await showAiPanel(context, screenshot: pending);
      }
    });
  }

  /// 拍照/相册 → pickImageForAi → showAiPanel。
  ///
  /// 相机/相册 Activity 让 App 进 paused：通过 suppressOverlayOnPauseProvider
  /// set(true) 抑制 lifecycle 的 showOverlay，避免悬浮球在系统界面闪现。
  /// finally 中复位（即使取消/失败），避免泄漏导致后续进后台不显示悬浮球（I-1）。
  Future<void> _pickImageAndAskAi(BuildContext context, {required bool fromCamera}) async {
    ref.read(suppressOverlayOnPauseProvider.notifier).set(true);
    CapturedScreenshot? screenshot;
    try {
      screenshot = await pickImageForAi(fromCamera: fromCamera);
      if (screenshot == null) return;
    } finally {
      ref.read(suppressOverlayOnPauseProvider.notifier).set(false);
    }
    if (!context.mounted) return;
    await showAiPanel(context, screenshot: screenshot);
  }

  /// 直接聊：无截图，纯文字多轮对话。
  void _directChat() => showAiPanel(context);

  @override
  Widget build(BuildContext context) {
    final plansAsync = ref.watch(planListProvider);
    final dueAsync = ref.watch(dueNowCountProvider);
    return PaperScaffold(
      appBar: AppBar(title: const Text('今日')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          children: [
            _AskAiSection(
              onCamera: () => _pickImageAndAskAi(context, fromCamera: true),
              onGallery: () => _pickImageAndAskAi(context, fromCamera: false),
              onChat: _directChat,
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
          bottom: BorderSide(color: rule ?? theme.colorScheme.outlineVariant, width: 2),
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

/// Ask-AI 三入口：拍照 / 从相册选择 / 直接聊。
class _AskAiSection extends StatelessWidget {
  const _AskAiSection({
    required this.onCamera,
    required this.onGallery,
    required this.onChat,
  });

  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _AskBtn(
          icon: Icons.photo_camera_outlined,
          label: '拍照',
          onTap: onCamera,
        ),
        const SizedBox(height: 8),
        _AskBtn(
          icon: Icons.photo_library_outlined,
          label: '从相册选择',
          onTap: onGallery,
        ),
        const SizedBox(height: 8),
        _AskBtn(
          icon: Icons.chat_bubble_outline,
          label: '直接聊',
          onTap: onChat,
        ),
      ],
    );
  }
}

/// Ask-AI 主按钮：纸感 FilledButton.tonal，下沿细分隔线。
class _AskBtn extends StatelessWidget {
  const _AskBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton.tonalIcon(
        icon: Icon(icon),
        label: Text(
          label,
          style: const TextStyle(fontFamily: 'NotoSerifSC', fontSize: 15),
        ),
        onPressed: onTap,
      ),
    );
  }
}

/// 今日计划摘要行：取第一个计划的名称 + 考试日期，点按进详情；空态引导去创建。
class _PlanSummaryRow extends StatelessWidget {
  const _PlanSummaryRow({required this.plansAsync, required this.onEmptyCreate});

  final AsyncValue<List<Plan>> plansAsync;
  final Future<void> Function() onEmptyCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return plansAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
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
            title: '还没有计划，去创建',
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
      loading: () => const _NavRow(
        icon: Icons.hourglass_empty,
        title: '今日待复习 …',
      ),
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
            bottom: BorderSide(color: rule ?? theme.colorScheme.outlineVariant, width: 0.6),
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
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }
}