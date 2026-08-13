import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// CategoryRepository 子树删除 / TopicRepository.delete 的测试。
///
/// 覆盖：
/// - delete(id)：单删知识点，FK CASCADE 自动清 mastery/edge/schedule/focus。
/// - previewSubtree：只统计不删，返回受影响的分类/知识点计数。
/// - deleteSubtree：事务内自底向上删子树（含多层分类、各层直挂知识点），
///   且对兄弟分类/知识点无副作用；CASCADE 随知识点删除清理依赖。
void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late CategoryRepository cats;
  late TopicRepository topics;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    cats = CategoryRepository(sdb);
    topics = TopicRepository(sdb);
  });
  tearDown(() async => await sdb.close());

  /// 建一棵测试子树：
  ///   数学(根，parent=null)
  ///     ├─ 高等数学
  ///     │    ├─ 极限  (topic: ε-δ定义)
  ///     │    └─ 求导  (topic: 链式法则)
  ///     └─ 技巧      (topic: 换元法)
  ///   英语(根，parent=null)  ← 兄弟，验证删除无副作用
  ///     └─ 语法 (topic: 时态)
  /// 返回各关键 id 供断言。
  Future<({
    int math,
    int advanced,
    int limit,
    int derive,
    int mathTrick,
    int english,
    int grammar,
    int epsDef,
    int chainRule,
    int substitution,
    int tense,
  })> seedTree() async {
    final math = await cats.ensurePath(['数学']);
    final advanced = await cats.ensurePath(['数学', '高等数学']);
    final limit = await cats.ensurePath(['数学', '高等数学', '极限']);
    final derive = await cats.ensurePath(['数学', '高等数学', '求导']);
    final mathTrick = await cats.ensurePath(['数学', '技巧']);
    final english = await cats.ensurePath(['英语']);
    final grammar = await cats.ensurePath(['英语', '语法']);

    Future<int> addTopic(int catId, String title) async {
      return topics.insert(Topic(
        categoryId: catId,
        question: 'q',
        title: title,
        summary: 's',
        createdAt: DateTime(2026, 8, 1),
        updatedAt: DateTime(2026, 8, 1),
      ));
    }

    final epsDef = await addTopic(limit, 'ε-δ极限定义');
    final chainRule = await addTopic(derive, '链式法则');
    final substitution = await addTopic(mathTrick, '换元法');
    final tense = await addTopic(grammar, '英语时态');

    return (
      math: math,
      advanced: advanced,
      limit: limit,
      derive: derive,
      mathTrick: mathTrick,
      english: english,
      grammar: grammar,
      epsDef: epsDef,
      chainRule: chainRule,
      substitution: substitution,
      tense: tense,
    );
  }

  group('TopicRepository.delete', () {
    test('删除知识点后findById返回null', () async {
      final s = await seedTree();
      final affected = await topics.delete(s.epsDef);
      expect(affected, 1);
      expect(await topics.findById(s.epsDef), isNull);
    });

    test('删除知识点级联清理 mastery_log', () async {
      final s = await seedTree();
      await sdb.db.insert('mastery_log', {
        'topic_id': s.epsDef,
        'status': 'learning',
        'reason': 'r',
        'changed_at': 0,
      });
      await topics.delete(s.epsDef);
      final rows = await sdb.db.query('mastery_log', where: 'topic_id = ?', whereArgs: [s.epsDef]);
      expect(rows, isEmpty);
    });

    test('删除知识点级联清理 topic_edge（双向）', () async {
      final s = await seedTree();
      // epsDef -> chainRule 的 prerequisite 边（双向都该被清）
      await sdb.db.insert('topic_edge', {
        'from_topic_id': s.epsDef,
        'to_topic_id': s.chainRule,
        'type': 'prerequisite',
        'created_at': 0,
      });
      await topics.delete(s.epsDef);
      final rows = await sdb.db.query('topic_edge',
          where: 'from_topic_id = ? OR to_topic_id = ?', whereArgs: [s.epsDef, s.epsDef]);
      expect(rows, isEmpty);
    });

    test('删除不存在的id返回0', () async {
      await seedTree();
      expect(await topics.delete(99999), 0);
    });
  });

  group('CategoryRepository.previewSubtree', () {
    test('统计子树内分类与知识点数量（含自身）', () async {
      final s = await seedTree();
      final preview = await cats.previewSubtree(s.math);
      // 分类：数学、高等数学、极限、求导、技巧 = 5
      expect(preview.categories, 5);
      // 知识点：ε-δ定义、链式法则、换元法 = 3（英语时态不在子树内）
      expect(preview.topics, 3);
    });

    test('只统计不删除', () async {
      final s = await seedTree();
      await cats.previewSubtree(s.math);
      // 数据原样还在
      expect(await topics.findById(s.epsDef), isNotNull);
      expect(await cats.findById(s.advanced), isNotNull);
    });

    test('叶子分类预览只含自身', () async {
      final s = await seedTree();
      final preview = await cats.previewSubtree(s.limit);
      expect(preview.categories, 1);
      expect(preview.topics, 1);
    });
  });

  group('CategoryRepository.deleteSubtree', () {
    test('删除整棵子树（多层分类+各层知识点）', () async {
      final s = await seedTree();
      final result = await cats.deleteSubtree(s.math);
      expect(result.categories, 5);
      expect(result.topics, 3);
      // 数学下所有分类与知识点都没了
      for (final id in [s.math, s.advanced, s.limit, s.derive, s.mathTrick]) {
        expect(await cats.findById(id), isNull, reason: '分类 $id 应被删除');
      }
      for (final id in [s.epsDef, s.chainRule, s.substitution]) {
        expect(await topics.findById(id), isNull, reason: '知识点 $id 应被删除');
      }
    });

    test('兄弟分类与知识点不受影响', () async {
      final s = await seedTree();
      await cats.deleteSubtree(s.math);
      expect(await cats.findById(s.english), isNotNull);
      expect(await cats.findById(s.grammar), isNotNull);
      expect(await topics.findById(s.tense), isNotNull);
    });

    test('删除知识点级联清理其掌握度/调度', () async {
      final s = await seedTree();
      await sdb.db.insert('mastery_log', {
        'topic_id': s.epsDef,
        'status': 'learning',
        'reason': 'r',
        'changed_at': 0,
      });
      await sdb.db.insert('topic_schedule', {
        'topic_id': s.epsDef,
        'stability': 1.0,
        'difficulty': 5.0,
        'reps': 1,
        'lapses': 0,
      });
      await cats.deleteSubtree(s.math);
      expect(await sdb.db.query('mastery_log', where: 'topic_id = ?', whereArgs: [s.epsDef]), isEmpty);
      expect(await sdb.db.query('topic_schedule', where: 'topic_id = ?', whereArgs: [s.epsDef]), isEmpty);
    });

    test('删除根顶级分类', () async {
      final s = await seedTree();
      final result = await cats.deleteSubtree(s.english);
      expect(result.categories, 2); // 英语、语法
      expect(result.topics, 1); // 时态
      expect(await cats.findById(s.english), isNull);
      expect(await topics.findById(s.tense), isNull);
    });
  });
}
