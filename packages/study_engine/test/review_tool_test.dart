import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<StudyDatabase> openDb() => StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );

  test('ReviewRepository.save 落库并返回 id,findById 还原 items', () async {
    final sdb = await openDb();
    final repo = ReviewRepository(sdb);
    // FK 开启：review.chat_session_id 引用 chat_session(id)，先建对应会话行。
    final now = DateTime.now().millisecondsSinceEpoch;
    await sdb.db.insert('chat_session', {'scenario_id': 'study', 'title': 's1', 'created_at': now, 'updated_at': now});
    final id = await repo.save(
      chatSessionId: 1,
      summary: '批改2题,对1错1',
      items: [
        ReviewItem(seq: 1, question: '1+1=?', userAnswer: '2', verdict: 'correct', analysis: '对', topicIds: const []),
        ReviewItem(seq: 2, question: '2+2=?', userAnswer: '5', verdict: 'wrong', analysis: '应为4', topicIds: const [7]),
      ],
    );
    expect(id, greaterThan(0));

    final got = await repo.findById(id);
    expect(got, isNotNull);
    expect(got!.summary, '批改2题,对1错1');
    expect(got.items.length, 2);
    expect(got.items[1].verdict, 'wrong');
    expect(got.items[1].topicIds, [7]);
    await sdb.close();
  });

  test('findBySession 按 created_at 倒序', () async {
    final sdb = await openDb();
    final repo = ReviewRepository(sdb);
    // FK 开启：先建 chat_session id=5 的行。
    final now = DateTime.now().millisecondsSinceEpoch;
    await sdb.db.insert('chat_session', {'id': 5, 'scenario_id': 'study', 'title': 's5', 'created_at': now, 'updated_at': now});
    final a = await repo.save(chatSessionId: 5, summary: 'a', items: const [ReviewItem(seq: 1, question: 'q', verdict: 'correct', analysis: 'x', topicIds: [])]);
    final b = await repo.save(chatSessionId: 5, summary: 'b', items: const [ReviewItem(seq: 1, question: 'q', verdict: 'wrong', analysis: 'x', topicIds: [])]);
    final list = await repo.findBySession(5);
    expect(list.length, 2);
    expect(list.first.id, b); // 倒序:b 后建在前
    expect(list.last.id, a);
    await sdb.close();
  });

  test('chatSessionId 可空:不传也能存', () async {
    final sdb = await openDb();
    final repo = ReviewRepository(sdb);
    final id = await repo.save(
      summary: '无会话批改',
      items: const [ReviewItem(seq: 1, question: 'q', verdict: 'partial', analysis: 'x', topicIds: [])],
    );
    final got = await repo.findById(id);
    expect(got!.chatSessionId, isNull);
    await sdb.close();
  });

  test('AgentLoop mock: save_review 落库 review 表', () async {
    final sdb = await openDb();
    final scenario = StudyScenario(
      categories: CategoryRepository(sdb),
      topics: TopicRepository(sdb),
      edges: TopicEdgeRepository(sdb),
      memories: AgentMemoryRepository(sdb),
      mastery: MasteryRepository(sdb),
      reviews: ReviewRepository(sdb),
    );

    // FK 开启：先造 chat_session id=42 行，否则 save_review 落库 FOREIGN KEY 失败。
    final now = DateTime.now().millisecondsSinceEpoch;
    await sdb.db.insert('chat_session', {'id': 42, 'scenario_id': 'study', 'title': 's42', 'created_at': now, 'updated_at': now});

    final llm = _ScriptedLlm([
      const [
        LlmStreamChunk(textDelta: '', toolCalls: [
          ToolCall(
            id: 'c1',
            name: 'save_review',
            arguments: '{"summary":"批改1题,错","items":[{"seq":1,"question":"1+1","verdict":"wrong","analysis":"应为2","topic_ids":[]}]}',
          ),
        ])
      ],
      const [LlmStreamChunk(textDelta: '已批改')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run(
      [const ChatMessage(role: 'system', content: 'sys')],
      context: const AgentScenarioContext(extra: {'chat_session_id': 42}),
    ).toList();
    expect(events.any((e) => e is ToolCallEndEvent), isTrue);

    final list = await ReviewRepository(sdb).findBySession(42);
    expect(list.length, 1);
    expect(list.first.summary, '批改1题,错');
    expect(list.first.items.first.verdict, 'wrong');
    await sdb.close();
  });
}

class _ScriptedLlm extends LlmProvider {
  _ScriptedLlm(this.script) : super(config: LlmConfig(name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({required List<ChatMessage> messages, required List<Map<String, dynamic>> tools}) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}
