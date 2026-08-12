import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  StudyScenario newScenario(StudyDatabase sdb) => StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
        schedules: TopicScheduleRepository(sdb),
      );

  test('场景1 save_topic 新建（分类自动建）', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = newScenario(sdb);
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);

    final result = await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限',
      'title': '洛必达法则',
      'question': '如何求0/0型极限?',
      'summary': '对分子分母分别求导后取极限',
    });
    expect(result, contains('已保存'));

    // 分类树三层建好
    final limit = await cats.findByPath(['数学', '高等数学', '极限']);
    expect(limit, isNotNull);
    // topic 落库
    final got = await topics.findByTitle('洛必达法则');
    expect(got, isNotNull);
    expect(got!.categoryId, limit!.id);
    await sdb.close();
  });

  test('场景2 save_topic 重复 title 被拒', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = newScenario(sdb);
    final topics = TopicRepository(sdb);

    await scenario.executeTool('save_topic', {
      'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
    });
    final result2 = await scenario.executeTool('save_topic', {
      'path': '物理', 'title': '极限', 'question': 'q2', 'summary': 's2',
    });
    expect(result2, contains('已存在'));
    expect(result2, contains('update_topic'));
    // 库中仍只有 1 条
    expect(await topics.findByTitle('极限'), isNotNull);
    final all = await topics.search('极限');
    expect(all.total, 1);
    await sdb.close();
  });

  test('场景3 先查后写完整流程', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = newScenario(sdb);

    await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限', 'title': '极限的ε-δ定义', 'question': 'q', 'summary': '旧答案',
    });
    // search 命中
    final searchResult = await scenario.executeTool('search_topics', {'keyword': '极限'});
    expect(searchResult, contains('极限的ε-δ定义'));
    // get 看详情
    final topics = TopicRepository(sdb);
    final t = await topics.findByTitle('极限的ε-δ定义');
    final detail = await scenario.executeTool('get_topic', {'id': t!.id});
    expect(detail, contains('旧答案'));
    // update 答案
    await scenario.executeTool('update_topic', {'id': t.id, 'summary': '新答案'});
    final got = await topics.findById(t.id!);
    expect(got?.summary, '新答案');
    // 不产生重复
    final all = await topics.search('极限');
    expect(all.total, 1);
    await sdb.close();
  });

  test('场景4 分层下钻 list_topics', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = newScenario(sdb);

    await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限', 'title': '洛必达法则', 'question': 'q', 'summary': 's',
    });
    // 顶级
    final top = await scenario.executeTool('list_topics', {});
    expect(top, contains('数学'));
    expect(top, contains('has_children'));
    // 下钻数学
    final math = await scenario.executeTool('list_topics', {'path': '数学'});
    expect(math, contains('高等数学'));
    // 下钻高等数学
    final adv = await scenario.executeTool('list_topics', {'path': '数学/高等数学'});
    expect(adv, contains('极限'));
    // 下钻极限 — 看到 topic
    final limit = await scenario.executeTool('list_topics', {'path': '数学/高等数学/极限'});
    expect(limit, contains('洛必达法则'));
    await sdb.close();
  });

  test('场景5 建边 link_topics + get_topic 含边', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = newScenario(sdb);
    final topics = TopicRepository(sdb);

    await scenario.executeTool('save_topic', {'path': '数学', 'title': '洛必达法则', 'question': 'q', 'summary': 's'});
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '导数', 'question': 'q', 'summary': 's'});
    final a = await topics.findByTitle('洛必达法则');
    final b = await topics.findByTitle('导数');

    final linkResult = await scenario.executeTool('link_topics', {
      'from': a!.id, 'to': b!.id, 'type': 'prerequisite',
    });
    expect(linkResult, contains('已建立'));

    final detail = await scenario.executeTool('get_topic', {'id': a.id});
    expect(detail, contains('prerequisite'));
    expect(detail, contains('导数'));
    await sdb.close();
  });

  test('场景6 AgentLoop 端到端 mock save_topic', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = newScenario(sdb);
    final topics = TopicRepository(sdb);

    final llm = _ScriptedLlm([
      const [
        LlmStreamChunk(textDelta: '', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"path":"物理/力学","title":"牛顿第二定律","question":"F=ma?","summary":"力等于质量乘加速度"}'),
        ])
      ],
      const [LlmStreamChunk(textDelta: '已保存')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.any((e) => e is ToolCallEndEvent), isTrue);

    final got = await topics.findByTitle('牛顿第二定律');
    expect(got, isNotNull);
    await sdb.close();
  });

  group('onTopicTouched 回调', () {
    test('save_topic 新建成功后触发回调(新 topicId)', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final touched = <int>[];
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
        schedules: TopicScheduleRepository(sdb),
        onTopicTouched: (id) async => touched.add(id),
      );

      await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
      });
      expect(touched, hasLength(1));
      final topics = TopicRepository(sdb);
      final t = await topics.findByTitle('极限');
      expect(touched.first, t!.id);
      await sdb.close();
    });

    test('save_topic 命中已存在也触发回调(existing.id)', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final touched = <int>[];
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
        schedules: TopicScheduleRepository(sdb),
        onTopicTouched: (id) async => touched.add(id),
      );
      // 第一次新建
      await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
      });
      touched.clear();
      // 第二次重复（命中已存在）
      await scenario.executeTool('save_topic', {
        'path': '物理', 'title': '极限', 'question': 'q2', 'summary': 's2',
      });
      expect(touched, hasLength(1));
      await sdb.close();
    });

    test('update_topic 成功后触发回调', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final touched = <int>[];
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
        schedules: TopicScheduleRepository(sdb),
        onTopicTouched: (id) async => touched.add(id),
      );
      await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': '旧',
      });
      final t = await TopicRepository(sdb).findByTitle('极限');
      touched.clear();
      await scenario.executeTool('update_topic', {'id': t!.id, 'summary': '新答案'});
      expect(touched, [t.id]);
      await sdb.close();
    });

    test('未设置回调时 no-op，不影响现有行为', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
        schedules: TopicScheduleRepository(sdb),
        // 不传 onTopicTouched
      );
      final result = await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
      });
      expect(result, contains('已保存'));
      await sdb.close();
    });
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
    String? traceId,
  }) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}
