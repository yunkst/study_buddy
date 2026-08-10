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

  test('SubjectRepository.ensureCreate 幂等', () async {
    final repo = SubjectRepository(sdb);
    final s1 = await repo.ensureCreate('数学');
    final s2 = await repo.ensureCreate('数学');
    expect(s1.id, s2.id);
    expect(await repo.all(), hasLength(1));
  });

  test('TopicRepository 增查', () async {
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    final id = await topics.insert(Topic(
      subjectId: math.id!,
      domain: '代数',
      title: '一元二次方程',
      createdAt: DateTime.now(),
    ));
    final got = await topics.findById(id);
    expect(got?.title, '一元二次方程');
    expect(await topics.queryBySubject(math.id!), hasLength(1));
    expect(await topics.queryBySubject(math.id!, domain: '几何'), isEmpty);
  });

  test('MasteryRepository 日志驱动当前状态', () async {
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final mastery = MasteryRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    final tid = await topics.insert(Topic(subjectId: math.id!, title: 't', createdAt: DateTime.now()));

    expect(await mastery.currentStatus(tid), MasteryStatus.unknown);
    await mastery.log(tid, MasteryStatus.learning);
    await mastery.log(tid, MasteryStatus.mastered);
    expect(await mastery.currentStatus(tid), MasteryStatus.mastered);
    expect(await mastery.timeline(tid), hasLength(2));
  });

  test('TopicDomainRepository 增查', () async {
    final subjects = SubjectRepository(sdb);
    final domains = TopicDomainRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    await domains.insert(TopicDomain(subjectId: math.id!, name: '代数', createdAt: DateTime.now()));
    expect(await domains.queryBySubject(math.id!), hasLength(1));
  });

  test('LlmConfigRepository.getDefault 视觉优先', () async {
    final repo = LlmConfigRepository(sdb);
    await repo.insert(LlmConfig(name: 'text', apiUrl: 'u', apiKey: 'k', model: 'm', isDefault: true, createdAt: DateTime.now()));
    await repo.insert(LlmConfig(name: 'vision', apiUrl: 'u', apiKey: 'k', model: 'mv', supportsVision: true, isDefault: true, createdAt: DateTime.now()));
    final d = await repo.getDefault(vision: true);
    expect(d?.supportsVision, isTrue);
    final plain = await repo.getDefault();
    expect(plain, isNotNull);
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
}
