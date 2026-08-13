import 'dart:convert';
import '../../models/models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/plan_repository.dart';
import '../agent_scenario.dart';
import '../ask_user_tools.dart';

/// 学习计划场景：7 工具管理计划全生命周期，记忆来自 agent_memory 表（scenario_id='plan'）。
class PlanScenario implements AgentScenario {
  final PlanRepository plans;
  final AgentMemoryRepository memories;

  PlanScenario({required this.plans, required this.memories});

  @override String get id => 'plan';
  @override String get displayName => '学习计划';
  @override List<Map<String, dynamic>> get tools => AskUserTools.planToolsWithAsk;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final today = ctx.extra['today'] as DateTime?;
    final todayStr = today != null
        ? '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}'
        : '（未知）';
    final planSummary = ctx.extra['plan_summary'] as String? ?? '（无当前计划，用户可能要新建）';
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    return '''你是学习计划助手 AI。职责：帮用户把考试目标拆成可执行的里程碑节点，跟踪周期测评，画进步曲线，并根据进度随时调整计划。

## 当前时间
今天是 $todayStr。

## 创建计划（create_plan）必须收齐
- name：计划名
- exam_date：考试日期（YYYY-MM-DD）
- exam_content：考试内容/范围
- target：目标（分数/院校/通过等）
- daily_minutes：每日可学习时长（分钟）
- current_level：当前自评水平（最近做真题能考多少分，哪块弱）
缺任何一项都要先追问用户补齐，不要瞎猜。收齐后再 create_plan。

## 用 ask_user 追问
- 收齐字段时，优先用 ask_user 一个一个结构化地问，能给出候选值的尽量给 options（如 daily_minutes 给常见时长、exam_content 给常见科目组合），拿不准的用自由输入。
- 一次只问一件事；连续提问建议最多 3 轮，其余字段基于已有信息合理推断并在提问里说明。
- 收到 ask_user 的 result 后直接使用，不要重复问已确认的字段。

## 拆节点原则
- 按考试日期倒推，结合每日时长和当前差距排期。
- 薄弱项节点排前。
- 每个节点要有明确的"完成标志"（description 写清达到什么程度算过）。
- 节点数 4-8 个为宜，太细碎用户跟不上，太粗等于没拆。

## 调整原则
- 用户报进度落后/超前时，对照 get_plan 的节点和测评重排后续节点。
- 改目标时联动调整节点的分数预期。
- 高危操作（删节点）执行前向用户确认一句。

## 测评
- 用户提到做了真题/模考并报分时，用 add_assessment 录入。
- 鼓励用户定期测评，对照曲线看趋势。

## 当前计划上下文
$planSummary

## 经验记忆
$memBlock''';
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId, AgentScenarioContext? context}) async {
    switch (name) {
      case 'create_plan':
        return _createPlan(args);
      case 'get_plan':
        return _getPlan(args['plan_id'] as int);
      case 'update_plan':
        return _updatePlan(args);
      case 'add_milestone':
        return _addMilestone(args);
      case 'update_milestone':
        return _updateMilestone(args);
      case 'delete_milestone':
        return _deleteMilestone(args['milestone_id'] as int);
      case 'add_assessment':
        return _addAssessment(args);
      default:
        return '未知工具: $name';
    }
  }

  DateTime _parseDate(String s) => DateTime.parse(s);

  Future<String> _createPlan(Map<String, dynamic> args) async {
    final name = args['name'] as String?;
    final examDate = args['exam_date'] as String?;
    final examContent = args['exam_content'] as String?;
    final target = args['target'] as String?;
    final dailyMinutes = args['daily_minutes'] as int?;
    final currentLevel = args['current_level'] as String?;
    final missing = <String>[];
    if (name == null) missing.add('name');
    if (examDate == null) missing.add('exam_date');
    if (examContent == null) missing.add('exam_content');
    if (target == null) missing.add('target');
    if (dailyMinutes == null) missing.add('daily_minutes');
    if (currentLevel == null) missing.add('current_level');
    if (missing.isNotEmpty) {
      return '缺少必填字段: ${missing.join(', ')}。请向用户追问补齐后再创建。';
    }
    final now = DateTime.now();
    final planId = await plans.insertPlan(Plan(
      name: name!,
      examDate: _parseDate(examDate!),
      examContent: examContent!,
      target: target!,
      dailyMinutes: dailyMinutes!,
      currentLevel: currentLevel,
      createdAt: now,
      updatedAt: now,
    ));
    // 从 current_level 抽分数作为起点测评
    final score = _extractScore(currentLevel!);
    await plans.addAssessment(Assessment(
      planId: planId,
      score: score,
      note: score == null ? currentLevel : null,
      assessedAt: now,
      createdAt: now,
    ));
    return jsonEncode({'ok': true, 'plan_id': planId, 'message': '已创建计划「$name」(id=$planId)，起点测评 $score 分'});
  }

  /// 从文本抽取分数。仅匹配"数字+分"模式（如"能考90分"）。
  /// 不做纯数字回退——避免把日期("2024年真题"→2024)、时长("3小时"→3)、
  /// 年级等误判为起点分数，导致进步曲线基线错乱。抽不到返回 null。
  int? _extractScore(String text) {
    final m = RegExp(r'(\d+)\s*分').firstMatch(text);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  Future<String> _getPlan(int planId) async {
    final detail = await plans.getPlanDetail(planId);
    final msList = detail.milestones.map((m) => {
          'id': m.id, 'title': m.title, 'description': m.description,
          'target_date': '${m.targetDate.year}-${m.targetDate.month.toString().padLeft(2, '0')}-${m.targetDate.day.toString().padLeft(2, '0')}',
          'status': m.status, 'sort_order': m.sortOrder,
        }).toList();
    final aList = detail.assessments.map((a) => {
          'id': a.id, 'score': a.score, 'note': a.note,
          'assessed_at': '${a.assessedAt.year}-${a.assessedAt.month.toString().padLeft(2, '0')}-${a.assessedAt.day.toString().padLeft(2, '0')}',
        }).toList();
    return jsonEncode({
      'plan': {
        'id': detail.plan.id, 'name': detail.plan.name,
        'exam_date': '${detail.plan.examDate.year}-${detail.plan.examDate.month.toString().padLeft(2, '0')}-${detail.plan.examDate.day.toString().padLeft(2, '0')}',
        'exam_content': detail.plan.examContent, 'target': detail.plan.target,
        'daily_minutes': detail.plan.dailyMinutes, 'current_level': detail.plan.currentLevel,
      },
      'milestones': msList,
      'assessments': aList,
    });
  }

  Future<String> _updatePlan(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    await plans.updatePlan(Plan(
      id: pid,
      name: args['name'] as String? ?? existing.name,
      examDate: args['exam_date'] != null ? _parseDate(args['exam_date'] as String) : existing.examDate,
      examContent: args['exam_content'] as String? ?? existing.examContent,
      target: args['target'] as String? ?? existing.target,
      dailyMinutes: args['daily_minutes'] as int? ?? existing.dailyMinutes,
      currentLevel: existing.currentLevel,
      createdAt: existing.createdAt,
      updatedAt: existing.createdAt,
    ));
    return '已更新计划「${existing.name}」';
  }

  Future<String> _addMilestone(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final now = DateTime.now();
    final id = await plans.addMilestone(Milestone(
      planId: pid,
      title: args['title'] as String,
      description: args['description'] as String,
      targetDate: _parseDate(args['target_date'] as String),
      sortOrder: (args['sort_order'] as int?) ?? 0,
      createdAt: now,
      updatedAt: now,
    ));
    return '已添加节点「${args['title']}」(id=$id)';
  }

  Future<String> _updateMilestone(Map<String, dynamic> args) async {
    final mid = args['milestone_id'] as int;
    final status = args['status'] as String?;
    if (status != null && status != 'pending' && status != 'done') {
      return 'status 必须是 pending 或 done，收到: $status';
    }
    await plans.updateMilestone(
      mid,
      title: args['title'] as String?,
      description: args['description'] as String?,
      targetDate: args['target_date'] != null ? _parseDate(args['target_date'] as String) : null,
      sortOrder: args['sort_order'] as int?,
      status: status,
    );
    return '已更新节点 id=$mid';
  }

  Future<String> _deleteMilestone(int milestoneId) async {
    await plans.deleteMilestone(milestoneId);
    return '已删除节点 id=$milestoneId';
  }

  Future<String> _addAssessment(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final now = DateTime.now();
    final assessedAt = args['assessed_at'] != null ? _parseDate(args['assessed_at'] as String) : now;
    final score = args['score'] as int?;
    final id = await plans.addAssessment(Assessment(
      planId: pid,
      score: score,
      note: args['note'] as String?,
      assessedAt: assessedAt,
      createdAt: now,
    ));
    return jsonEncode({'ok': true, 'assessment_id': id, 'score': score});
  }

  @override
  Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;

  @override
  Future<List<String>> getMemories() async {
    _memCache = (await memories.queryByScenario(id)).map((m) => m.content).toList();
    return _memCache;
  }

  @override
  Future<MemoryPatchResult> patchMemory(int? index, String newText) async {
    final all = await memories.queryByScenario(id);
    if (index == null) {
      await memories.add(id, newText);
      return MemoryPatchResult(true, '已新增记忆');
    }
    final i = index - 1;
    if (i < 0 || i >= all.length) {
      return MemoryPatchResult(false, '编号越界，可用范围 1..${all.length}');
    }
    await memories.update(all[i].id!, newText);
    return MemoryPatchResult(true, '已更新记忆 $index');
  }

  @override
  Future<void> cleanup() async {}
}
