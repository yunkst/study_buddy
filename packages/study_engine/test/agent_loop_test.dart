import 'dart:async';
import 'dart:io';
import 'dart:math';

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
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;
  @override String buildSystemPrompt(AgentScenarioContext ctx) => 'sys';
  @override List<ChatMessage> composeApiMessages(List<ChatMessage> base, AgentScenarioContext ctx) => base;
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

  test('AgentLoop 通过 sink 上报开始/完成并带 traceId', () async {
    final logger = _RecordingLogger();
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: 'done')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario(), logger: logger);
    await loop
        .run([const ChatMessage(role: 'system', content: 'sys')], traceId: 'trace-42')
        .toList();

    final messages = logger.calls.map((c) => c.$2).toList();
    expect(messages.any((m) => m.contains('Agent') && m.contains('开始')), isTrue);
    expect(messages.any((m) => m.contains('Agent') && m.contains('完成')), isTrue);
    // 所有调用都带 traceId
    expect(logger.calls.every((c) => c.$3 == 'trace-42'), isTrue);
  });

  test('AgentLoop 默认 NullLoggerSink 不抛异常(回归)', () async {
    final llm = _FakeLlm([const [LlmStreamChunk(textDelta: 'ok')]]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario());
    final events =
        await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.any((e) => e is AgentDoneEvent), isTrue);
  });

  test('未传 system 消息时自动注入 scenario.buildSystemPrompt', () async {
    // 调用方未前置 system → AgentLoop 应自动调 getMemories + buildSystemPrompt 并 insert(0)。
    // 验证：_FakeLlm 收到的 messages.first 是 role=system,content=sys。
    List<ChatMessage>? captured;
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '回答')],
    ]);
    final scenario = _RecordingScenario();
    final loop = AgentLoop(llm: _SpyLlm(llm, (m) => captured = m), scenario: scenario);
    await loop.run([const ChatMessage(role: 'user', content: '嗨')]).toList();

    expect(scenario.memoriesQueried, isTrue, reason: '应先调 getMemories 填充记忆缓存');
    expect(scenario.promptBuilt, isTrue, reason: '应调 buildSystemPrompt');
    expect(captured, isNotNull);
    expect(captured!.first.role, 'system');
    expect(captured!.first.content, 'sys-prompt');
    expect(captured!.last.role, 'user');
  });

  // ============ LLM 调用失败重试机制测试 ============

  test('LLM 首次失败后重试成功：含 RetryEvent 且最终 Done', () async {
    final llm = _FailingThenOkLlm(
      // 第 1 次抛 SocketException（模拟远程临时中断），第 2 次正常返回文本。
      failTimes: 1,
      okChunks: const [LlmStreamChunk(textDelta: '恢复成功')],
    );
    final loop = AgentLoop(
      llm: llm,
      scenario: _FakeScenario(),
      retry: const RetryConfig(maxAttempts: 3, baseDelayMs: 0, jitterMs: 0),
      random: _FixedRandom(),
    );
    final events = await loop
        .run([const ChatMessage(role: 'system', content: 'sys')])
        .toList();

    final retries = events.whereType<RetryEvent>().toList();
    expect(retries, hasLength(1), reason: '应只触发 1 次重试');
    expect(retries.single.attempt, 1);
    // 重试后 LLM 重新生成，最终文本应等于第 2 次的完整内容
    expect(events.whereType<TextDeltaEvent>().single.delta, '恢复成功');
    expect(events.last, isA<AgentDoneEvent>());
    expect((events.last as AgentDoneEvent).finalText, '恢复成功');
  });

  test('网络中断与 HTTP 5xx 都会触发重试（所有错误都重试）', () async {
    // 连续抛不同类型的异常，验证都被重试，最终成功。
    final llm = _FailingThenOkLlm(
      failTimes: 3,
      okChunks: const [LlmStreamChunk(textDelta: 'ok')],
      errors: [
        const SocketException('connection reset'),
        LlmHttpException(503, 'upstream down'),
        TimeoutException('LLM 504'),
      ],
    );
    final loop = AgentLoop(
      llm: llm,
      scenario: _FakeScenario(),
      retry: const RetryConfig(maxAttempts: 5, baseDelayMs: 0, jitterMs: 0),
      random: _FixedRandom(),
    );
    final events = await loop
        .run([const ChatMessage(role: 'system', content: 'sys')])
        .toList();
    final retries = events.whereType<RetryEvent>().toList();
    expect(retries, hasLength(3));
    expect(retries.map((e) => e.attempt), [1, 2, 3]);
    expect(events.last, isA<AgentDoneEvent>());
  });

  test('重试耗尽后以 AgentErrorEvent 结束，且不破坏对话', () async {
    // 永远抛异常，maxAttempts=2 → 尝试 2 次后放弃。
    final llm = _AlwaysFailLlm(const SocketException('down'));
    final loop = AgentLoop(
      llm: llm,
      scenario: _FakeScenario(),
      retry: const RetryConfig(maxAttempts: 2, baseDelayMs: 0, jitterMs: 0),
      random: _FixedRandom(),
    );
    final events = await loop
        .run([const ChatMessage(role: 'system', content: 'sys')])
        .toList();
    final retries = events.whereType<RetryEvent>().toList();
    expect(retries, hasLength(1), reason: 'maxAttempts=2：仅第 1 次失败后重试 1 次');
    expect(events.last, isA<AgentErrorEvent>());
    expect((events.last as AgentErrorEvent).message, contains('down'));
  });

  test('重试前清空已部分下发的流式文本（避免新旧拼接）', () async {
    // 第 1 次调用：吐半个字「半」后流中断抛错；第 2 次成功返回「完整回答」。
    // 已发出的 TextDeltaEvent 无法撤回，但 AgentLoop 会丢弃缓冲并 yield RetryEvent，
    // 交由 UI 层（chat_session_provider）在收到 RetryEvent 时清空 streamingText。
    // 此处验证：最终 finalText 是完整重生成的结果（而非「半」+「完整回答」拼接）。
    final llm = _PartialThenOkLlm();
    final loop = AgentLoop(
      llm: llm,
      scenario: _FakeScenario(),
      retry: const RetryConfig(maxAttempts: 3, baseDelayMs: 0, jitterMs: 0),
      random: _FixedRandom(),
    );
    final events = await loop
        .run([const ChatMessage(role: 'system', content: 'sys')])
        .toList();
    expect(events.whereType<RetryEvent>(), hasLength(1));
    // finalText 不包含旧的中途文本——重试丢弃了缓冲
    expect((events.last as AgentDoneEvent).finalText, '完整回答',
        reason: '重试应丢弃缓冲里的「半」字，finalText 只含重新生成的完整回答');
  });

  test('RetryConfig.maxAttempts=1 表示不重试：单次失败即 AgentErrorEvent', () async {
    final llm = _AlwaysFailLlm(const SocketException('down'));
    final loop = AgentLoop(
      llm: llm,
      scenario: _FakeScenario(),
      retry: RetryConfig.none,
      random: _FixedRandom(),
    );
    final events = await loop
        .run([const ChatMessage(role: 'system', content: 'sys')])
        .toList();
    expect(events.whereType<RetryEvent>(), isEmpty);
    expect(events.last, isA<AgentErrorEvent>());
  });

  test('成功路径不产生 RetryEvent（回归）', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: 'done')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: _FakeScenario());
    final events = await loop
        .run([const ChatMessage(role: 'system', content: 'sys')])
        .toList();
    expect(events.whereType<RetryEvent>(), isEmpty);
    expect(events.last, isA<AgentDoneEvent>());
  });
}

/// 记录是否被调用的 scenario。
class _RecordingScenario implements AgentScenario {
  bool memoriesQueried = false;
  bool promptBuilt = false;
  @override String get id => 'rec';
  @override String get displayName => 'Rec';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;
  @override String buildSystemPrompt(AgentScenarioContext ctx) {
    promptBuilt = true;
    return 'sys-prompt';
  }
  @override List<ChatMessage> composeApiMessages(List<ChatMessage> base, AgentScenarioContext ctx) => base;
  @override Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId, AgentScenarioContext? context}) async => '{}';
  @override Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;
  @override Future<List<String>> getMemories() async {
    memoriesQueried = true;
    return [];
  }
  @override Future<MemoryPatchResult> patchMemory(int? index, String newText) async => MemoryPatchResult(true, '');
  @override Future<void> cleanup() async {}
}

/// 包装 _FakeLlm，捕获喂给 LLM 的 messages。
class _SpyLlm extends LlmProvider {
  _SpyLlm(this._inner, this.onMessages)
      : super(config: LlmConfig(
            name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final LlmProvider _inner;
  final void Function(List<ChatMessage>) onMessages;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) {
    onMessages(messages);
    return _inner.chatStreamWithTools(messages: messages, tools: tools);
  }
}

/// 记录所有 log 调用的 fake LoggerSink。
class _RecordingLogger implements LoggerSink {
  final List<(LoggerLevel, String, String?)> calls = [];
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general',
      String? traceId,
      String? stackTrace,
      List<String> tags = const []}) {
    calls.add((level, message, traceId));
  }
}

/// 前 [failTimes] 次调用抛异常，后续返回 [okChunks]。
/// [errors] 提供每次抛的具体异常（默认 SocketException）。
class _FailingThenOkLlm extends LlmProvider {
  _FailingThenOkLlm({
    required this.failTimes,
    required this.okChunks,
    this.errors,
  }) : super(config: LlmConfig(
            name: '',
            apiUrl: '',
            apiKey: '',
            model: '',
            createdAt: DateTime(2026)));
  final int failTimes;
  final List<LlmStreamChunk> okChunks;
  final List<Object>? errors;
  int _callCount = 0;

  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    final idx = _callCount++;
    if (idx < failTimes) {
      final err = errors != null && idx < errors!.length
          ? errors![idx]
          : const SocketException('down');
      throw err;
    }
    for (final c in okChunks) {
      yield c;
    }
  }
}

/// 每次调用都抛 [error]。
class _AlwaysFailLlm extends LlmProvider {
  _AlwaysFailLlm(this.error) : super(config: LlmConfig(
            name: '',
            apiUrl: '',
            apiKey: '',
            model: '',
            createdAt: DateTime(2026)));
  final Object error;

  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    throw error;
  }
}

/// 第 1 次调用：吐「半」后流中断（用 sync* 中途 throw 模拟）；
/// 第 2 次调用：正常吐「完整回答」。验证重试时已部分累积的文本被丢弃。
class _PartialThenOkLlm extends LlmProvider {
  _PartialThenOkLlm() : super(config: LlmConfig(
            name: '',
            apiUrl: '',
            apiKey: '',
            model: '',
            createdAt: DateTime(2026)));
  int _callCount = 0;

  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    _callCount++;
    if (_callCount == 1) {
      yield const LlmStreamChunk(textDelta: '半');
      throw const SocketException('drop after first chunk');
    }
    yield const LlmStreamChunk(textDelta: '完整回答');
  }
}

/// 确定性 Random：nextInt 恒返回 0，nextDouble 恒返回 0。
/// 用于让退避抖动可预测，便于断言测试时即时完成。
class _FixedRandom implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0.0;
  @override
  int nextInt(int max) => 0;
}
