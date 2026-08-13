import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 记忆注入（composeApiMessages）测试：
/// - 纯文本 user 消息：记忆以 apiContent 旁车注入，content 保持干净；
/// - 含图 user 消息：记忆作为 TextPart 追加，图片保留；
/// - 无记忆时：原样返回（不注入）。
void main() {
  setUpAll(sqfliteFfiInit);

  Future<StudyPlanScenario> newScenario(StudyDatabase sdb) => Future.value(
        StudyPlanScenario(
          categories: CategoryRepository(sdb),
          topics: TopicRepository(sdb),
          edges: TopicEdgeRepository(sdb),
          memories: AgentMemoryRepository(sdb),
          mastery: MasteryRepository(sdb),
          reviews: ReviewRepository(sdb),
          schedules: TopicScheduleRepository(sdb),
          plans: PlanRepository(sdb),
          dayTasks: PlanDayTaskRepository(sdb),
        ),
      );

  test('有记忆时：纯文本 user 消息的 apiContent 注入 memory-context，content 干净', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final memories = AgentMemoryRepository(sdb);
    await memories.add('study_plan', '用户喜欢先看结论再看推导');
    await memories.add('study_plan', '批改时多用提问引导');

    final s = await newScenario(sdb);
    await s.getMemories(); // 填充 _memCache（AgentLoop 在 run 早期会调）

    final base = <ChatMessage>[
      const ChatMessage(role: 'system', content: 'sys'),
      const ChatMessage(role: 'user', content: '这道题怎么做？'),
    ];
    final out = s.composeApiMessages(base, const AgentScenarioContext());

    // content 保持干净
    expect(out.last.content, '这道题怎么做？');
    // apiContent 含记忆块与原文
    expect(out.last.apiContent, contains('这道题怎么做？'));
    expect(out.last.apiContent, contains('<memory-context>'));
    expect(out.last.apiContent, contains('NOT new user input'));
    expect(out.last.apiContent, contains('用户喜欢先看结论再看推导'));
    expect(out.last.apiContent, contains('[2] 批改时多用提问引导'));
    await sdb.close();
  });

  test('含图 user 消息：记忆作为 TextPart 追加，图片 part 保留', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final memories = AgentMemoryRepository(sdb);
    await memories.add('study_plan', '拍题后先做主体裁剪');

    final s = await newScenario(sdb);
    await s.getMemories();

    final base = <ChatMessage>[
      const ChatMessage(role: 'system', content: 'sys'),
      ChatMessage(role: 'user', content: [
        const TextPart('（拍题无文本）'),
        const ImageUrlPart('data:image/png;base64,AAAA', detail: 'high'),
      ]),
    ];
    final out = s.composeApiMessages(base, const AgentScenarioContext());

    final parts = out.last.content as List<ContentPart>;
    // 图片保留 + 追加记忆 TextPart
    expect(parts.whereType<ImageUrlPart>(), hasLength(1));
    expect(parts.whereType<TextPart>(), hasLength(2));
    final lastText = (parts.whereType<TextPart>().toList().last).text;
    expect(lastText, contains('<memory-context>'));
    expect(lastText, contains('拍题后先做主体裁剪'));
    // 含图路径不设 apiContent（纯文本会覆盖图片）
    expect(out.last.apiContent, isNull);
    await sdb.close();
  });

  test('无记忆时：原样返回，不注入', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final s = await newScenario(sdb);
    await s.getMemories(); // 空记忆

    final base = <ChatMessage>[
      const ChatMessage(role: 'system', content: 'sys'),
      const ChatMessage(role: 'user', content: '你好'),
    ];
    final out = s.composeApiMessages(base, const AgentScenarioContext());
    expect(out, hasLength(2));
    expect(out.last.content, '你好');
    expect(out.last.apiContent, isNull);
    await sdb.close();
  });

  test('记忆块在 AgentLoop 中随当前 user 消息发给 LLM（端到端）', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final memories = AgentMemoryRepository(sdb);
    await memories.add('study_plan', '测试记忆内容');

    final s = await newScenario(sdb);
    List<ChatMessage>? captured;
    // 用 Spy LLM 捕获发给模型的 messages
    final spy = _SpyLlm(LlmProvider(
      config: LlmConfig(
          name: '',
          apiUrl: '',
          apiKey: '',
          model: '',
          createdAt: DateTime(2026)),
    ), (m) => captured = m);

    final loop = AgentLoop(llm: spy, scenario: s);
    await loop
        .run([const ChatMessage(role: 'user', content: '这是用户消息')])
        .toList();

    expect(captured, isNotNull);
    final userMsg = captured!.lastWhere((m) => m.role == 'user');
    // 发给 LLM 的 JSON 应含注入（toJson(forApi:true) 走 apiContent）
    final json = userMsg.toJson(forApi: true);
    expect(json['content'] as String, contains('测试记忆内容'));
    expect(json['content'] as String, contains('这是用户消息'));
    await sdb.close();
  });
}

/// 捕获喂给 LLM 的 messages 的 Spy。
class _SpyLlm extends LlmProvider {
  _SpyLlm(LlmProvider inner, this.onMessages)
      : _inner = inner,
        super(config: inner.config);
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
