import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';
import '../../core/theme/paper_extension.dart';

/// 每日打卡月历视图。挂在计划详情页「每日任务」区块。
///
/// 自撸月历（不引入 table_calendar 依赖）：顶部翻月，7×6 网格显示日号与
/// 完成状态点，点击某天在下方展示当天任务列表，可勾选完成/重置/删除。
class DayTaskCalendar extends ConsumerStatefulWidget {
  const DayTaskCalendar({super.key, required this.planId});
  final int planId;

  @override
  ConsumerState<DayTaskCalendar> createState() => _DayTaskCalendarState();
}

class _DayTaskCalendarState extends ConsumerState<DayTaskCalendar> {
  late DateTime _focusedMonth;
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month);
    _selectedDay = DateTime(now.year, now.month, now.day);
  }

  static String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// 按本地零点聚合：Map[日期key, List[PlanDayTask]]
  Map<String, List<PlanDayTask>> _groupByDay(List<PlanDayTask> tasks) {
    final map = <String, List<PlanDayTask>>{};
    for (final t in tasks) {
      final key = _dateKey(t.taskDate);
      map.putIfAbsent(key, () => []).add(t);
    }
    return map;
  }

  void _prevMonth() => setState(() {
        _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
      });

  void _nextMonth() => setState(() {
        _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
      });

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(planDayTasksProvider(widget.planId));
    return tasksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('加载任务失败: $e'),
      data: (tasks) {
        final byDay = _groupByDay(tasks);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildMonthHeader(),
            const SizedBox(height: 8),
            _buildWeekRowHeader(),
            const SizedBox(height: 4),
            _buildGrid(byDay),
            const SizedBox(height: 12),
            _buildSelectedDayPanel(byDay),
          ],
        );
      },
    );
  }

  Widget _buildMonthHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: _prevMonth,
          tooltip: '上一月',
        ),
        Text(
          '${_focusedMonth.year} 年 ${_focusedMonth.month} 月',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: _nextMonth,
          tooltip: '下一月',
        ),
      ],
    );
  }

  Widget _buildWeekRowHeader() {
    final cs = Theme.of(context).colorScheme;
    const weeks = ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: weeks
          .map((w) => Expanded(
                child: Text(w, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ))
          .toList(),
    );
  }

  /// 当月第一天是周几（周一=0），用于计算 6×7 网格首行空白偏移。
  int get _firstWeekdayOffset {
    // DateTime.weekday: 周一=1..周日=7；转成 周一=0..周日=6
    return DateTime(_focusedMonth.year, _focusedMonth.month, 1).weekday - 1;
  }

  int get _daysInMonth {
    return DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0).day;
  }

  Widget _buildGrid(Map<String, List<PlanDayTask>> byDay) {
    final cs = Theme.of(context).colorScheme;
    final paper = Theme.of(context).extension<PaperColors>()!;
    final offset = _firstWeekdayOffset;
    final daysInMonth = _daysInMonth;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 1,
      ),
      itemCount: 6 * 7, // 固定 6 行，保证月历稳定
      itemBuilder: (context, index) {
        final dayNum = index - offset + 1;
        if (dayNum < 1 || dayNum > daysInMonth) {
          return const SizedBox.shrink();
        }
        final date = DateTime(_focusedMonth.year, _focusedMonth.month, dayNum);
        final key = _dateKey(date);
        final dayTasks = byDay[key] ?? const <PlanDayTask>[];
        final done = dayTasks.where((t) => t.status == 'done').length;
        final pending = dayTasks.length - done;
        final isSelected = _selectedDay != null &&
            _dateKey(_selectedDay!) == key;
        final isToday = _dateKey(date) == _dateKey(DateTime.now());

        return InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => setState(() => _selectedDay = date),
          child: Container(
            decoration: isSelected
                ? BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$dayNum',
                  style: TextStyle(
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    color: isToday ? Theme.of(context).colorScheme.primary : null,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (done > 0) _dot(cs.tertiary, done),
                    if (pending > 0) ...[
                      const SizedBox(width: 2),
                      _dot(paper.gold, pending),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dot(Color color, [int? count]) {
    return Tooltip(
      message: count != null ? '$count 项' : '',
      child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    );
  }

  Widget _buildSelectedDayPanel(Map<String, List<PlanDayTask>> byDay) {
    final cs = Theme.of(context).colorScheme;
    final selected = _selectedDay;
    if (selected == null) return const SizedBox.shrink();
    final key = _dateKey(selected);
    final dayTasks = byDay[key] ?? const <PlanDayTask>[];
    final done = dayTasks.where((t) => t.status == 'done').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${selected.month}月${selected.day}日 任务（$done/${dayTasks.length}）',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加'),
              onPressed: () => _addTask(selected),
            ),
          ],
        ),
        if (dayTasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('当天没有任务', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          )
        else
          ...dayTasks.map((t) {
            final isDone = t.status == 'done';
            return Row(
              children: [
                Checkbox(
                  value: isDone,
                  onChanged: (v) => _toggleTask(t, v ?? false),
                ),
                Expanded(
                  child: Text(
                    t.title,
                    style: TextStyle(
                      decoration: isDone ? TextDecoration.lineThrough : null,
                      color: isDone ? cs.onSurfaceVariant : null,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '删除任务',
                  onPressed: () => _deleteTask(t),
                ),
              ],
            );
          }),
      ],
    );
  }

  Future<void> _toggleTask(PlanDayTask t, bool done) async {
    final repo = await ref.read(planDayTaskRepositoryAsyncProvider.future);
    await repo.updateTask(t.id!, status: done ? 'done' : 'pending');
    if (!mounted) return;
    ref.invalidate(planDayTasksProvider(widget.planId));
  }

  Future<void> _deleteTask(PlanDayTask t) async {
    final repo = await ref.read(planDayTaskRepositoryAsyncProvider.future);
    await repo.deleteTask(t.id!);
    if (!mounted) return;
    ref.invalidate(planDayTasksProvider(widget.planId));
  }

  void _addTask(DateTime day) {
    // 进入计划 AI 对话，由 agent 创建当日任务。taskDate 通过 extra 注入。
    // 注：showPlanChat 目前在 plan_chat_sheet.dart 实现，此处保持简单——
    // 直接用底部弹窗或跳转到计划对话入口。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('请在计划 AI 对话里说「${day.month}月${day.day}日我想…」来添加当天任务')),
    );
  }
}