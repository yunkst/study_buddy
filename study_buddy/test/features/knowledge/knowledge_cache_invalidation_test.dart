// 知识 Tab：缓存失效回归测试（任务：agent 创建的知识点切回 Tab 看不到）。
//
// 背景：知识页 categoryChildrenProvider / topicsInCategoryProvider /
// topicSearchProvider 均为 FutureProvider.family，结果无限期缓存；agent 在
// /ai 会话 save_topic 写库后若不作废缓存，已浏览过知识页的用户切回看不到新增
// 知识点（StatefulShellRoute.indexedStack 保活页面，watch 旧缓存）。
//
// 修复：agent 写库的 onTopicTouched 回调里调用 invalidateKnowledgeCache，
// 作废全量知识缓存。本测试直接验证该行为：先读缓存 → 写库 → 调用失效 →
// 再读应为最新数据。
//
// 注：Riverpod 3.x 已不再导出 ProviderListenable 公共类型，所以这里走
// `dynamic` 避开类型问题；所有运行时类型仍由 AsyncValue<T> 静态保证。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/features/knowledge/knowledge_providers.dart';
import 'package:study_engine/study_engine.dart';

/// 让 future 进入 data 态：watch 一次 → 等真实异步查询（isolate 内）→
/// 再 read 一次让容器拿到 data 帧。
Future<void> _resolve(ProviderContainer container, dynamic provider) async {
  container.read(provider);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  container.read(provider);
}

/// 类型擦除 read（Riverpod 3.x 的 container.read 返回值的泛型推到调用点）。
T _data<T>(ProviderContainer container, dynamic provider) {
  return (container.read(provider) as AsyncValue<T>).requireValue;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late int mathCategoryId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final now = DateTime.now();
    mathCategoryId = await sdb.db.insert(
      'category',
      Category(parentId: null, name: '数学', createdAt: now).toMap(),
    );
  });
  tearDown(() async => await sdb.close());

  test('topicsInCategoryProvider 写库后不刷新 → 缓存仍是旧值（bug 锁定）', () async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    final p = topicsInCategoryProvider(mathCategoryId);
    await _resolve(container, p);
    expect(_data<List<Topic>>(container, p), isEmpty);

    // 写库一条知识点（不调用失效）。
    final now = DateTime.now();
    await sdb.db.insert(
      'topic',
      Topic(
        categoryId: mathCategoryId,
        question: '极限定义？',
        title: '极限定义',
        summary: '极限',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );

    // 缓存未失效 → 仍是空（这正是 bug，验证修复的回归条件成立）。
    await _resolve(container, p);
    expect(_data<List<Topic>>(container, p), isEmpty);
  });

  test('invalidateKnowledgeCache 后重新读取命中新增知识点', () async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    final p = topicsInCategoryProvider(mathCategoryId);
    await _resolve(container, p);
    expect(_data<List<Topic>>(container, p), isEmpty);

    // 写库一条知识点。
    final now = DateTime.now();
    await sdb.db.insert(
      'topic',
      Topic(
        categoryId: mathCategoryId,
        question: '极限定义？',
        title: '极限定义',
        summary: '极限',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );

    // 作废缓存（模拟 agent save_topic 后的 onTopicTouched 行为）。
    invalidateKnowledgeCache(container);

    // 重新读取：命中新增。
    await _resolve(container, p);
    expect(_data<List<Topic>>(container, p).single.title, '极限定义');
  });

  test('invalidateKnowledgeCache 同时作废分类树与搜索缓存', () async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    // 首次：根分类只有「数学」。
    final rootP = categoryChildrenProvider(null);
    await _resolve(container, rootP);
    expect(_data<List<Category>>(container, rootP).map((c) => c.name), ['数学']);

    // 首次搜索「极限」：无。
    final searchP = topicSearchProvider('极限');
    await _resolve(container, searchP);
    expect(_data<TopicSearchResult>(container, searchP).items, isEmpty);

    // 写库：新增顶级分类「物理」+ 知识点「极限定义」。
    final now = DateTime.now();
    await sdb.db.insert('category', Category(parentId: null, name: '物理', createdAt: now).toMap());
    await sdb.db.insert(
      'topic',
      Topic(
        categoryId: mathCategoryId,
        question: '极限定义？',
        title: '极限定义',
        summary: '极限',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );

    // 作废缓存。
    invalidateKnowledgeCache(container);

    // 重新读取：分类树含「物理」、搜索「极限」命中。
    await _resolve(container, rootP);
    expect(_data<List<Category>>(container, rootP).map((c) => c.name), containsAll(['数学', '物理']));
    await _resolve(container, searchP);
    expect(_data<TopicSearchResult>(container, searchP).items.single.title, '极限定义');
  });
}