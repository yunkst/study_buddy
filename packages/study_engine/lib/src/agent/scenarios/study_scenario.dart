import '../../models/models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/subject_repository.dart';
import '../../repos/topic_repository.dart';
import '../agent_scenario.dart';
import '../agent_tools.dart';

/// 学习伴侣场景：tools = save_topic/query_topics，工具执行调 Repository，
/// 记忆来自 agent_memory 表。
class StudyScenario implements AgentScenario {
  final SubjectRepository subjects;
  final TopicRepository topics;
  final AgentMemoryRepository memories;

  StudyScenario({required this.subjects, required this.topics, required this.memories});

  @override String get id => 'study';
  @override String get displayName => '学习伴侣';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    final subjectLine = ctx.currentSubject == null ? '' : '当前学科：${ctx.currentSubject}\n';
    return '''你是学习伴侣 AI。你的职责是帮助用户分析题目、讲解知识点、整理知识库、并跟踪掌握状态。

$subjectLine## 工作原则
- 分析题目后，用 save_topic 把涉及的知识点入库（学科不存在会自动创建）。
- 用 query_topics 查看已有知识点，避免重复入库。
- 简洁、聚焦知识点本身。

## 经验记忆
$memBlock''';
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    switch (name) {
      case 'save_topic':
        final subjectName = args['subject'] as String;
        final title = args['title'] as String;
        final domain = args['domain'] as String?;
        final summary = args['summary'] as String?;
        final subject = await subjects.ensureCreate(subjectName);
        final id = await topics.insert(Topic(
          subjectId: subject.id!,
          domain: domain,
          title: title,
          summary: summary,
          createdAt: DateTime.now(),
        ));
        return '已保存知识点“$title”（id=$id），学科“$subjectName”';
      case 'query_topics':
        final subjectName = args['subject'] as String;
        final domain = args['domain'] as String?;
        final subject = await subjects.findByName(subjectName);
        if (subject == null) return '学科“$subjectName”不存在';
        final list = await topics.queryBySubject(subject.id!, domain: domain);
        if (list.isEmpty) return '没有匹配的知识点';
        return list.map((t) => '- ${t.title}${t.domain == null ? "" : "（${t.domain}）"}').join('\n');
      default:
        return '未知工具: $name';
    }
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
