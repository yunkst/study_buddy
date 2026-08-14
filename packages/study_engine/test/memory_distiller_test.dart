import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 假 LLM：可预设要返回的整段文本，或抛异常。
/// 继承 LlmProvider 并覆写 chatStreamWithTools，绕开真实 HTTP。
/// config 用一个合法的 LlmConfig 占位（字段非空即可，不会真正发请求）。
LlmConfig _fakeConfig() => LlmConfig(
      name: 'fake',
      apiUrl: 'http://localhost',
      apiKey: 'k',
      model: 'fake-model',
      createdAt: DateTime(2026, 1, 1),
    );

class _FakeLlm extends LlmProvider {
  _FakeLlm(String output, {bool throwOnCall = false})
      : _output = output,
        _throwOnCall = throwOnCall,
        super(config: _fakeConfig());
  final String _output;
  final bool _throwOnCall;

  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    if (_throwOnCall) throw Exception('boom');
    yield LlmStreamChunk(textDelta: _output);
    yield const LlmStreamChunk(textDelta: '', toolCalls: []);
  }
}

ChatMessage _user(String t) => ChatMessage(role: 'user', content: t);
ChatMessage _assistant(String t) => ChatMessage(role: 'assistant', content: t);

void main() {
  setUpAll(sqfliteFfiInit);

  test('用户消息 < 2 不调 LLM，直接跳过', () async {
    final sdb =
        await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = AgentMemoryRepository(sdb);
    // 用一个调用即抛异常的 Llm 断言「未调用」：若被调用会失败。
    final d = MemoryDistiller(llm: _FakeLlm('', throwOnCall: true), memories: repo);
    final r = await d.distill(messages: [_user('hi')], scenarioId: 'study_plan');
    expect(r.note, contains('过短'));
    expect(r.added, 0);
    await sdb.close();
  });

  test('正常提炼 → 写入仓库', () async {
    final sdb =
        await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = AgentMemoryRepository(sdb);
    final d = MemoryDistiller(
      llm: _FakeLlm('- 用户偏好简短回答\n- 用户常错极限计算'),
      memories: repo,
    );
    final r = await d.distill(
      messages: [_user('帮我讲下极限'), _assistant('...'), _user('再短点')],
      scenarioId: 'study_plan',
    );
    expect(r.added, 2);
    expect((await repo.queryByScenario('study_plan')).map((m) => m.content).toList(),
        ['用户偏好简短回答', '用户常错极限计算']);
    await sdb.close();
  });

  test('输出 NOTHING → 不写入', () async {
    final sdb =
        await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = AgentMemoryRepository(sdb);
    final d = MemoryDistiller(llm: _FakeLlm('NOTHING'), memories: repo);
    final r = await d.distill(
      messages: [_user('a'), _assistant('b'), _user('c')],
      scenarioId: 'study_plan',
    );
    expect(r.added, 0);
    expect(r.note, contains('无候选'));
    expect(await repo.queryByScenario('study_plan'), isEmpty);
    await sdb.close();
  });

  test('候选与现有记忆重复 → skipped', () async {
    final sdb =
        await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = AgentMemoryRepository(sdb);
    await repo.add('study_plan', '用户偏好简短回答');
    final d = MemoryDistiller(
      llm: _FakeLlm('- 用户偏好简短回答\n- 用户常错极限计算'),
      memories: repo,
    );
    final r = await d.distill(
      messages: [_user('a'), _assistant('b'), _user('c')],
      scenarioId: 'study_plan',
    );
    expect(r.added, 1);
    expect(r.skipped, 1);
    await sdb.close();
  });

  test('候选超容量 → skipped，其余照写', () async {
    final sdb =
        await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = AgentMemoryRepository(sdb);
    // 先占满接近上限
    await repo.add('study_plan', List.filled(1900, 'x').join());
    final d = MemoryDistiller(
      llm: _FakeLlm('- ' + List.filled(300, 'y').join() + '\n- 有效偏好'),
      memories: repo,
    );
    final r = await d.distill(
      messages: [_user('a'), _assistant('b'), _user('c')],
      scenarioId: 'study_plan',
    );
    expect(r.added, 1);
    expect(r.skipped, 1);
    await sdb.close();
  });

  test('LLM 异常 → 返回空结果不抛出', () async {
    final sdb =
        await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = AgentMemoryRepository(sdb);
    final d = MemoryDistiller(llm: _FakeLlm('', throwOnCall: true), memories: repo);
    final r = await d.distill(
      messages: [_user('a'), _assistant('b'), _user('c')],
      scenarioId: 'study_plan',
    );
    expect(r.added, 0);
    expect(r.note, contains('失败'));
    await sdb.close();
  });
}