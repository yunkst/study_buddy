import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// 知识库某层列表项：分类或知识点。
class CategoryChild {
  final bool isCategory;
  final int id; // category.id 或 topic.id
  final String name; // category.name 或 topic.title
  final bool hasChildren; // 仅分类有意义：是否有子分类
  const CategoryChild({
    required this.isCategory,
    required this.id,
    required this.name,
    this.hasChildren = false,
  });
}

/// 详情页聚合数据。
class TopicDetail {
  final Topic topic;
  final List<String> path; // 分类路径段
  final List<TopicEdgeView> edges; // 关联边（prerequisite 在前）
  const TopicDetail({required this.topic, required this.path, required this.edges});
}

/// 搜索结果项：id + 标题 + 路径。
class KnowledgeSearchResult {
  final int id;
  final String title;
  final List<String> path;
  const KnowledgeSearchResult({required this.id, required this.title, required this.path});
}

/// 背诵模式。
enum ReviewMode { todayNew, due }

// ---- repository providers（FutureProvider：DB 就绪后构造）----

final categoryRepositoryProvider =
    FutureProvider<CategoryRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return CategoryRepository(db);
});

final topicRepositoryProvider = FutureProvider<TopicRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicRepository(db);
});

final topicEdgeRepositoryProvider =
    FutureProvider<TopicEdgeRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicEdgeRepository(db);
});

final reviewScheduleRepositoryProvider =
    FutureProvider<ReviewScheduleRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReviewScheduleRepository(db);
});

final reviewQueueRepositoryProvider =
    FutureProvider<ReviewQueueRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReviewQueueRepository(db);
});

// ---- 聚合 providers ----

/// 某层列表：子分类（前置）+ 直挂知识点。parentId 为 null 表根级。
final categoryChildrenProvider =
    FutureProvider.family<List<CategoryChild>, int?>((ref, parentId) async {
  final cats = await ref.watch(categoryRepositoryProvider.future);
  final topics = await ref.watch(topicRepositoryProvider.future);

  final children = await cats.findChildren(parentId);
  final list = <CategoryChild>[];
  for (final c in children) {
    final sub = await cats.findChildren(c.id);
    list.add(CategoryChild(
      isCategory: true,
      id: c.id!,
      name: c.name,
      hasChildren: sub.isNotEmpty,
    ));
  }
  if (parentId != null) {
    final direct = await topics.findByCategory(parentId);
    list.addAll(direct.map(
        (t) => CategoryChild(isCategory: false, id: t.id!, name: t.title)));
  }
  return list;
});

/// 详情聚合：topic + 路径 + 边（prerequisite 在前）。
final topicDetailProvider =
    FutureProvider.family<TopicDetail, int>((ref, topicId) async {
  final topics = await ref.watch(topicRepositoryProvider.future);
  final cats = await ref.watch(categoryRepositoryProvider.future);
  final edges = await ref.watch(topicEdgeRepositoryProvider.future);

  final topic = await topics.findById(topicId);
  if (topic == null) throw StateError('知识点不存在: $topicId');
  final path = await cats.pathOf(topic.categoryId);
  final edgeList = await edges.findByTopic(topicId);
  edgeList.sort((a, b) {
    if (a.type == 'prerequisite' && b.type != 'prerequisite') return -1;
    if (b.type == 'prerequisite' && a.type != 'prerequisite') return 1;
    return 0;
  });
  return TopicDetail(topic: topic, path: path, edges: edgeList);
});

/// 关键词搜索：title + 路径。
final knowledgeSearchProvider =
    FutureProvider.family<List<KnowledgeSearchResult>, String>(
        (ref, keyword) async {
  final topics = await ref.watch(topicRepositoryProvider.future);
  final cats = await ref.watch(categoryRepositoryProvider.future);
  final r = await topics.search(keyword, limit: 30);
  final results = <KnowledgeSearchResult>[];
  for (final item in r.items) {
    final path = await cats.pathOf(item.categoryId);
    results.add(KnowledgeSearchResult(id: item.id, title: item.title, path: path));
  }
  return results;
});
