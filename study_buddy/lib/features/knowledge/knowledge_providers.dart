import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/providers/topic_schedule_provider.dart';

/// 知识 Tab 的数据 providers。
///
/// 依赖 `databaseProvider`（SQLite）与 `topicScheduleRepositoryProvider`（FSRS 调度）。
/// 提供分类树、知识点列表（按分类）、知识点搜索、以及基于 schedule 派生的掌握度。
///
/// `categoryChildrenProvider` 的 family 参数为 `int?`：null 表示根分类。

/// 分类树某一节点的直接子分类（null = 根分类）。
final categoryChildrenProvider = FutureProvider.family<List<Category>, int?>((ref, parentId) async {
  final db = await ref.watch(databaseProvider.future);
  return CategoryRepository(db).findChildren(parentId);
});

/// 指定分类下的知识点列表。
final topicsInCategoryProvider = FutureProvider.family<List<Topic>, int>((ref, categoryId) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicRepository(db).findByCategory(categoryId);
});

/// 按关键字搜索知识点。
final topicSearchProvider = FutureProvider.family<TopicSearchResult, String>((ref, keyword) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicRepository(db).search(keyword);
});

/// 知识点当前掌握度（派生自 schedule）。
final masteryOfProvider = FutureProvider.family<MasteryStatus, int>((ref, topicId) async {
  final repo = await ref.watch(topicScheduleRepositoryProvider.future);
  final s = await repo.findByTopic(topicId);
  return MasteryFromSchedule.fromSchedule(s);
});