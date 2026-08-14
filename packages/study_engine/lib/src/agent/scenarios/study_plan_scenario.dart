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
import '../agent_tools.dart';
import '../ask_user_tools.dart';
import '../memory_policy.dart';
import '../plan_tools.dart';
import '../prompt_resolver.dart';
import '../tool_definition.dart';

/// 工具参数缺失/类型错误异常：由各工具 handler 的必填参数 helper
/// （[_reqStr]/[_reqInt]/[_reqEnum]）抛出，[StudyPlanScenario.executeTool]
/// 入口统一 catch 转成「参数 xxx 缺失…」友好报错，避免污染下一轮 LLM 调用。
class ToolArgsException implements Exception {
  ToolArgsException(this.message);
  final String message;
  @override
  String toString() => 'ToolArgsException: $message';
}

/// 融合场景：学习伴侣 + 学习计划合一。28 工具（知识点 12 + 计划 14 + ask_user +
/// patch_memory），一份融合系统提示词，agent 同时具备批改/知识库/计划全部能力。
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

  /// 工具定义表（28 个：知识点 12 + 计划 14 + ask_user + patch_memory）。
  /// schema 复用现有 const Map（AskUserTools.combinedTools 同源），execute 复用
  /// 下方私有实现方法；[executeTool] 按 id 查表分发。
  late final List<ToolDefinition> _defs = [
    // —— 知识点 / 批改 ——
    _tool(AgentTools.studyTools[0], (a, _) => _listTopics(a)),
    _tool(AgentTools.studyTools[1], (a, _) => _searchTopics(a)),
    _tool(AgentTools.studyTools[2], (a, _) => _getTopic(a)),
    _tool(AgentTools.studyTools[3], (a, _) => _saveTopic(a)),
    _tool(AgentTools.studyTools[4], (a, _) => _updateTopic(a)),
    _tool(AgentTools.studyTools[5], (a, _) => _linkTopics(a)),
    _tool(AgentTools.studyTools[6], (a, _) => _setMastery(a)),
    _tool(AgentTools.studyTools[7], (a, _) => _getMastery(a)),
    _tool(AgentTools.studyTools[8],
        (a, ctx) => _saveReview(a, ctx.scenarioContext as AgentScenarioContext?)),
    _tool(AgentTools.studyTools[9], (a, _) => _deleteTopic(a)),
    _tool(AgentTools.studyTools[10], (a, _) => _deleteCategory(a)),
    _tool(AgentTools.studyTools[11], (a, _) => _recommendTopics(a)),
    // —— 学习计划 ——
    _tool(PlanTools.planTools[0], (a, _) => _createPlan(a)),
    _tool(PlanTools.planTools[1], (a, _) => _getPlan(a)),
    _tool(PlanTools.planTools[2], (a, _) => _updatePlan(a)),
    _tool(PlanTools.planTools[3], (a, _) => _addMilestone(a)),
    _tool(PlanTools.planTools[4], (a, _) => _updateMilestone(a)),
    _tool(PlanTools.planTools[5], (a, _) => _deleteMilestone(a)),
    _tool(PlanTools.planTools[6], (a, _) => _addAssessment(a)),
    _tool(PlanTools.planTools[7], (a, _) => _deletePlan(a)),
    _tool(PlanTools.planTools[8], (a, _) => _deleteAssessment(a)),
    _tool(PlanTools.planTools[9], (a, _) => _createDayTask(a)),
    _tool(PlanTools.planTools[10], (a, _) => _listDayTasks(a)),
    _tool(PlanTools.planTools[11], (a, _) => _checkinDayTask(a)),
    _tool(PlanTools.planTools[12], (a, _) => _updateDayTask(a)),
    _tool(PlanTools.planTools[13], (a, _) => _deleteDayTask(a)),
    // 经验记忆：patch_memory 演进/沉淀偏好与教训。
    _tool(AskUserTools.patchMemory, (a, _) => _patchMemory(a)),
    // ask_user：由 AgentLoop 特殊拦截（挂起等用户作答），不走 executeTool。
    _tool(AskUserTools.askUser, (a, _) async => 'ask_user 由 AgentLoop 拦截处理'),
  ];

  SchemaToolDefinition _tool(
    Map<String, dynamic> schema,
    Future<String> Function(Map<String, dynamic> args, ToolExecContext ctx) exec,
  ) =>
      SchemaToolDefinition(schema, exec);

  @override
  List<ToolDefinition> get definitions => _defs;

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
    // 按 id 查表分发（原 24 个 case 的 switch 已拆成 _defs 注册）。
    for (final d in _defs) {
      if (d.id == name) {
        try {
          return await d.execute(
            args,
            ToolExecContext(
              toolCallId: toolCallId,
              scenarioContext: context,
              onProgress: onProgress,
            ),
          );
        } on ToolArgsException catch (e) {
          // 必填参数校验统一在入口转友好报错，handler 内无需各自写 if 链。
          return e.message;
        }
      }
    }
    return '未知工具: $name';
  }

  // ===================== 知识点 / 批改 =====================

  Future<String> _listTopics(Map<String, dynamic> args) async {
    final path = _argStr(args, 'path');
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

  Future<String> _searchTopics(Map<String, dynamic> args) async {
    const limit = 30;
    final keyword = _reqStr(args, 'keyword');
    final offset = _argInt(args, 'offset');
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

  /// 向用户推荐知识库中与话题相关的知识点（只读，前端渲染可点卡片）。
  ///
  /// 与 [_searchTopics] 的区别：这里是对用户的推荐展示（标题命中优先、上限 8 条、
  /// 无需分页），而 search_topics 是 AI 内部查重浏览。返回 items 全量即结果，
  /// 由前端把工具结果渲染成「相关知识点」卡片列表。
  Future<String> _recommendTopics(Map<String, dynamic> args) async {
    const limit = 8;
    final keyword = _reqStr(args, 'keyword');
    final result = await topics.searchWithTitlePriority(keyword, limit: limit);
    final items = <Map<String, Object?>>[];
    for (final it in result.items) {
      final path = await categories.pathOf(it.categoryId);
      items.add({'id': it.id, 'title': it.title, 'path': path.join('/')});
    }
    return jsonEncode({'items': items});
  }

  Future<String> _getTopic(Map<String, dynamic> args) async {
    final id = _reqInt(args, 'id');
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

  /// 确保 topic 有 FSRS 调度行：无行则建默认行并立即可复习。
  ///
  /// 默认行 S=0、D=5、reps=0、lapses=0、lastReviewedAt=null、dueAt=now。
  /// `dueAt <= now` ⇒ 立刻进 dueNow() 队列，今日待复习数随之 +1。
  /// [force]=true 时无条件建行（fresh insert 必然无行）；false 时已有行则尊重
  /// 历史 FSRS 状态不动。异常静默吞掉（topic 本身已落库，调度行可由后续
  /// set_mastery 兜底，不让调度失败破坏 save_topic 的成功语义）。
  Future<void> _ensureDefaultSchedule(int topicId, {required bool force}) async {
    try {
      if (!force) {
        final existing = await schedules.findByTopic(topicId);
        if (existing != null) return;
      }
      await schedules.upsert(TopicSchedule(
        topicId: topicId,
        stability: 0,
        difficulty: 5.0,
        reps: 0,
        lapses: 0,
        lastReviewedAt: null,
        dueAt: DateTime.now(),
      ));
    } catch (_) {
      // 静默：见方法 doc。不 rethrow。
    }
  }

  Future<String> _saveTopic(Map<String, dynamic> args) async {
    final path = _reqStr(args, 'path');
    final title = _reqStr(args, 'title');
    final question = _reqStr(args, 'question');
    final summary = _reqStr(args, 'summary');
    final existing = await topics.findByTitle(title);
    if (existing != null) {
      await _ensureDefaultSchedule(existing.id!, force: false);
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
        // UNIQUE 冲突理论上必能查到已存在的同 title 记录；防御性判空后转「已存在」。
        if (existing == null) rethrow;
        final id = existing.id!;
        await _ensureDefaultSchedule(id, force: false);
        await onTopicTouched?.call(id);
        return jsonEncode(SaveTopicResult(
          id: id,
          isNew: false,
          message: '知识点「$title」已存在。如需补充答案请用 update_topic。',
        ).toJson());
      }
      rethrow;
    }
    await _ensureDefaultSchedule(id, force: true);
    await onTopicTouched?.call(id);
    return jsonEncode(SaveTopicResult(
      id: id,
      isNew: true,
      message: '已保存知识点「$title」(id=$id)，路径 $path',
    ).toJson());
  }

  Future<String> _updateTopic(Map<String, dynamic> args) async {
    final id = _reqInt(args, 'id');
    final summary = _reqStr(args, 'summary');
    final existing = await topics.findById(id);
    if (existing == null) return '知识点 id=$id 不存在';
    await topics.updateSummary(id, summary);
    await onTopicTouched?.call(id);
    return '已更新知识点「${existing.title}」的答案';
  }

  Future<String> _linkTopics(Map<String, dynamic> args) async {
    // 用 _reqEnum/_reqInt 而非 `as` 强转：模型流式输出偶发吐空 args / 非法 JSON
    // 会让 _parseArgs 退到 P0 防御分支时 args 为 null（外层不上 executeTool），
    // 但即便绕过、空 Map 进来也不该抛 TypeError。
    final type = _reqEnum(args, 'type', const {'prerequisite', 'related'});
    final from = _reqInt(args, 'from');
    final to = _reqInt(args, 'to');
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

  Future<String> _setMastery(Map<String, dynamic> args) async {
    final topicId = _reqInt(args, 'topic_id');
    final status = _reqStr(args, 'status');
    final reason = _reqStr(args, 'reason');
    final parsed = MasteryStatusX.fromWire(status);
    if (parsed == MasteryStatus.unknown) {
      return 'status 不合法(允许 learning/mastered/weak,禁止 unknown)';
    }
    await mastery.log(topicId, parsed, reason: reason);
    final corrected = await schedules.applyMasteryOverride(topicId: topicId, status: parsed);
    return '已记录掌握度: $status, 已同步 schedule (S=${corrected.stability.toStringAsFixed(2)}, D=${corrected.difficulty.toStringAsFixed(2)}) (reason: $reason)';
  }

  Future<String> _getMastery(Map<String, dynamic> args) async {
    final topicId = _reqInt(args, 'topic_id');
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
    final summary = _reqStr(args, 'summary');
    final itemsRaw = args['items'];
    if (itemsRaw is! List) return '参数 items 缺失或非数组: ${args['items']}';
    final items = <ReviewItem>[];
    for (final (i, raw) in itemsRaw.indexed) {
      if (raw is! Map) return '参数 items 含非对象项(第 ${i + 1} 项): $raw';
      final item = _parseReviewItem(Map<String, dynamic>.from(raw));
      if (item == null) {
        return '参数 items[${i + 1}] 存在非法字段，请检查 question/verdict/analysis 是否齐全';
      }
      items.add(item);
    }
    final sessionId = ctx?.extra['chat_session_id'] as int?;
    final id = await reviews.save(chatSessionId: sessionId, summary: summary, items: items);
    return '已保存批改(共 ${items.length} 题,review_id=$id)';
  }

  /// 解析单个批改条目：question/verdict/analysis 必填，seq/user_answer/topic_ids
  /// 可选。字段非法返回 null，由 [_saveReview] 统一报错定位第几项。
  ReviewItem? _parseReviewItem(Map<String, dynamic> m) {
    final question = _argStr(m, 'question');
    final verdict = _argStr(m, 'verdict');
    final analysis = _argStr(m, 'analysis');
    if (question == null || verdict == null || analysis == null) return null;
    return ReviewItem(
      seq: _asInt(m['seq']) ?? 0,
      question: question,
      userAnswer: _argStr(m, 'user_answer'),
      verdict: verdict,
      analysis: analysis,
      topicIds: _topicIdsOf(m['topic_ids']),
    );
  }

  /// topic_ids 数组 → int 列表；非数组/含非整项时丢弃该元素（容错，不阻断保存）。
  List<int> _topicIdsOf(Object? raw) =>
      raw is List ? raw.map((e) => _asInt(e)).whereType<int>().toList() : const [];

  /// 删除知识点：id 与 title 二选一，id 优先。删后 FK CASCADE 自动清掌握度/调度/边。
  /// 校验：二者都缺 → 拒绝；id/title 均无法定位 → 返回未找到。
  Future<String> _deleteTopic(Map<String, dynamic> args) async {
    final id = _argInt(args, 'id');
    final title = _argStr(args, 'title');
    if (id == null && (title == null || title.trim().isEmpty)) {
      return jsonEncode({'ok': false, 'deleted': false, 'msg': '需传入 id 或 title 之一'});
    }
    int targetId;
    if (id != null) {
      final t = await topics.findById(id);
      if (t == null) {
        return jsonEncode({'ok': false, 'deleted': false, 'msg': '知识点 id=$id 不存在'});
      }
      targetId = id;
    } else {
      final t = await topics.findByTitle(title!.trim());
      if (t == null) {
        return jsonEncode({'ok': false, 'deleted': false, 'msg': '知识点「$title」不存在'});
      }
      targetId = t.id!;
    }
    final affected = await topics.delete(targetId);
    await onTopicTouched?.call(targetId);
    return jsonEncode({
      'ok': affected > 0,
      'deleted': affected > 0,
      'msg': affected > 0 ? '已删除知识点(id=$targetId)，关联掌握度/调度/图谱边一并清除' : '未删除',
    });
  }

  /// 删除分类子树：按 path 解析到末端分类，删整棵子树（后代分类 + 各层知识点）。
  /// path 不存在 → 返回未找到，不报错。
  Future<String> _deleteCategory(Map<String, dynamic> args) async {
    final pathStr = _argStr(args, 'path');
    if (pathStr == null) {
      return jsonEncode({'ok': false, 'msg': '参数 path 缺失或非字符串: ${args['path']}'});
    }
    final segments = pathStr.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return jsonEncode({'ok': false, 'msg': 'path 不能为空'});
    }
    final cat = await categories.findByPath(segments);
    if (cat == null) {
      return jsonEncode({'ok': false, 'msg': '分类路径不存在: $pathStr'});
    }
    final result = await categories.deleteSubtree(cat.id!);
    return jsonEncode({
      'ok': true,
      'deleted_categories': result.categories,
      'deleted_topics': result.topics,
      'msg': '已删除分类「$pathStr」及其下 ${result.categories} 个分类、${result.topics} 个知识点',
    });
  }

  /// 宽松 int 解析：容忍 LLM 把数字序列化成字符串或 num（国产 OpenAI 兼容端点常见）。
  /// 解析失败返回 null，由调用方兜底。
  int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 可选参数：缺失/非字符串返回 null，由 handler 按需判空。
  String? _argStr(Map<String, dynamic> args, String key) {
    final v = args[key];
    return v is String ? v : null;
  }

  /// 可选参数：缺失/非整数返回 null。
  int? _argInt(Map<String, dynamic> args, String key) => _asInt(args[key]);

  // —— 必填参数：缺失/类型错抛 [ToolArgsException]，由 executeTool 入口统一转
  // 友好报错，handler 不再各自写 if 链。——

  /// 必填 String 参数；缺失/非字符串抛 [ToolArgsException]。
  String _reqStr(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is! String) throw ToolArgsException('参数 $key 缺失或非字符串: $v');
    return v;
  }

  /// 必填 int 参数；缺失/非整数抛 [ToolArgsException]。
  int _reqInt(Map<String, dynamic> args, String key) {
    final v = _asInt(args[key]);
    if (v == null) throw ToolArgsException('参数 $key 缺失或非整数: ${args[key]}');
    return v;
  }

  /// 必填枚举参数：值必须属于 [allowed]；否则抛 [ToolArgsException]。
  String _reqEnum(Map<String, dynamic> args, String key, Set<String> allowed) {
    final v = _reqStr(args, key);
    if (!allowed.contains(v)) {
      throw ToolArgsException('参数 $key 必须是 ${allowed.join('/')}');
    }
    return v;
  }

  // ===================== 学习计划 =====================

  /// 宽松日期解析：非法/非日期字符串返回 null，由调用方兜底报错（替代裸
  /// `DateTime.parse` 的 FormatException，避免污染下一轮 LLM 调用）。
  DateTime? _tryParseDate(String s) => DateTime.tryParse(s);

  /// yyyy-MM-dd 格式化（本地无 intl 依赖）。
  String _fmtYmd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<String> _createPlan(Map<String, dynamic> args) async {
    final name = _argStr(args, 'name');
    final examDate = _argStr(args, 'exam_date');
    final examContent = _argStr(args, 'exam_content');
    final target = _argStr(args, 'target');
    final dailyMinutes = _argInt(args, 'daily_minutes');
    final currentLevel = _argStr(args, 'current_level');
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
    final examDateDt = _tryParseDate(examDate!);
    if (examDateDt == null) return '参数 exam_date 格式非法: $examDate';
    final now = DateTime.now();
    final planId = await plans.insertPlan(Plan(
      name: name!,
      examDate: examDateDt,
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

  Future<String> _getPlan(Map<String, dynamic> args) async {
    final planId = _reqInt(args, 'plan_id');
    final detail = await plans.getPlanDetail(planId);
    final msList = detail.milestones.map((m) => {
          'id': m.id, 'title': m.title, 'description': m.description,
          'target_date': _fmtYmd(m.targetDate),
          'status': m.status, 'sort_order': m.sortOrder,
        }).toList();
    final aList = detail.assessments.map((a) => {
          'id': a.id, 'score': a.score, 'note': a.note,
          'assessed_at': _fmtYmd(a.assessedAt),
        }).toList();
    return jsonEncode({
      'plan': {
        'id': detail.plan.id, 'name': detail.plan.name,
        'exam_date': _fmtYmd(detail.plan.examDate),
        'exam_content': detail.plan.examContent, 'target': detail.plan.target,
        'daily_minutes': detail.plan.dailyMinutes, 'current_level': detail.plan.currentLevel,
      },
      'milestones': msList,
      'assessments': aList,
    });
  }

  Future<String> _updatePlan(Map<String, dynamic> args) async {
    final pid = _reqInt(args, 'plan_id');
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final examDateStr = _argStr(args, 'exam_date');
    DateTime examDate;
    if (examDateStr == null) {
      examDate = existing.examDate;
    } else {
      final d = _tryParseDate(examDateStr);
      if (d == null) return '参数 exam_date 格式非法: $examDateStr';
      examDate = d;
    }
    await plans.updatePlan(Plan(
      id: pid,
      name: _argStr(args, 'name') ?? existing.name,
      examDate: examDate,
      examContent: _argStr(args, 'exam_content') ?? existing.examContent,
      target: _argStr(args, 'target') ?? existing.target,
      dailyMinutes: _argInt(args, 'daily_minutes') ?? existing.dailyMinutes,
      currentLevel: existing.currentLevel,
      createdAt: existing.createdAt,
      updatedAt: existing.createdAt,
    ));
    return '已更新计划「${existing.name}」';
  }

  Future<String> _addMilestone(Map<String, dynamic> args) async {
    final pid = _reqInt(args, 'plan_id');
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final title = _reqStr(args, 'title');
    final description = _reqStr(args, 'description');
    final targetDateStr = _reqStr(args, 'target_date');
    final targetDate = _tryParseDate(targetDateStr);
    if (targetDate == null) return '参数 target_date 格式非法: $targetDateStr';
    final now = DateTime.now();
    final id = await plans.addMilestone(Milestone(
      planId: pid,
      title: title,
      description: description,
      targetDate: targetDate,
      sortOrder: _argInt(args, 'sort_order') ?? 0,
      createdAt: now,
      updatedAt: now,
    ));
    return '已添加节点「$title」(id=$id)';
  }

  Future<String> _updateMilestone(Map<String, dynamic> args) async {
    final mid = _reqInt(args, 'milestone_id');
    final status = _argStr(args, 'status');
    if (status != null && status != 'pending' && status != 'done') {
      return 'status 必须是 pending 或 done，收到: $status';
    }
    final targetDateStr = _argStr(args, 'target_date');
    final targetDate = targetDateStr == null ? null : _tryParseDate(targetDateStr);
    if (targetDateStr != null && targetDate == null) return '参数 target_date 格式非法: $targetDateStr';
    await plans.updateMilestone(
      mid,
      title: _argStr(args, 'title'),
      description: _argStr(args, 'description'),
      targetDate: targetDate,
      sortOrder: _argInt(args, 'sort_order'),
      status: status,
    );
    return '已更新节点 id=$mid';
  }

  Future<String> _deleteMilestone(Map<String, dynamic> args) async {
    final milestoneId = _reqInt(args, 'milestone_id');
    await plans.deleteMilestone(milestoneId);
    return '已删除节点 id=$milestoneId';
  }

  Future<String> _addAssessment(Map<String, dynamic> args) async {
    final pid = _reqInt(args, 'plan_id');
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final now = DateTime.now();
    final assessedAtStr = _argStr(args, 'assessed_at');
    DateTime assessedAt;
    if (assessedAtStr == null) {
      assessedAt = now;
    } else {
      final d = _tryParseDate(assessedAtStr);
      if (d == null) return '参数 assessed_at 格式非法: $assessedAtStr';
      assessedAt = d;
    }
    final score = _argInt(args, 'score');
    final id = await plans.addAssessment(Assessment(
      planId: pid,
      score: score,
      note: _argStr(args, 'note'),
      assessedAt: assessedAt,
      createdAt: now,
    ));
    return jsonEncode({'ok': true, 'assessment_id': id, 'score': score});
  }

  Future<String> _deletePlan(Map<String, dynamic> args) async {
    final planId = _reqInt(args, 'plan_id');
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

  Future<String> _deleteAssessment(Map<String, dynamic> args) async {
    final assessmentId = _reqInt(args, 'assessment_id');
    await plans.deleteAssessment(assessmentId);
    return '已删除测评 id=$assessmentId';
  }

  Future<String> _createDayTask(Map<String, dynamic> args) async {
    final pid = _reqInt(args, 'plan_id');
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final title = _reqStr(args, 'title');
    final taskDateStr = _reqStr(args, 'task_date');
    final taskDate = _tryParseDate(taskDateStr);
    if (taskDate == null) return '参数 task_date 格式非法: $taskDateStr';
    final now = DateTime.now();
    final id = await dayTasks.addTask(PlanDayTask(
      planId: pid,
      taskDate: taskDate,
      title: title,
      sortOrder: _argInt(args, 'sort_order') ?? 0,
      createdAt: now,
      updatedAt: now,
    ));
    return '已添加每日任务「$title」(id=$id)';
  }

  Future<String> _listDayTasks(Map<String, dynamic> args) async {
    final pid = _reqInt(args, 'plan_id');
    final date = _argStr(args, 'task_date');
    final dateDt = date == null ? null : _tryParseDate(date);
    if (date != null && dateDt == null) return '参数 task_date 格式非法: $date';
    final list = date != null
        ? await dayTasks.findByPlanAndDate(pid, dateDt!)
        : await dayTasks.findByPlan(pid);
    String fmtDateTime(DateTime d) =>
        '${_fmtYmd(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return jsonEncode({
      'plan_id': pid,
      'count': list.length,
      'tasks': list
          .map((t) => {
                'id': t.id,
                'task_date': _fmtYmd(t.taskDate),
                'title': t.title,
                'status': t.status,
                'sort_order': t.sortOrder,
                'done_at': t.doneAt == null ? null : fmtDateTime(t.doneAt!),
              })
          .toList(),
    });
  }

  Future<String> _checkinDayTask(Map<String, dynamic> args) async {
    final tid = _reqInt(args, 'task_id');
    final status = _reqEnum(args, 'status', const {'pending', 'done'});
    await dayTasks.updateTask(tid, status: status);
    return '已把任务 $tid 标记为 $status';
  }

  Future<String> _updateDayTask(Map<String, dynamic> args) async {
    final tid = _reqInt(args, 'task_id');
    final taskDateStr = _argStr(args, 'task_date');
    final taskDate = taskDateStr == null ? null : _tryParseDate(taskDateStr);
    if (taskDateStr != null && taskDate == null) return '参数 task_date 格式非法: $taskDateStr';
    await dayTasks.updateTask(
      tid,
      title: _argStr(args, 'title'),
      taskDate: taskDate,
      sortOrder: _argInt(args, 'sort_order'),
    );
    return '已更新每日任务 id=$tid';
  }

  Future<String> _deleteDayTask(Map<String, dynamic> args) async {
    final taskId = _reqInt(args, 'task_id');
    await dayTasks.deleteTask(taskId);
    return '已删除每日任务 id=$taskId';
  }

  // ===================== 经验记忆（patch_memory 工具） =====================

  Future<String> _patchMemory(Map<String, dynamic> args) async {
    final action = _reqEnum(args, 'action', {'add', 'replace', 'remove'});
    final op = switch (action) {
      'add' => AddMemoryOp(_reqStr(args, 'new_text')),
      'replace' => _replaceOpWithTarget(args),
      'remove' => _removeOpWithTarget(args),
      _ => throw ToolArgsException('未知 action: $action'),
    };
    final result = await patchMemory(op);
    return result.message;
  }

  ReplaceMemoryOp _replaceOpWithTarget(Map<String, dynamic> args) {
    final target = _reqStr(args, 'target_text');
    if (target.trim().isEmpty) {
      throw ToolArgsException('参数 target_text 不能为空');
    }
    return ReplaceMemoryOp(target, _reqStr(args, 'new_text'));
  }

  RemoveMemoryOp _removeOpWithTarget(Map<String, dynamic> args) {
    final target = _reqStr(args, 'target_text');
    if (target.trim().isEmpty) {
      throw ToolArgsException('参数 target_text 不能为空');
    }
    return RemoveMemoryOp(target);
  }

  @override
  Future<MemoryPatchResult> patchMemory(MemoryPatchOp op) async {
    final all = await memories.queryByScenario(id);
    final allTexts = all.map((m) => m.content).toList();
    var changed = false;
    var successMsg = '记忆已更新';
    switch (op) {
      case AddMemoryOp(:final content):
        if (content.trim().isEmpty) {
          return MemoryPatchResult(false, '记忆内容不能为空');
        }
        if (isDuplicate(allTexts, content)) {
          return MemoryPatchResult(true, '重复，已跳过（记忆已存在相同内容）');
        }
        if (isOverBudget(allTexts, additional: [content])) {
          return MemoryPatchResult(false, _budgetError(allTexts));
        }
        await memories.add(id, content);
        changed = true;
        successMsg = '已新增记忆';
        break;
      case ReplaceMemoryOp(:final target, :final newContent):
        if (newContent.trim().isEmpty) {
          return MemoryPatchResult(false, '新内容不能为空');
        }
        final hits = _substringHits(all, target);
        if (hits.isEmpty) {
          return MemoryPatchResult(false, _notFoundError(allTexts, target));
        }
        if (hits.length > 1) {
          return MemoryPatchResult(false, _ambiguousError(allTexts, target, hits));
        }
        final after = [...allTexts];
        after[hits.single] = newContent;
        if (isOverBudget(after)) {
          return MemoryPatchResult(false, _budgetError(after));
        }
        await memories.update(all[hits.single].id!, newContent);
        changed = true;
        successMsg = '已更新记忆';
        break;
      case RemoveMemoryOp(:final target):
        final hits = _substringHits(all, target);
        if (hits.isEmpty) {
          return MemoryPatchResult(false, _notFoundError(allTexts, target));
        }
        if (hits.length > 1) {
          return MemoryPatchResult(false, _ambiguousError(allTexts, target, hits));
        }
        await memories.delete(all[hits.single].id!);
        changed = true;
        successMsg = '已删除记忆';
        break;
    }
    // 成功落库后同步缓存：修复「run 中途 patch 后后续轮次 <memory-context> 看不到」。
    // 失败路径未改库，无需刷新。
    if (changed) {
      _memCache = (await memories.queryByScenario(id)).map((m) => m.content).toList();
    }
    return MemoryPatchResult(true, successMsg);
  }

  /// 子串命中下标（不区分大小写）。空=零命中，多=需更精确子串。
  List<int> _substringHits(List<AgentMemory> all, String target) {
    final lower = target.toLowerCase();
    return [
      for (var i = 0; i < all.length; i++)
        if (all[i].content.toLowerCase().contains(lower)) i,
    ];
  }

  String _budgetError(List<String> texts) =>
      '记忆已超容量上限（${kMaxMemoryChars} 字符），当前 ${totalChars(texts)} 字符。'
      '请用 replace/remove 合并或删除旧条目腾出空间后重试。当前条目：\n${_numbered(texts)}';

  String _notFoundError(List<String> texts, String target) =>
      '未找到包含「$target」的记忆条目。当前条目：\n${_numbered(texts)}';

  String _ambiguousError(List<String> texts, String target, List<int> hits) =>
      '「$target」匹配到 ${hits.length} 条记忆，请用更精确的子串区分。命中：\n'
      '${hits.map((i) => '[${i + 1}] ${texts[i]}').join('\n')}';

  String _numbered(List<String> texts) =>
      texts.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');

  @override
  Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;

  @override
  Future<List<String>> getMemories() async {
    _memCache = (await memories.queryByScenario(id)).map((m) => m.content).toList();
    return _memCache;
  }

  @override
  Future<void> cleanup() async {}
}
