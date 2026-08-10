import 'dart:convert';
import '../../models/models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/category_repository.dart';
import '../../repos/mastery_repository.dart';
import '../../repos/review_repository.dart';
import '../../repos/topic_edge_repository.dart';
import '../../repos/topic_repository.dart';
import '../agent_scenario.dart';
import '../agent_tools.dart';

/// 学习伴侣场景：8 工具，工具执行调 Repository，记忆来自 agent_memory 表。
class StudyScenario implements AgentScenario {
  final CategoryRepository categories;
  final TopicRepository topics;
  final TopicEdgeRepository edges;
  final AgentMemoryRepository memories;
  final MasteryRepository mastery; // 掌握度记录/查询
  final ReviewRepository reviews; // 批改记录（Task 3 填实现，本阶段仅注入）

  StudyScenario({
    required this.categories,
    required this.topics,
    required this.edges,
    required this.memories,
    required this.mastery,
    required this.reviews,
  });

  @override String get id => 'study';
  @override String get displayName => '学习伴侣';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    return '''你是学习伴侣 AI。职责是分析题目、批改作答、整理知识库、维护掌握度。

## 意图识别（每次输入先判断）
- 输入含用户作答（手写/文字答案） → 进入「批改流程」
- 纯题目（无作答） → 进入「分析流程」：分析题目涉及的知识点并整理进知识库
- 两者兼备 → 批改为主、分析为辅

## 批改流程（含作答时）
1. 逐题判定：对 / 部分对 / 错，给出解析
2. 从错误与部分对的作答中，识别暴露薄弱的知识点或技巧
3. 对每个薄弱点：search_topics 查是否存在
   - 存在 → get_topic 看详情、get_mastery 看现状；答案需补充/修正 → update_topic(id, summary)
   - 不存在 → save_topic 创建（技巧挂「技巧」分类）
4. set_mastery 维护掌握度，reason 写明判定依据：
   - 全对 → 升一级：unknown/weak→learning、learning→mastered、mastered 保持
   - 部分对 → learning（已 mastered 则回退 learning）
   - 全错 → weak
5. save_review 保存结构化批改明细（逐题对错/解析/涉及知识点），随后引导用户点卡片查看、可追问复盘

## 分析流程（纯题目）
按原有职责：分析题目涉及的知识点，整理进知识库（list/search/get/save/update/link）。

## 技巧与知识点同等待遇
技巧也是知识：按 学科/.../技巧/<名> 挂载；有自己的引子（何时用）与答案（怎么用）；
可建关联边、可设掌握度，处理方式与知识点完全一致。

## 知识点粒度原则（最高优先级）
- 一个知识点 = 一个引子(question) + 一个答案(summary)。
- 粒度必须低：若某内容需要多个引子才能讲清，拆成多个知识点分别保存。
- ❌错误："极限"(含定义/求法/定理) ❌正确："ε-δ极限定义""洛必达法则""夹逼定理"

## 写入前必先查（避免重复）
1. 先 search_topics(keyword) 搜索相关知识点，看是否已存在。
2. 命中 → get_topic(id) 看详情：
   - 答案需补充/修正 → update_topic(id, summary)
   - 识别到与已有知识点的依赖/关联 → link_topics(...)
3. 未命中 → list_topics(path) 找到正确分类挂载位置 → save_topic(path, title, question, summary)

## 分类
- path 形如"数学/高等数学/极限"，不存在的层级会自动创建。
- 知识点必须挂到最具体的分类（挂"极限"而非"高等数学"）。

## 关联边
- prerequisite：学A必须先会B，A依赖B(from=A,to=B)。
- related：无先后的相关知识点。
- 仅在分析出明确关系时建边，不要滥连。

## 经验记忆
$memBlock''';
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    switch (name) {
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
      default:
        return '未知工具: $name';
    }
  }

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
      return '知识点「$title」已存在(id=${existing.id})。如需补充答案请用 update_topic(id=${existing.id}, summary=...)';
    }
    final segments = path.split('/').where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return 'path 不能为空';
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
        return '知识点「$title」已存在(id=${existing?.id})。如需补充答案请用 update_topic(id=${existing?.id}, summary=...)';
      }
      rethrow;
    }
    return '已保存知识点「$title」(id=$id)，路径 $path';
  }

  Future<String> _updateTopic(int id, String summary) async {
    final existing = await topics.findById(id);
    if (existing == null) return '知识点 id=$id 不存在';
    await topics.updateSummary(id, summary);
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
    return '已记录掌握度: $status (reason: $reason)';
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
