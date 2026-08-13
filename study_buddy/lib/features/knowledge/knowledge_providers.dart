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

/// 按 id 取单个分类（用于读取 parentId 以支持「返回上级」回到父级而非根）。
final categoryByIdProvider = FutureProvider.family<Category?, int>((ref, id) async {
  final db = await ref.watch(databaseProvider.future);
  return CategoryRepository(db).findById(id);
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

/// 作废知识 Tab 全量缓存（分类树 / 按分类知识点 / 搜索 / 单分类）。
///
/// 这些 provider 是 `FutureProvider.family`，结果会被无限期缓存。当 agent
/// 在别处（如 /ai 会话）save_topic / update_topic 写库后，已浏览过知识 Tab
/// 的用户切回时若不刷新会看不到新增知识点（StatefulShellRoute.indexedStack
/// 保活页面，watch 的是旧缓存）。故在写库后调用本函数令其下次读取重拉。
///
/// 入参为 `ProviderContainer`：provider 内可传 `ref.container`，测试可直接传
/// `ProviderContainer`，二者共用同一套 invalidate 行为。
void invalidateKnowledgeCache(ProviderContainer container) {
  container.invalidate(categoryChildrenProvider);
  container.invalidate(categoryByIdProvider);
  container.invalidate(topicsInCategoryProvider);
  container.invalidate(topicSearchProvider);
}

/// 预览删除分类子树的影响范围（仅统计，不删）。
///
/// 参数：categoryId；返回 [DeletedSubtree]。供长按确认弹窗展示。
final previewCategoryDeleteProvider =
    FutureProvider.family<DeletedSubtree, int>((ref, categoryId) async {
  final db = await ref.read(databaseProvider.future);
  return CategoryRepository(db).previewSubtree(categoryId);
});

/// 删除单知识点的动作（family key = topicId）。
///
/// 调用后 invalidate 相关 provider（mastery、所属分类的知识列表、搜索结果），
/// 使 UI 重建刷新。
final deleteTopicActionProvider =
    Provider.family<Future<void> Function(), int>((ref, topicId) {
  return () async {
    final db = await ref.read(databaseProvider.future);
    await TopicRepository(db).delete(topicId);
    // 刷新：知识点当前掌握度（该 topicId 失效）、该分类下知识列表、搜索结果。
    // topicsInCategoryProvider 不知道原 categoryId，全 family invalidate 让所有缓存失效。
    ref.invalidate(masteryOfProvider(topicId));
    ref.invalidate(topicsInCategoryProvider);
    ref.invalidate(topicSearchProvider);
  };
});

/// 删除分类子树的动作（family key = categoryId）。
///
/// 事务内删子树 + 全部分支知识点；FK CASCADE 清理 mastery/edge/schedule/focus。
/// 调用后 invalidate 分类树与全知识列表，使 UI 重建刷新。
final deleteCategoryActionProvider =
    Provider.family<Future<DeletedSubtree> Function(), int>((ref, categoryId) {
  return () async {
    final db = await ref.read(databaseProvider.future);
    final result = await CategoryRepository(db).deleteSubtree(categoryId);
    ref.invalidate(categoryChildrenProvider);
    ref.invalidate(topicsInCategoryProvider);
    ref.invalidate(topicSearchProvider);
    return result;
  };
});
