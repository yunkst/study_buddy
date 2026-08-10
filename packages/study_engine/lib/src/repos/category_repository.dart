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
}