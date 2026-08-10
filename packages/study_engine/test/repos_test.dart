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

  test('ReviewScheduleRepository getByTopic 无记录返回 null', () async {
    final repo = ReviewScheduleRepository(sdb);
    expect(await repo.getByTopic(999), isNull);
  });

  test('ReviewScheduleRepository upsert 插入与更新（主键原子）', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final tid = await topics.insert(Topic(categoryId: catId, question: 'q', title: 't', summary: 's', createdAt: now, updatedAt: now));
    final repo = ReviewScheduleRepository(sdb);

    final s1 = SpacedRepetitionService.initial(tid, now);
    await repo.upsert(s1);
    expect((await repo.getByTopic(tid))?.intervalDays, 0);

    // 二次 upsert（首次反馈后）不报主键冲突
    final s2 = SpacedRepetitionService.apply(s1, ReviewFeedback.remembered, now);
    await repo.upsert(s2);
    final got = await repo.getByTopic(tid);
    expect(got?.intervalDays, 1);
    expect(got?.reviewCount, 1);
  });

  test('ReviewScheduleRepository findDue 只返回到期且升序', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10, 12, 0);
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: 'A', summary: 's', createdAt: now, updatedAt: now));
    final b = await topics.insert(Topic(categoryId: catId, question: 'q2', title: 'B', summary: 's', createdAt: now, updatedAt: now));
    final c = await topics.insert(Topic(categoryId: catId, question: 'q3', title: 'C', summary: 's', createdAt: now, updatedAt: now));
    final repo = ReviewScheduleRepository(sdb);
    // A 昨天到期，B 今天到期，C 明天到期
    await repo.upsert(SpacedRepetitionService.initial(a, now.subtract(const Duration(days: 1))));
    await repo.upsert(SpacedRepetitionService.initial(b, now));
    await repo.upsert(SpacedRepetitionService.initial(c, now.add(const Duration(days: 1))));

    final due = await repo.findDue(now);
    expect(due.map((s) => s.topicId), [a, b]); // C 未到期排除
    expect(due.first.nextReviewAt.isAfter(due.last.nextReviewAt) == false, isTrue); // 升序
  });

  test('FK 启用：删 topic 连带删 review_schedule（CASCADE 回归）', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final repo = ReviewScheduleRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final tid = await topics.insert(Topic(categoryId: catId, question: 'q', title: 't', summary: 's', createdAt: now, updatedAt: now));
    await repo.upsert(SpacedRepetitionService.initial(tid, now));

    await sdb.db.delete('topic', where: 'id = ?', whereArgs: [tid]);
    expect(await repo.getByTopic(tid), isNull, reason: 'FK 未启用，删 topic 后调度残留');
  });

  test('ReviewQueueRepository dueQueue JOIN 一次查 + 限量', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final repo = ReviewQueueRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10, 12, 0);
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: '洛必达', summary: 's', createdAt: now, updatedAt: now));
    await topics.insert(Topic(categoryId: catId, question: 'q2', title: '夹逼', summary: 's', createdAt: now, updatedAt: now));
    final sched = ReviewScheduleRepository(sdb);
    await sched.upsert(SpacedRepetitionService.initial(a, now.subtract(const Duration(days: 1))));

    final q = await repo.dueQueue(now);
    expect(q, hasLength(1));
    expect(q.first.topicId, a);
    expect(q.first.title, '洛必达');
    expect(q.first.question, 'q1');

    final capped = await repo.dueQueue(now, limit: 0);
    expect(capped, isEmpty);
  });

  test('ReviewQueueRepository todayNewQueue 排除已建 schedule + 跨天边界', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final repo = ReviewQueueRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final dayStart = DateTime(2026, 8, 10, 0, 0);
    final today = dayStart.add(const Duration(hours: 10));
    final yesterday = dayStart.subtract(const Duration(minutes: 1));
    // 今天新存（无 schedule）——应返回
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: '今天新增未背', summary: 's', createdAt: today, updatedAt: today));
    // 今天新存且已背（建了 schedule）——应排除（背过即移出今日新增，防二次 apply）
    final b = await topics.insert(Topic(categoryId: catId, question: 'q2', title: '今天新增已背', summary: 's', createdAt: today, updatedAt: today));
    await ReviewScheduleRepository(sdb).upsert(SpacedRepetitionService.initial(b, today));
    // 昨天存（有 schedule，不算今日新增）——应排除
    final c = await topics.insert(Topic(categoryId: catId, question: 'q3', title: '昨天', summary: 's', createdAt: yesterday, updatedAt: yesterday));
    await ReviewScheduleRepository(sdb).upsert(SpacedRepetitionService.initial(c, yesterday));

    final q = await repo.todayNewQueue(dayStart);
    expect(q.map((i) => i.topicId), [a]); // 仅未背的今日新增返回
    expect(q.first.title, '今天新增未背');
  });

  test('findOrCreateByTopic 首次建会话、二次复用', () async {
    final repo = ChatRepository(sdb);
    final id1 = await repo.findOrCreateByTopic(1, 'ε-δ极限定义');
    final id2 = await repo.findOrCreateByTopic(1, 'ε-δ极限定义');
    expect(id1, id2);
  });

  test('findOrCreateByTopic 不同 topic 建不同会话', () async {
    final repo = ChatRepository(sdb);
    final a = await repo.findOrCreateByTopic(1, 'A');
    final b = await repo.findOrCreateByTopic(2, 'B');
    expect(a, isNot(b));
  });

  test('listMessages 空会话返回空列表', () async {
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study', 't');
    expect(await repo.listMessages(sid), isEmpty);
  });

  test('listMessages 往返：纯文本 + 多轮 + 含 tool_calls 反序列化', () async {
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study', 't');
    await repo.addMessage(sid, const ChatMessage(role: 'user', content: '你好'));
    await repo.addMessage(sid, const ChatMessage(role: 'assistant', content: '你好！'));
    await repo.addMessage(sid, const ChatMessage(
      role: 'assistant',
      content: '',
      toolCalls: [ToolCall(id: 'call_1', name: 'get_topic', arguments: '{"id":1}')],
    ));
    final msgs = await repo.listMessages(sid);
    expect(msgs, hasLength(3));
    expect(msgs[0].role, 'user');
    expect(msgs[0].content, '你好');
    expect(msgs[2].toolCalls, hasLength(1));
    expect(msgs[2].toolCalls!.first.name, 'get_topic');
    expect(msgs[2].toolCalls!.first.arguments, '{"id":1}');
  });

  test('listMessages 往返：content parts(TextPart/ImageUrlPart)', () async {
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study', 't');
    await repo.addMessage(sid, const ChatMessage(
      role: 'user',
      content: [
        TextPart('看图'),
        ImageUrlPart('data:image/png;base64,xxx', detail: 'high'),
      ],
    ));
    final msgs = await repo.listMessages(sid);
    final parts = msgs.first.content as List<ContentPart>;
    expect(parts, hasLength(2));
    expect(parts[0], isA<TextPart>());
    expect((parts[0] as TextPart).text, '看图');
    expect(parts[1], isA<ImageUrlPart>());
    expect((parts[1] as ImageUrlPart).url, 'data:image/png;base64,xxx');
    expect((parts[1] as ImageUrlPart).detail, 'high');
  });
}
