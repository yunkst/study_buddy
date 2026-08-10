import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 假 LLM：用脚本驱动多轮响应。
class _FakeLlm extends LlmProvider {
  _FakeLlm(this.script) : super(config: LlmConfig(
        name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  /// 最近一次收到的消息列表（测试断言注入的 system 消息）。
  List<ChatMessage>? lastMessages;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) {
    lastMessages = messages;
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}

class _FakeScenario implements AgentScenario {
  final List<String> executed = [];
  AgentScenarioContext? lastCtx;
  @override String get id => 'fake';
  @override String get displayName => 'Fake';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;
  @override String buildSystemPrompt(AgentScenarioContext ctx) {
    lastCtx = ctx;
    return 'fake scenario prompt';
  }
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

  test('run 自动注入 buildSystemPrompt 的 system 消息,且 context 透传', () async {
    final fakeLlm = _FakeLlm(const [
      [LlmStreamChunk(textDelta: '完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: fakeLlm, scenario: scenario);
    await loop.run([
      const ChatMessage(role: 'user', content: 'hi'),
    ], context: const AgentScenarioContext(extra: {'k': 'v'})).toList();
    expect(scenario.lastCtx, isNotNull);
    expect(scenario.lastCtx!.extra, {'k': 'v'});
    // LLM 收到的消息首条是 system
    expect(fakeLlm.lastMessages!.first.role, 'system');
    expect(fakeLlm.lastMessages!.first.content, contains('fake scenario prompt'));
  });

  test('调用方已传 system 消息则不重复注入', () async {
    final fakeLlm = _FakeLlm(const [
      [LlmStreamChunk(textDelta: '完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: fakeLlm, scenario: scenario);
    await loop.run([
      const ChatMessage(role: 'system', content: 'custom sys'),
      const ChatMessage(role: 'user', content: 'hi'),
    ]).toList();
    expect(fakeLlm.lastMessages!.first.role, 'system');
    expect(fakeLlm.lastMessages!.first.content, 'custom sys');
  });
}
