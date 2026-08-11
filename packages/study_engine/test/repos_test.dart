import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

void main() {
  late StudyDatabase sdb;
  setUp(() async => sdb = await _fresh());
  tearDown(() async => await sdb.close());

  test('LlmConfigRepository.getDefault 视觉优先', () async {
    final repo = LlmConfigRepository(sdb);
    await repo.insert(LlmConfig(name: 'text', apiUrl: 'u', apiKey: 'k', model: 'm', isDefault: true, createdAt: DateTime.now()));
    await repo.insert(LlmConfig(name: 'vision', apiUrl: 'u', apiKey: 'k', model: 'mv', supportsVision: true, isDefault: true, createdAt: DateTime.now()));
    final d = await repo.getDefault(vision: true);
    expect(d?.supportsVision, isTrue);
    final plain = await repo.getDefault();
    expect(plain, isNotNull);
  });

  test('LlmConfigRepository.update 按主键更新业务字段', () async {
    final repo = LlmConfigRepository(sdb);
    final id = await repo.insert(LlmConfig(
      name: '原配置',
      apiUrl: 'http://old',
      apiKey: 'old-key',
      model: 'old-model',
      isDefault: true,
      createdAt: DateTime(2026, 1, 1),
    ));
    final updated = LlmConfig(
      id: id,
      name: '新配置',
      apiUrl: 'https://api.example.com/v1',
      apiKey: 'secret-token',
      model: 'gpt-4o',
      supportsVision: true,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime(2026, 1, 1),
    );
    await repo.update(updated);
    final all = await repo.all();
    expect(all, hasLength(1));
    expect(all.first.id, id);
    expect(all.first.name, '新配置');
    expect(all.first.apiUrl, 'https://api.example.com/v1');
    expect(all.first.apiKey, 'secret-token');
    expect(all.first.model, 'gpt-4o');
    expect(all.first.supportsVision, isTrue);
    expect(all.first.isDefault, isTrue);
    // created_at 不应被 update 改动
    expect(all.first.createdAt, DateTime(2026, 1, 1));
  });

  test('AgentMemoryRepository 增删改查', () async {
    final repo = AgentMemoryRepository(sdb);
    final id = await repo.add('study', '经验1');
    expect(await repo.queryByScenario('study'), hasLength(1));
    await repo.update(id, '经验1改');
    expect((await repo.queryByScenario('study')).first.content, '经验1改');
    await repo.delete(id);
    expect(await repo.queryByScenario('study'), isEmpty);
  });

  test('ChatRepository 建会话+存消息', () async {
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study', '测试会话');
    await repo.addMessage(sid, const ChatMessage(role: 'user', content: '你好'));
    final rows = await sdb.db.query('chat_message', where: 'session_id = ?', whereArgs: [sid]);
    expect(rows, hasLength(1));
  });

  test('CategoryRepository.ensurePath 多级创建且幂等', () async {
    final repo = CategoryRepository(sdb);
    final id1 = await repo.ensurePath(['数学', '高等数学', '极限']);
    final id2 = await repo.ensurePath(['数学', '高等数学', '极限']);
    expect(id1, id2);

    final found = await repo.findByPath(['数学', '高等数学', '极限']);
    expect(found?.id, id1);

    final missing = await repo.findByPath(['数学', '不存在的分支']);
    expect(missing, isNull);
  });

  test('CategoryRepository.findChildren 与 pathOf', () async {
    final repo = CategoryRepository(sdb);
    await repo.ensurePath(['数学', '高等数学', '极限']);
    final topLevel = await repo.findChildren(null);
    expect(topLevel.map((c) => c.name), contains('数学'));

    final math = await repo.findByPath(['数学']);
    final children = await repo.findChildren(math!.id!);
    expect(children.map((c) => c.name), contains('高等数学'));

    final limit = await repo.findByPath(['数学', '高等数学', '极限']);
    final path = await repo.pathOf(limit!.id!);
    expect(path, ['数学', '高等数学', '极限']);
  });

  test('TopicRepository 新结构增查与查重', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学', '代数']);
    final now = DateTime.now();
    final id = await topics.insert(Topic(
      categoryId: catId,
      question: '什么是韦达定理？',
      title: '韦达定理',
      summary: '一元二次方程根与系数的关系…',
      createdAt: now,
      updatedAt: now,
    ));
    final got = await topics.findById(id);
    expect(got?.title, '韦达定理');
    expect(await topics.findByTitle('韦达定理'), isNotNull);
    expect(await topics.findByCategory(catId), hasLength(1));
  });

  test('TopicRepository.search 跨字段命中与分页', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    await topics.insert(Topic(categoryId: catId, question: '如何求0/0型极限？', title: '洛必达法则', summary: '对分子分母求导', createdAt: now, updatedAt: now));
    await topics.insert(Topic(categoryId: catId, question: '什么是ε-δ定义？', title: '极限定义', summary: '极限的严格定义', createdAt: now, updatedAt: now));

    // 命中 title
    var r = await topics.search('洛必达');
    expect(r.total, 1);
    expect(r.items.first.title, '洛必达法则');
    // 命中 question
    r = await topics.search('0/0');
    expect(r.total, 1);
    // 命中 summary
    r = await topics.search('严格定义');
    expect(r.total, 1);
    // LIKE 元字符被转义：搜 '%' 不应匹配全表，搜 '_' 不应匹配任意单字符
    r = await topics.search('%');
    expect(r.total, 0);
    r = await topics.search('_');
    expect(r.total, 0);
  });

  test('TopicRepository.updateSummary 刷新 updated_at', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final id = await topics.insert(Topic(categoryId: catId, question: 'q', title: 't', summary: '旧答案', createdAt: now, updatedAt: now));
    await topics.updateSummary(id, '新答案');
    final got = await topics.findById(id);
    expect(got?.summary, '新答案');
    expect(got!.updatedAt.isAfter(now) || got.updatedAt == now, isTrue);
  });

  test('TopicEdgeRepository 建边与双向查询', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final edges = TopicEdgeRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: '洛必达法则', summary: 's1', createdAt: now, updatedAt: now));
    final b = await topics.insert(Topic(categoryId: catId, question: 'q2', title: '导数', summary: 's2', createdAt: now, updatedAt: now));

    await edges.insert(a, b, 'prerequisite');
    // UNIQUE 冲突忽略：重复建边不报错
    await edges.insert(a, b, 'prerequisite');

    final fromA = await edges.findByTopic(a);
    expect(fromA, hasLength(1));
    expect(fromA.first.type, 'prerequisite');
    expect(fromA.first.otherTitle, '导数');

    // 双向：从 b 也能查到这条边
    final fromB = await edges.findByTopic(b);
    expect(fromB, hasLength(1));
    expect(fromB.first.otherTitle, '洛必达法则');
  });

  test('FK 启用：删 topic 连带删边（ON DELETE CASCADE）', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final edges = TopicEdgeRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: 'A', summary: 's1', createdAt: now, updatedAt: now));
    final b = await topics.insert(Topic(categoryId: catId, question: 'q2', title: 'B', summary: 's2', createdAt: now, updatedAt: now));
    await edges.insert(a, b, 'prerequisite');

    // 裸 SQL 删 topic（删除能力不在本次 Repository 范围，测试直连验证 FK 生效）
    await sdb.db.delete('topic', where: 'id = ?', whereArgs: [a]);
    final edgesAfter = await edges.findByTopic(b);
    expect(edgesAfter, isEmpty, reason: 'FK 未启用，删 topic 后边残留');
  });

  test('MasteryRepository 日志驱动当前状态', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final mastery = MasteryRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final tid = await topics.insert(Topic(categoryId: catId, question: 'q', title: 't', summary: 's', createdAt: now, updatedAt: now));

    expect(await mastery.currentStatus(tid), MasteryStatus.unknown);
    await mastery.log(tid, MasteryStatus.learning);
    await mastery.log(tid, MasteryStatus.mastered);
    expect(await mastery.currentStatus(tid), MasteryStatus.mastered);
    expect(await mastery.timeline(tid), hasLength(2));
  });
}
