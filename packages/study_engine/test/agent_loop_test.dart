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
      {void Function(String p)? onProgress, String? toolCallId, AgentScenarioContext? context}) async {
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

  test('无工具调用的轮不 yield AgentRoundEndEvent,Done 携带最终文本', () async {
    // 契约固定：纯文本轮 = TextDelta(s) + AgentDoneEvent(finalText=累积文本)，NO RoundEnd。
    // 这是 Notifier 区分「纯文本轮需 append finalText」「工具轮需 append newMessages」的依据。
    // 注意：_FakeLlm 的 script 每个元素是一次 LLM 调用的全部 chunks。
    final llm = _FakeLlm([
      const [
        LlmStreamChunk(textDelta: '直接'),
        LlmStreamChunk(textDelta: '回答'),
      ],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events =
        await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();

    // 纯文本轮不 yield RoundEnd
    expect(events.whereType<AgentRoundEndEvent>(), isEmpty);
    // 事件序列里要有 TextDelta 和最终 AgentDoneEvent
    expect(events.whereType<TextDeltaEvent>(), isNotEmpty);
    // 最后一个事件必须是 AgentDoneEvent，其 finalText = 所有 TextDelta 的累积
    expect(events.last, isA<AgentDoneEvent>());
    final done = events.last as AgentDoneEvent;
    expect(done.finalText, '直接回答');
  });

  test('纯文本轮事件序列: TextDelta* + AgentDoneEvent(finalText),无 RoundEnd', () async {
    // 多 delta 流式输出验证：finalText 是累积值，不是最新 delta
    final llm = _FakeLlm([
      const [
        LlmStreamChunk(textDelta: '你好'),
        LlmStreamChunk(textDelta: '，'),
        LlmStreamChunk(textDelta: '世界'),
      ],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events =
        await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();

    // 严格结构：事件流只含 Started + TextDeltas + Done,不含 RoundEnd
    final types = events.map((e) => e.runtimeType).toList();
    expect(types, [
      AgentStartedEvent,
      TextDeltaEvent,
      TextDeltaEvent,
      TextDeltaEvent,
      AgentDoneEvent,
    ]);
    final done = events.last as AgentDoneEvent;
    expect(done.finalText, '你好，世界');
  });
}
