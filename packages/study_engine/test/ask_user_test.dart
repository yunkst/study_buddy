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
    String? traceId,
  }) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}

class _FakeScenario implements AgentScenario {
  final List<String> executed = [];
  @override String get id => 'fake';
  @override String get displayName => 'Fake';
  @override List<Map<String, dynamic>> get tools => AskUserTools.studyToolsWithAsk;
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

const _askCall = ToolCall(
  id: 'ask-1',
  name: 'ask_user',
  arguments: '{"question":"哪门学科？","options":[{"label":"数学","value":"math"},{"label":"英语","value":"eng"}]}',
);

void main() {
  test('ask_user 全链路：挂起 → completeAskUser → 下一轮拿到答案', () async {
    // 第 1 轮调 ask_user；第 2 轮纯文本收尾。
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [_askCall])],
      const [LlmStreamChunk(textDelta: '已确认学科')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario());

    // 在 AskUserRequestedEvent 到达时从 listener 侧喂答案（模拟 UI 作答）。
    final events = await _runAndAnswerOn(loop, (req) {
      expect(req.question, '哪门学科？');
      expect(req.options.map((o) => o.value), ['math', 'eng']);
      expect(req.isFreeInput, isFalse);
      loop.completeAskUser('math');
    });

    expect(events.whereType<AskUserRequestedEvent>(), hasLength(1));
    final answered = events.whereType<AskUserAnsweredEvent>().toList();
    expect(answered, hasLength(1));
    expect(answered.single.toolCallId, 'ask-1');
    expect(answered.single.answer, 'math');
    expect(events.whereType<AgentDoneEvent>(), hasLength(1));

    // 工具结果 = 用户答案；RoundEnd 携带 assistant(toolCalls) + tool(answer)。
    final roundEnd = events.whereType<AgentRoundEndEvent>().single;
    expect(roundEnd.newMessages, hasLength(2));
    expect(roundEnd.newMessages[1].role, 'tool');
    expect(roundEnd.newMessages[1].content, 'math');
    expect(roundEnd.newMessages[1].toolCallId, 'ask-1');
  });

  test('ask_user 多选：answer 用 ", " 拼接回灌', () async {
    final llm = _FakeLlm([
      const [
        LlmStreamChunk(
          textDelta: '',
          toolCalls: [
            ToolCall(
              id: 'ask-2',
              name: 'ask_user',
              arguments:
                  '{"question":"选薄弱科目","multi_select":true,'
                  '"options":[{"label":"高数","value":"calc"},{"label":"线代","value":"linalg"},{"label":"概率","value":"prob"}]}',
            ),
          ],
        ),
      ],
      const [LlmStreamChunk(textDelta: '知道了')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario());
    final events = await _runAndAnswerOn(loop, (req) {
      expect(req.multiSelect, isTrue);
      loop.completeAskUser('calc, linalg');
    });

    final answered = events.whereType<AskUserAnsweredEvent>().single;
    expect(answered.answer, 'calc, linalg');
    final roundEnd = events.whereType<AgentRoundEndEvent>().single;
    expect(roundEnd.newMessages[1].content, 'calc, linalg');
  });

  test('ask_user 挂起期间用户中止 → 工具结果回填“用户取消”，且不泄漏', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [_askCall])],
      const [LlmStreamChunk(textDelta: '重试或放弃')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario());
    final events = await _runAndAnswerOn(loop, (req) {
      loop.abortAskUser('用户关闭抽屉');
    });

    final end = events.whereType<ToolCallEndEvent>().single;
    expect(end.name, 'ask_user');
    expect(end.result, '用户取消或会话中断');
    expect(loop.askUserCompleter, isNull);
    expect(loop.pendingAskRequest, isNull);
  });

  test('ask_user 无选项退化为自由输入（isFreeInput）', () async {
    final llm = _FakeLlm([
      const [
        LlmStreamChunk(
          textDelta: '',
          toolCalls: [
            ToolCall(id: 'ask-3', name: 'ask_user', arguments: '{"question":"你的目标分是多少？"}'),
          ],
        ),
      ],
      const [LlmStreamChunk(textDelta: '收到')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario());
    final events = await _runAndAnswerOn(loop, (req) {
      expect(req.isFreeInput, isTrue);
      expect(req.options, isEmpty);
      loop.completeAskUser('目标 380 分');
    });
    final roundEnd = events.whereType<AgentRoundEndEvent>().single;
    expect(roundEnd.newMessages[1].content, '目标 380 分');
  });
}

/// 启动 [loop.run]，在 AskUserRequestedEvent 到达时调用 [answer] 喂答案，收集全部事件。
Future<List<AgentEvent>> _runAndAnswerOn(
  AgentLoop loop,
  void Function(AskUserRequest request) answer,
) async {
  final events = <AgentEvent>[];
  await loop
      .run([const ChatMessage(role: 'system', content: 'sys')])
      .listen((e) {
        events.add(e);
        if (e is AskUserRequestedEvent) answer(e.request);
      })
      .asFuture<void>();
  return events;
}
