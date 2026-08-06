import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('Agent 调 save_topic 后知识点落库', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final memories = AgentMemoryRepository(sdb);
    final scenario = StudyScenario(subjects: subjects, topics: topics, memories: memories);

    // 手动执行一次工具，验证落库（集成测试不依赖真实网络）
    final result = await scenario.executeTool('save_topic', {
      'subject': '物理',
      'title': '牛顿第二定律',
      'domain': '力学',
    });
    expect(result, contains('已保存'));

    final phys = await subjects.findByName('物理');
    expect(phys, isNotNull);
    final list = await topics.queryBySubject(phys!.id!);
    expect(list, hasLength(1));
    expect(list.first.title, '牛顿第二定律');
    expect(list.first.domain, '力学');

    // 通过 AgentLoop 端到端：mock LLM 返回 save_topic
    final llm = _ScriptedLlm([
      const [
        LlmStreamChunk(textDelta: '', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"subject":"物理","title":"惯性","domain":"力学"}'),
        ])
      ],
      const [LlmStreamChunk(textDelta: '已为你保存知识点')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.any((e) => e is ToolCallEndEvent), isTrue);
    final list2 = await topics.queryBySubject(phys.id!);
    expect(list2.any((t) => t.title == '惯性'), isTrue);

    await sdb.close();
  });
}

class _ScriptedLlm extends LlmProvider {
  _ScriptedLlm(this.script) : super(config: LlmConfig(
        name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}
