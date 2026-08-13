import '../db/database.dart';
import '../models/models.dart';

class CategoryRepository {
  final StudyDatabase _db;
  CategoryRepository(this._db);

  /// 逐级创建分类，已存在则跳过，返回末端 category id。
  Future<int> ensurePath(List<String> segments) async {
    int? parentId;
    for (final name in segments) {
      final existing = await _findByName(name, parentId);
      if (existing != null) {
        parentId = existing.id;
        continue;
      }
      final now = DateTime.now();
      final id = await _db.db.insert('category', Category(
        parentId: parentId,
        name: name,
        createdAt: now,
      ).toMap());
      parentId = id;
    }
    return parentId!;
  }

  /// 按 name 逐级下钻，返回末端 category 或 null（任一级缺失即 null）。
  Future<Category?> findByPath(List<String> segments) async {
    int? parentId;
    Category? current;
    for (final name in segments) {
      current = await _findByName(name, parentId);
      if (current == null) return null;
      parentId = current.id;
    }
    return current;
  }

  /// 直接子分类。parentId 为 null 时返回顶级。
  Future<List<Category>> findChildren(int? parentId) async {
    final rows = parentId == null
        ? await _db.db.query('category', where: 'parent_id IS NULL', orderBy: 'sort_order, name')
        : await _db.db.query('category', where: 'parent_id = ?', whereArgs: [parentId], orderBy: 'sort_order, name');
    return rows.map(Category.fromMap).toList();
  }

  /// 按 id 取单个分类（不存在返回 null）。
  Future<Category?> findById(int id) async {
    final rows = await _db.db.query('category', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Category.fromMap(rows.first);
  }

  /// 向上回溯到根，返回完整路径段列表。
  Future<List<String>> pathOf(int categoryId) async {
    final segments = <String>[];
    int? currentId = categoryId;
    while (currentId != null) {
      final rows = await _db.db.query('category', where: 'id = ?', whereArgs: [currentId], limit: 1);
      if (rows.isEmpty) break;
      final cat = Category.fromMap(rows.first);
      segments.insert(0, cat.name);
      currentId = cat.parentId;
    }
    return segments;
  }

  Future<Category?> _findByName(String name, int? parentId) async {
    final rows = parentId == null
        ? await _db.db.query('category', where: 'name = ? AND parent_id IS NULL', whereArgs: [name], limit: 1)
        : await _db.db.query('category', where: 'name = ? AND parent_id = ?', whereArgs: [name, parentId], limit: 1);
    return rows.isEmpty ? null : Category.fromMap(rows.first);
  }

  /// 收集 [rootId] 子树内的全部分类 id（含 rootId 自身），BFS 自顶向下。
  ///
  /// category.parent_id 是 ON DELETE RESTRICT，topic.category_id 无级联，
  /// 故删除前需先把整棵子树的分类 id 收齐，统一删其下知识点，再按「叶子优先」
  /// 删分类，避免 RESTRICT/外键违约。供 [previewSubtree] / [deleteSubtree] 复用。
  Future<List<int>> _collectSubtreeIds(int rootId) async {
    final ids = <int>[];
    final queue = <int>[rootId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      ids.add(id);
      final children = await _db.db.query('category',
          where: 'parent_id = ?', whereArgs: [id], columns: ['id']);
      queue.addAll(children.map((r) => r['id'] as int));
    }
    return ids;
  }

  /// 预览删除 [rootId] 子树的影响范围：返回将受影响的分类数与知识点数。
  ///
  /// 只统计不删除，供 UI 确认弹窗展示「删除 X 及其下 N 个子分类、M 个知识点」。
  Future<DeletedSubtree> previewSubtree(int rootId) async {
    final ids = await _collectSubtreeIds(rootId);
    final placeholders = List.filled(ids.length, '?').join(',');
    final topicRows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM topic WHERE category_id IN ($placeholders)',
      ids,
    );
    final topicCount = (topicRows.isNotEmpty ? topicRows.first['c'] as int : 0);
    return DeletedSubtree(categories: ids.length, topics: topicCount);
  }

  /// 删除 [rootId] 子树（含其全部后代分类与直挂知识点），返回实际删除计数。
  ///
  /// 在单事务内执行：先按子树分类 id 批量删知识点（触发 topic 的 FK CASCADE 清理
  /// mastery/edge/schedule/focus），再按「叶子优先」逆序删分类（满足 parent 的
  /// ON DELETE RESTRICT）。任一步失败回滚，保证不留半删的破碎状态。
  Future<DeletedSubtree> deleteSubtree(int rootId) async {
    return _db.db.transaction((txn) async {
      final ids = <int>[];
      final queue = <int>[rootId];
      while (queue.isNotEmpty) {
        final id = queue.removeAt(0);
        ids.add(id);
        final children = await txn.query('category',
            where: 'parent_id = ?', whereArgs: [id], columns: ['id']);
        queue.addAll(children.map((r) => r['id'] as int));
      }
      final placeholders = List.filled(ids.length, '?').join(',');
      final topicDeleted = await txn.rawDelete(
        'DELETE FROM topic WHERE category_id IN ($placeholders)',
        ids,
      );
      // 叶子优先：BFS 收集顺序天然父在前、子在后，逆序删即先删叶子，满足 RESTRICT。
      var catDeleted = 0;
      for (final id in ids.reversed) {
        catDeleted += await txn.delete('category', where: 'id = ?', whereArgs: [id]);
      }
      return DeletedSubtree(categories: catDeleted, topics: topicDeleted);
    });
  }
}

/// 子树删除/预览结果：受影响的分类数与知识点数。
class DeletedSubtree {
  final int categories;
  final int topics;
  const DeletedSubtree({required this.categories, required this.topics});
}