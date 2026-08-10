import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 假 LLM：用脚本驱动多轮响应。
class _FakeLlm extends LlmProvider {
  _FakeLlm(this.script) : super(config: LlmConfig(
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

class _FakeScenario implements AgentScenario {
  final List<String> executed = [];
  @override String get id => 'fake';
  @override String get displayName => 'Fake';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;
  @override String buildSystemPrompt(AgentScenarioContext ctx) => 'sys';
  @override Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    executed.add(name);
    return '{"ok":true}';
  }
  @override Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;
  @override Future<List<String>> getMemories() async => [];
  @override Future<MemoryPatchResult> patchMemory(int? index, String newText) async => MemoryPatchResult(true, '');
  @override Future<void> cleanup() async {}
}

void main() {
  test('AgentLoop 执行工具后结束', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [ToolCall(id: 'c1', name: 'query_topics', arguments: '{"subject":"数学"}')])],
      const [LlmStreamChunk(textDelta: '已完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(scenario.executed, ['query_topics']);
    expect(events.any((e) => e is AgentDoneEvent), isTrue);
    expect(events.any((e) => e is ToolCallStartEvent), isTrue);
  });

  test('AgentRoundEndEvent 携带本轮 assistant+tool 消息', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [ToolCall(id: 'c1', name: 'query_topics', arguments: '{"subject":"数学"}')])],
      const [LlmStreamChunk(textDelta: '已完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    final roundEnds = events.whereType<AgentRoundEndEvent>().toList();
    expect(roundEnds, hasLength(1)); // 只第 1 轮有工具调用
    final newMsgs = roundEnds.single.newMessages;
    expect(newMsgs, hasLength(2)); // assistant + tool
    expect(newMsgs[0].role, 'assistant');
    expect(newMsgs[0].toolCalls, hasLength(1));
    expect(newMsgs[0].toolCalls!.single.id, 'c1');
    expect(newMsgs[1].role, 'tool');
    expect(newMsgs[1].toolCallId, 'c1');
  });

  test('无工具调用的轮不 yield AgentRoundEndEvent', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '直接回答')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.whereType<AgentRoundEndEvent>(), isEmpty);
  });
}
