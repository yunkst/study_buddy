import 'dart:convert';
import '../../models/models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/category_repository.dart';
import '../../repos/mastery_repository.dart';
import '../../repos/plan_day_task_repository.dart';
import '../../repos/plan_repository.dart';
import '../../repos/review_repository.dart';
import '../../repos/topic_edge_repository.dart';
import '../../repos/topic_repository.dart';
import '../../repos/topic_schedule_repository.dart';
import '../agent_scenario.dart';
import '../ask_user_tools.dart';
import '../prompt_resolver.dart';

/// 融合场景：学习伴侣 + 学习计划合一。24 工具（知识点 9 + 计划 14 + ask_user），
/// 一份融合系统提示词，agent 同时具备批改/知识库/计划全部能力。
/// 记忆来自 agent_memory 表（scenario_id='study_plan'，v9 迁移把旧 study/plan 归并）。
///
/// system prompt 通过 [promptResolver] 获取（基线为 Dart 常量模板，
/// App 层可注入 DbPromptResolver 读 `prompt_override` 表做运行时覆盖）。
/// 经验记忆不嵌 system prompt，而是经 [composeApiMessages] 以 `&lt;memory-context&gt;`
/// 块随当前轮用户消息注入（hermes 风格，标注 NOT new user input）。
class StudyPlanScenario implements AgentScenario {
  final CategoryRepository categories;
  final TopicRepository topics;
  final TopicEdgeRepository edges;
  final AgentMemoryRepository memories;
  final MasteryRepository mastery; // 掌握度记录/查询
  final ReviewRepository reviews; // 批改记录
  final TopicScheduleRepository schedules; // FSRS 调度仓储
  final PlanRepository plans; // 学习计划
  final PlanDayTaskRepository dayTasks; // 每日任务
  final PromptResolver promptResolver; // 默认纯 Dart 常量模板（可纯 Dart 测试）

  /// 知识点被接触时的回调（save_topic 新建/命中已存在、update_topic 成功）。
  /// 默认 null = no-op。app 层注入实现以关联到当前专注会话。
  final Future<void> Function(int topicId)? onTopicTouched;

  StudyPlanScenario({
    required this.categories,
    required this.topics,
    required this.edges,
    required this.memories,
    required this.mastery,
    required this.reviews,
    required this.schedules,
    required this.plans,
    required this.dayTasks,
    this.onTopicTouched,
    this.promptResolver = const DefaultPromptResolver(),
  });

  @override String get id => 'study_plan';
  @override String get displayName => '学习伴侣';
  @override List<Map<String, dynamic>> get tools => AskUserTools.combinedTools;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) => promptResolver.resolve(id, ctx);

  @override
  List<ChatMessage> composeApiMessages(
      List<ChatMessage> base, AgentScenarioContext ctx) {
    if (_memCache.isEmpty) return base;
    // 定位「当前轮用户消息」：base 里最后一条 role==user（AgentLoop 入口调用时，
    // 调用方传入的历史以当前用户消息结尾）。历史 user 已在前轮注入过，无需重复。
    final idx = base.lastIndexWhere((m) => m.role == 'user');
    if (idx < 0) return base;
    final msg = base[idx];
    final block = _memoryContextBlock();

    final List<ChatMessage> out;
    final content = msg.content;
    if (content is String) {
      // 纯文本：stamp apiContent = 原文 + \n\n + 记忆块；content 保持干净（存储/UI 用）。
      final stamped = ChatMessage(
        role: msg.role,
        content: content,
        apiContent: '$content\n\n$block',
        toolCalls: msg.toolCalls,
        toolCallId: msg.toolCallId,
      );
      out = [...base];
      out[idx] = stamped;
    } else {
      // 含图（vision parts）：追加一个记忆 TextPart，保留图片——apiContent 是纯文本
      // 会覆盖图片，故走 content 数组追加；该列表只发 LLM，不入库（存储用 App 层干净 state）。
      final parts = [...(content as List<ContentPart>), TextPart(block)];
      final stamped = ChatMessage(
        role: msg.role,
        content: parts,
        toolCalls: msg.toolCalls,
        toolCallId: msg.toolCallId,
      );
      out = [...base];
      out[idx] = stamped;
    }
    return out;
  }

  /// 经验记忆 → `&lt;memory-context&gt;` 包裹块（hermes 风格，明确标注 NOT new user input）。
  String _memoryContextBlock() {
    final mem = _memCache;
    final body = mem.isEmpty
        ? '（暂无经验记忆）'
        : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    return '<memory-context>\n'
        '[System note: The following is recalled memory context, NOT new user input. '
        'This is the agent\'s persistent memory and should inform all responses.]\n\n'
        '$body\n'
        '</memory-context>';
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId, AgentScenarioContext? context}) async {
    switch (name) {
      // —— 知识点 / 批改 ——
      case 'list_topics':
        return _listTopics(args['path'] as String?);
      case 'search_topics':
        return _searchTopics(args['keyword'] as String, args['offset'] as int?);
      case 'get_topic':
        return _getTopic(args['id'] as int);
      case 'save_topic':
        return _saveTopic(
          args['path'] as String,
          args['title'] as String,
          args['question'] as String,
          args['summary'] as String,
        );
      case 'update_topic':
        return _updateTopic(args['id'] as int, args['summary'] as String);
      case 'link_topics':
        return _linkTopics(args['from'] as int, args['to'] as int, args['type'] as String);
      case 'set_mastery':
        return _setMastery(
          args['topic_id'] as int,
          args['status'] as String,
          args['reason'] as String,
        );
      case 'get_mastery':
        return _getMastery(args['topic_id'] as int);
      case 'save_review':
        return _saveReview(args, context);
      // —— 学习计划 ——
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
      case 'delete_plan':
        return _deletePlan(args['plan_id'] as int);
      case 'delete_assessment':
        return _deleteAssessment(args['assessment_id'] as int);
      case 'create_day_task':
        return _createDayTask(args);
      case 'list_day_tasks':
        return _listDayTasks(args);
      case 'checkin_day_task':
        return _checkinDayTask(args);
      case 'update_day_task':
        return _updateDayTask(args);
      case 'delete_day_task':
        return _deleteDayTask(args['task_id'] as int);
      default:
        return '未知工具: $name';
    }
  }

  // ===================== 知识点 / 批改 =====================

  Future<String> _listTopics(String? path) async {
    int? parentId;
    if (path != null && path.isNotEmpty) {
      final segments = path.split('/').where((s) => s.trim().isNotEmpty).toList();
      final cat = await categories.findByPath(segments);
      if (cat == null) return '路径不存在: $path';
      parentId = cat.id;
    }
    final children = await categories.findChildren(parentId);
    final childList = <Map<String, Object?>>[];
    for (final c in children) {
      final grandChildren = await categories.findChildren(c.id!);
      childList.add({'name': c.name, 'has_children': grandChildren.isNotEmpty});
    }
    final topicList = parentId == null
        ? <Map<String, Object?>>[]
        : (await topics.findByCategory(parentId)).map((t) => {'id': t.id, 'title': t.title}).toList();
    return jsonEncode({'children': childList, 'topics': topicList});
  }

  Future<String> _searchTopics(String keyword, int? offset) async {
    const limit = 30;
    final result = await topics.search(keyword, limit: limit, offset: offset ?? 0);
    final items = <Map<String, Object?>>[];
    for (final it in result.items) {
      final path = await categories.pathOf(it.categoryId);
      items.add({'id': it.id, 'title': it.title, 'path': path.join('/')});
    }
    return jsonEncode({
      'items': items,
      'total': result.total,
      'returned': items.length,
      'has_more': result.total > (offset ?? 0) + limit,
    });
  }

  Future<String> _getTopic(int id) async {
    final t = await topics.findById(id);
    if (t == null) return '知识点 id=$id 不存在';
    final path = await categories.pathOf(t.categoryId);
    final edgeList = (await edges.findByTopic(id))
        .map((e) => {'type': e.type, 'other_id': e.otherId, 'other_title': e.otherTitle})
        .toList();
    return jsonEncode({
      'id': t.id,
      'title': t.title,
      'path': path.join('/'),
      'question': t.question,
      'summary': t.summary,
      'edges': edgeList,
    });
  }

  Future<String> _saveTopic(String path, String title, String question, String summary) async {
    final existing = await topics.findByTitle(title);
    if (existing != null) {
      await onTopicTouched?.call(existing.id!);
      return jsonEncode(SaveTopicResult(
        id: existing.id!,
        isNew: false,
        message: '知识点「$title」已存在。如需补充答案请用 update_topic。',
      ).toJson());
    }
    final segments = path.split('/').where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return jsonEncode({'id': null, 'is_new': null, 'msg': 'path 不能为空'});
    final catId = await categories.ensurePath(segments);
    final now = DateTime.now();
    int id;
    try {
      id = await topics.insert(Topic(
        categoryId: catId,
        question: question,
        title: title,
        summary: summary,
        createdAt: now,
        updatedAt: now,
      ));
    } catch (e) {
      // 并发兜底：findByTitle 与 insert 非原子，并发下另一会话可能已插入同 title，
      // 触发 UNIQUE 冲突。捕获后转「已存在」引导（与上面 findByTitle 命中一致），
      // 非 UNIQUE 异常继续抛出。
      if (e.toString().contains('UNIQUE constraint failed')) {
        final existing = await topics.findByTitle(title);
        await onTopicTouched?.call(existing!.id!);
        return jsonEncode(SaveTopicResult(
          id: existing!.id!,
          isNew: false,
          message: '知识点「$title」已存在。如需补充答案请用 update_topic。',
        ).toJson());
      }
      rethrow;
    }
    await onTopicTouched?.call(id);
    return jsonEncode(SaveTopicResult(
      id: id,
      isNew: true,
      message: '已保存知识点「$title」(id=$id)，路径 $path',
    ).toJson());
  }

  Future<String> _updateTopic(int id, String summary) async {
    final existing = await topics.findById(id);
    if (existing == null) return '知识点 id=$id 不存在';
    await topics.updateSummary(id, summary);
    await onTopicTouched?.call(id);
    return '已更新知识点「${existing.title}」的答案';
  }

  Future<String> _linkTopics(int from, int to, String type) async {
    if (type != 'prerequisite' && type != 'related') return 'type 必须是 prerequisite 或 related';
    final fromTopic = await topics.findById(from);
    final toTopic = await topics.findById(to);
    if (fromTopic == null) return '知识点 id=$from 不存在';
    if (toTopic == null) return '知识点 id=$to 不存在';
    final before = (await edges.findByTopic(from)).where((e) => e.otherId == to).length;
    await edges.insert(from, to, type);
    final after = (await edges.findByTopic(from)).where((e) => e.otherId == to).length;
    if (after == before) return '关联已存在: ${fromTopic.title} → ${toTopic.title} ($type)';
    return '已建立 $type 关联: ${fromTopic.title} → ${toTopic.title}';
  }

  Future<String> _setMastery(int topicId, String status, String reason) async {
    final parsed = MasteryStatusX.fromWire(status);
    if (parsed == MasteryStatus.unknown) {
      return 'status 不合法(允许 learning/mastered/weak,禁止 unknown)';
    }
    await mastery.log(topicId, parsed, reason: reason);
    final corrected = await schedules.applyMasteryOverride(topicId: topicId, status: parsed);
    return '已记录掌握度: $status, 已同步 schedule (S=${corrected.stability.toStringAsFixed(2)}, D=${corrected.difficulty.toStringAsFixed(2)}) (reason: $reason)';
  }

  Future<String> _getMastery(int topicId) async {
    final current = await mastery.currentStatus(topicId);
    final timeline = await mastery.timeline(topicId);
    final recent = timeline.reversed.take(5).toList().reversed.map((m) => {
          'status': m.status.wire,
          'reason': m.reason,
          'changed_at': m.changedAt.toIso8601String(),
        }).toList();
    return jsonEncode({
      'topic_id': topicId,
      'current_status': current.wire,
      'log_count': timeline.length,
      'recent': recent,
    });
  }

  Future<String> _saveReview(Map<String, dynamic> args, AgentScenarioContext? ctx) async {
    final summary = args['summary'] as String;
    final itemsRaw = args['items'] as List;
    final items = itemsRaw.map((raw) {
      final m = raw as Map<String, dynamic>;
      final tids = m['topic_ids'];
      return ReviewItem(
        seq: _asInt(m['seq']) ?? 0,
        question: m['question'] as String,
        userAnswer: m['user_answer'] as String?,
        verdict: m['verdict'] as String,
        analysis: m['analysis'] as String,
        topicIds: tids == null
            ? const []
            : (tids as List).map((e) => _asInt(e)!).whereType<int>().toList(),
      );
    }).toList();
    final sessionId = ctx?.extra['chat_session_id'] as int?;
    final id = await reviews.save(chatSessionId: sessionId, summary: summary, items: items);
    return '已保存批改(共 ${items.length} 题,review_id=$id)';
  }

  /// 宽松 int 解析：容忍 LLM 把数字序列化成字符串或 num（国产 OpenAI 兼容端点常见）。
  /// 解析失败返回 null，由调用方兜底。
  int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  // ===================== 学习计划 =====================

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

  Future<String> _deletePlan(int planId) async {
    // 删前取一次详情用于反馈计数
    final detail = await plans.getPlanDetail(planId);
    final name = detail.plan.name;
    final msCount = detail.milestones.length;
    final aCount = detail.assessments.length;
    final tCount = (await dayTasks.findByPlan(planId)).length;
    await plans.deletePlan(planId); // CASCADE 自动清 milestone / assessment / plan_day_task
    return jsonEncode({
      'ok': true,
      'plan_id': planId,
      'message': '已删除计划「$name」(id=$planId，连带 $msCount 节点、$aCount 测评、$tCount 每日任务)',
    });
  }

  Future<String> _deleteAssessment(int assessmentId) async {
    await plans.deleteAssessment(assessmentId);
    return '已删除测评 id=$assessmentId';
  }

  Future<String> _createDayTask(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final now = DateTime.now();
    final id = await dayTasks.addTask(PlanDayTask(
      planId: pid,
      taskDate: _parseDate(args['task_date'] as String),
      title: args['title'] as String,
      sortOrder: (args['sort_order'] as int?) ?? 0,
      createdAt: now,
      updatedAt: now,
    ));
    return '已添加每日任务「${args['title']}」(id=$id)';
  }

  Future<String> _listDayTasks(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final date = args['task_date'] as String?;
    final list = date != null
        ? await dayTasks.findByPlanAndDate(pid, _parseDate(date))
        : await dayTasks.findByPlan(pid);
    String fmtDate(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    String fmtDateTime(DateTime d) =>
        '${fmtDate(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return jsonEncode({
      'plan_id': pid,
      'count': list.length,
      'tasks': list
          .map((t) => {
                'id': t.id,
                'task_date': fmtDate(t.taskDate),
                'title': t.title,
                'status': t.status,
                'sort_order': t.sortOrder,
                'done_at': t.doneAt == null ? null : fmtDateTime(t.doneAt!),
              })
          .toList(),
    });
  }

  Future<String> _checkinDayTask(Map<String, dynamic> args) async {
    final tid = args['task_id'] as int;
    final status = args['status'] as String;
    if (status != 'pending' && status != 'done') {
      return 'status 必须是 pending 或 done，收到: $status';
    }
    await dayTasks.updateTask(tid, status: status);
    return '已把任务 $tid 标记为 $status';
  }

  Future<String> _updateDayTask(Map<String, dynamic> args) async {
    final tid = args['task_id'] as int;
    await dayTasks.updateTask(
      tid,
      title: args['title'] as String?,
      taskDate: args['task_date'] != null ? _parseDate(args['task_date'] as String) : null,
      sortOrder: args['sort_order'] as int?,
    );
    return '已更新每日任务 id=$tid';
  }

  Future<String> _deleteDayTask(int taskId) async {
    await dayTasks.deleteTask(taskId);
    return '已删除每日任务 id=$taskId';
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
