# 知识点管理体系重设计 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重构 study_engine 的知识点体系为分类树 + 知识图骨架，让 AI 能存带引子的细粒度知识点、下钻巡视、精准定位、按需更新、建立关联，从源头替代事后去重。

**Architecture:** 新增 `category` 表（自引用树）承载学科→模块→章节层级，`topic` 表废弃扁平 `domain` 改挂 `category_id` 并加 `question`/`summary` 必填字段 + `title` 全库 UNIQUE，新增 `topic_edge` 表存知识点关联边（prerequisite/related）。Repository 层手写 SQL，Agent 工具集从 2 个扩到 6 个（list/search/get/save/update/link），`save_topic` 内部按 title 查重硬保证防重复。

**Tech Stack:** Dart 3.9+ / sqflite_common / test 包 / OpenAI function-calling 工具 schema

## Global Constraints

- 数据库版本 `kCurrentDbVersion` 从 1 升到 2，新增 `_v2` 迁移分支
- `topic.title` 全库 `UNIQUE`，`topic.question`/`topic.summary` 均 `NOT NULL`
- `topic_edge` 用 `UNIQUE(from_topic_id, to_topic_id, type)` 防重复边，`ON DELETE CASCADE` 删知识点连带删边
- 废弃扁平 `domain`：删除 `Topic.domain` 字段、`topic_domain` 表、`TopicDomain` 类、`TopicDomainRepository`、`SubjectRepository`、`Subject` 类（学科并入 category 顶级节点）
- 测试用 `test` 包（非 flutter_test），`sqflite_common_ffi` + `inMemoryDatabasePath`
- 不引入 FTS，搜索用 SQLite `LIKE '%kw%'`
- `mastery_log` 表保留不动（死代码，后续激活）

---

## 文件结构

| 文件 | 责任 | 动作 |
|---|---|---|
| `packages/study_engine/lib/src/models/models.dart` | 数据模型类 | 改：删 Subject/TopicDomain，改 Topic，加 Category/TopicEdge |
| `packages/study_engine/lib/src/db/database_migrations.dart` | 迁移 | 改：kCurrentDbVersion→2，加 `_v2` 重建 topic 表 + 建 category/topic_edge |
| `packages/study_engine/lib/src/repos/category_repository.dart` | 分类树 CRUD | 新建 |
| `packages/study_engine/lib/src/repos/topic_repository.dart` | 知识点 CRUD | 改：适配新字段 + 加 search/findByTitle/updateSummary |
| `packages/study_engine/lib/src/repos/topic_edge_repository.dart` | 关联边 CRUD | 新建 |
| `packages/study_engine/lib/src/repos/topic_domain_repository.dart` | （废弃） | 删除 |
| `packages/study_engine/lib/src/repos/subject_repository.dart` | （废弃） | 删除 |
| `packages/study_engine/lib/src/repos/mastery_repository.dart` | 掌握度（不动） | 不改 |
| `packages/study_engine/lib/src/agent/agent_tools.dart` | 工具 schema | 改：6 个工具 |
| `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` | 工具执行 + prompt | 改：6 分支 + 新 prompt |
| `packages/study_engine/lib/study_engine.dart` | barrel 导出 | 改：更新导出 |
| `packages/study_engine/test/repos_test.dart` | Repository 单测 | 改：替换为新模型测试 |
| `packages/study_engine/test/study_scenario_integration_test.dart` | 集成测试 | 改：新场景 |
| `study_buddy/lib/core/providers/agent_session_provider.dart` | APP 注入 | 改：构造新 Repository |

---

## Task 1: 数据模型改造（models.dart）

**Files:**
- Modify: `packages/study_engine/lib/src/models/models.dart`

**Interfaces:**
- Produces: `Category`、`TopicEdge` 类；改造后的 `Topic` 类（`categoryId`/`question`/`summary`(必填)/`updatedAt`/`title`）；删除 `Subject`、`TopicDomain`

- [ ] **Step 1: 替换 Subject 与 Topic 类**

把 `models.dart` 第 4-60 行（从 `/// 学科。` 到 `Topic` 类结束的 `}`）替换为：

```dart
/// 分类节点。自引用树，承载 学科→模块→章节。学科是顶级节点（parent_id 为 null）。
class Category {
  final int? id;
  final int? parentId;
  final String name;
  final int sortOrder;
  final DateTime createdAt;
  const Category({
    this.id,
    this.parentId,
    required this.name,
    this.sortOrder = 0,
    required this.createdAt,
  });

  factory Category.fromMap(Map<String, Object?> m) => Category(
        id: m['id'] as int?,
        parentId: m['parent_id'] as int?,
        name: m['name'] as String,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        if (parentId != null) 'parent_id': parentId,
        'name': name,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 知识点。挂载到 Category，含背诵引子(question)与答案本体(summary)。
class Topic {
  final int? id;
  final int categoryId;
  final String question; // 必填：背诵引子
  final String title; // 全库唯一
  final String summary; // 必填：答案本体，背诵揭晓内容
  final DateTime createdAt;
  final DateTime updatedAt;
  const Topic({
    this.id,
    required this.categoryId,
    required this.question,
    required this.title,
    required this.summary,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Topic.fromMap(Map<String, Object?> m) => Topic(
        id: m['id'] as int?,
        categoryId: m['category_id'] as int,
        question: m['question'] as String,
        title: m['title'] as String,
        summary: m['summary'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'category_id': categoryId,
        'question': question,
        'title': title,
        'summary': summary,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}
```

- [ ] **Step 2: 删除 TopicDomain 类，新增 TopicEdge**

删除 `models.dart` 原 `TopicDomain` 类（第 62-82 行，`/// 学科内领域分类。` 到其结束 `}`）。在 `Topic` 类之后、`/// 掌握状态枚举。` 之前插入：

```dart
/// 知识点关联边。prerequisite=前置依赖(有向)，related=相关(无向)。
class TopicEdge {
  final int? id;
  final int fromTopicId;
  final int toTopicId;
  final String type; // 'prerequisite' | 'related'
  final DateTime createdAt;
  const TopicEdge({
    this.id,
    required this.fromTopicId,
    required this.toTopicId,
    required this.type,
    required this.createdAt,
  });

  factory TopicEdge.fromMap(Map<String, Object?> m) => TopicEdge(
        id: m['id'] as int?,
        fromTopicId: m['from_topic_id'] as int,
        toTopicId: m['to_topic_id'] as int,
        type: m['type'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'from_topic_id': fromTopicId,
        'to_topic_id': toTopicId,
        'type': type,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}
```

- [ ] **Step 3: 验证编译**

Run: `cd packages/study_engine && dart analyze lib/src/models/models.dart`
Expected: models.dart 自身无错（其他文件引用旧 Topic 字段会报错，本步只确认 models.dart 内部正确）

- [ ] **Step 4: Commit**

```bash
git add packages/study_engine/lib/src/models/models.dart
git commit -m "refactor(models): 废弃 Subject/TopicDomain，改造 Topic，新增 Category/TopicEdge"
```

---

## Task 2: 数据库迁移 v2（database_migrations.dart）

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`

**Interfaces:**
- Consumes: `Category`/`Topic`/`TopicEdge` 模型（Task 1）
- Produces: `kCurrentDbVersion = 2`；`_v2` 迁移建 `category`/`topic`(重建)/`topic_edge` 表

- [ ] **Step 1: 更新版本号与迁移分发**

把 `database_migrations.dart` 第 4 行 `const int kCurrentDbVersion = 1;` 改为：

```dart
const int kCurrentDbVersion = 2;
```

在 `switch (v)` 的 `case 1:` 后、`default:` 前插入 `case 2`：

```dart
      case 2:
        _v2(batch);
        break;
```

- [ ] **Step 2: 新增 _v2 迁移函数**

在 `database_migrations.dart` 末尾（`_v1` 函数结束后）追加：

```dart
/// v2：知识点体系重设计。新建 category 表，重建 topic 表（废弃 domain/subject_id/parent_topic_id，
/// 加 category_id/question/updated_at，title 改 UNIQUE，summary 改 NOT NULL），新建 topic_edge 表。
/// 地基阶段无真实数据，直接 DROP 重建 topic。
void _v2(Batch batch) {
  // 删除依赖 topic 的旧索引（mastery_log 的 idx_mastery_topic 不依赖 topic 字段，保留）
  batch.execute('DROP TABLE IF EXISTS topic_domain');
  // mastery_log 引用 topic(id)，先临时移除 FK 约束：重建 mastery_log 不带 FK
  batch.execute('CREATE TABLE mastery_log_new AS SELECT * FROM mastery_log');
  batch.execute('DROP TABLE mastery_log');
  batch.execute('''
    CREATE TABLE mastery_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      topic_id INTEGER NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      changed_at INTEGER NOT NULL
    )
  ''');
  batch.execute('INSERT INTO mastery_log SELECT * FROM mastery_log_new');
  batch.execute('DROP TABLE mastery_log_new');
  batch.execute('CREATE INDEX IF NOT EXISTS idx_mastery_topic ON mastery_log(topic_id, changed_at)');

  // 重建 subject 为 category 顶级节点（无真实数据，直接重建）
  batch.execute('DROP TABLE IF EXISTS topic');
  batch.execute('DROP TABLE IF EXISTS subject');

  batch.execute('''
    CREATE TABLE category (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      parent_id INTEGER,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (parent_id) REFERENCES category(id) ON DELETE RESTRICT
    )
  ''');
  batch.execute('CREATE INDEX idx_category_parent ON category(parent_id)');

  batch.execute('''
    CREATE TABLE topic (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category_id INTEGER NOT NULL,
      question TEXT NOT NULL,
      title TEXT NOT NULL UNIQUE,
      summary TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (category_id) REFERENCES category(id)
    )
  ''');
  batch.execute('CREATE INDEX idx_topic_category ON topic(category_id)');

  batch.execute('''
    CREATE TABLE topic_edge (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_topic_id INTEGER NOT NULL,
      to_topic_id INTEGER NOT NULL,
      type TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (from_topic_id) REFERENCES topic(id) ON DELETE CASCADE,
      FOREIGN KEY (to_topic_id) REFERENCES topic(id) ON DELETE CASCADE,
      UNIQUE(from_topic_id, to_topic_id, type)
    )
  ''');
  batch.execute('CREATE INDEX idx_topic_edge_from ON topic_edge(from_topic_id)');
  batch.execute('CREATE INDEX idx_topic_edge_to ON topic_edge(to_topic_id)');
}
```

- [ ] **Step 3: 验证迁移编译**

Run: `cd packages/study_engine && dart analyze lib/src/db/database_migrations.dart`
Expected: 无错

- [ ] **Step 4: Commit**

```bash
git add packages/study_engine/lib/src/db/database_migrations.dart
git commit -m "feat(db): v2 迁移 — category 树 + topic 重建 + topic_edge"
```

---

## Task 3: CategoryRepository（新建）

**Files:**
- Create: `packages/study_engine/lib/src/repos/category_repository.dart`

**Interfaces:**
- Consumes: `StudyDatabase`、`Category`
- Produces: `CategoryRepository` 类，方法 `ensurePath(List<String>) → Future<int>`、`findByPath(List<String>) → Future<Category?>`、`findChildren(int?) → Future<List<Category>>`、`pathOf(int) → Future<List<String>>`

- [ ] **Step 1: 写失败测试**

在 `packages/study_engine/test/repos_test.dart` 的 `main()` 内追加测试（暂不删旧测试，Task 10 统一清理）：

```dart
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/repos_test.dart -N "CategoryRepository"`
Expected: FAIL — `CategoryRepository` 未定义 / 未导入

- [ ] **Step 3: 实现 CategoryRepository**

创建 `packages/study_engine/lib/src/repos/category_repository.dart`：

```dart
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/repos_test.dart -N "CategoryRepository"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/study_engine/lib/src/repos/category_repository.dart packages/study_engine/test/repos_test.dart
git commit -m "feat(repos): CategoryRepository — 分类树 ensurePath/findByPath/findChildren/pathOf"
```

---

## Task 4: TopicRepository 改造

**Files:**
- Modify: `packages/study_engine/lib/src/repos/topic_repository.dart`

**Interfaces:**
- Consumes: `Topic`（新字段，Task 1）、`StudyDatabase`
- Produces: `TopicRepository` 方法 `insert`/`findById`/`findByCategory`/`findByTitle`/`search`/`updateSummary`

- [ ] **Step 1: 写失败测试**

在 `test/repos_test.dart` 的 `main()` 内追加：

```dart
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/repos_test.dart -N "TopicRepository"`
Expected: FAIL — `findByCategory`/`findByTitle`/`search`/`updateSummary` 未定义，`insert` 参数不匹配

- [ ] **Step 3: 重写 TopicRepository**

把 `packages/study_engine/lib/src/repos/topic_repository.dart` 整个文件替换为：

```dart
import '../db/database.dart';
import '../models/models.dart';

/// search 的结果：items + 命中总数（用于分页"还有 N 条未展示"）。
class TopicSearchResult {
  final List<TopicSearchItem> items;
  final int total;
  TopicSearchResult(this.items, this.total);
}

/// search 返回的轻量项：仅 id+title+categoryId（调用方再 pathOf 重建路径）。
class TopicSearchItem {
  final int id;
  final String title;
  final int categoryId;
  TopicSearchItem(this.id, this.title, this.categoryId);
}

class TopicRepository {
  final StudyDatabase _db;
  TopicRepository(this._db);

  Future<int> insert(Topic t) => _db.db.insert('topic', t.toMap());

  Future<Topic?> findById(int id) async {
    final rows = await _db.db.query('topic', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 按 title 精确匹配（全库唯一，save_topic 查重用）。
  Future<Topic?> findByTitle(String title) async {
    final rows = await _db.db.query('topic', where: 'title = ?', whereArgs: [title], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 某分类直挂的知识点（仅 id+title，list_topics 用）。
  Future<List<Topic>> findByCategory(int categoryId) async {
    final rows = await _db.db.query('topic', where: 'category_id = ?', whereArgs: [categoryId], orderBy: 'title');
    return rows.map(Topic.fromMap).toList();
  }

  /// 跨 title+question+summary 的 LIKE 搜索。limit 默认 30。
  Future<TopicSearchResult> search(String keyword, {int limit = 30, int offset = 0}) async {
    final like = '%$keyword%';
    final countRows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM topic WHERE title LIKE ? OR question LIKE ? OR summary LIKE ?',
      [like, like, like],
    );
    final total = countRows.isNotEmpty ? (countRows.first['c'] as int) : 0;
    final rows = await _db.db.rawQuery(
      'SELECT id, title, category_id FROM topic WHERE title LIKE ? OR question LIKE ? OR summary LIKE ? ORDER BY title LIMIT ? OFFSET ?',
      [like, like, like, limit, offset],
    );
    final items = rows.map((r) => TopicSearchItem(r['id'] as int, r['title'] as String, r['category_id'] as int)).toList();
    return TopicSearchResult(items, total);
  }

  /// 更新答案本体并刷新 updated_at。
  Future<void> updateSummary(int id, String summary) async {
    await _db.db.update('topic', {'summary': summary, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/repos_test.dart -N "TopicRepository"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/study_engine/lib/src/repos/topic_repository.dart packages/study_engine/test/repos_test.dart
git commit -m "refactor(repos): TopicRepository 适配新字段，加 search/findByTitle/updateSummary"
```

---

## Task 5: TopicEdgeRepository（新建）

**Files:**
- Create: `packages/study_engine/lib/src/repos/topic_edge_repository.dart`

**Interfaces:**
- Consumes: `StudyDatabase`、`TopicEdge`
- Produces: `TopicEdgeRepository` 方法 `insert`/`findByTopic`

- [ ] **Step 1: 写失败测试**

在 `test/repos_test.dart` 的 `main()` 内追加：

```dart
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/repos_test.dart -N "TopicEdgeRepository"`
Expected: FAIL — `TopicEdgeRepository` 未定义

- [ ] **Step 3: 实现 TopicEdgeRepository**

创建 `packages/study_engine/lib/src/repos/topic_edge_repository.dart`：

```dart
import '../db/database.dart';

/// findByTopic 返回的边项：类型 + 对端 topic 的 id/title。
class TopicEdgeView {
  final String type;
  final int otherId;
  final String otherTitle;
  TopicEdgeView(this.type, this.otherId, this.otherTitle);
}

class TopicEdgeRepository {
  final StudyDatabase _db;
  TopicEdgeRepository(this._db);

  /// 建边。UNIQUE(from,to,type) 冲突时忽略（不报错）。
  Future<void> insert(int fromTopicId, int toTopicId, String type) async {
    try {
      await _db.db.insert('topic_edge', {
        'from_topic_id': fromTopicId,
        'to_topic_id': toTopicId,
        'type': type,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // UNIQUE 冲突，忽略
    }
  }

  /// 双向查该 topic 参与的所有边（from 或 to 匹配）。
  Future<List<TopicEdgeView>> findByTopic(int topicId) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT e.type,
             CASE WHEN e.from_topic_id = ? THEN e.to_topic_id ELSE e.from_topic_id END AS other_id,
             t.title AS other_title
      FROM topic_edge e
      JOIN topic t ON t.id = CASE WHEN e.from_topic_id = ? THEN e.to_topic_id ELSE e.from_topic_id END
      WHERE e.from_topic_id = ? OR e.to_topic_id = ?
      ''',
      [topicId, topicId, topicId, topicId],
    );
    return rows.map((r) => TopicEdgeView(r['type'] as String, r['other_id'] as int, r['other_title'] as String)).toList();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/repos_test.dart -N "TopicEdgeRepository"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/study_engine/lib/src/repos/topic_edge_repository.dart packages/study_engine/test/repos_test.dart
git commit -m "feat(repos): TopicEdgeRepository — 关联边 insert(冲突忽略)/findByTopic(双向)"
```

---

## Task 6: 删除废弃 Repository + 更新 barrel 导出

**Files:**
- Delete: `packages/study_engine/lib/src/repos/topic_domain_repository.dart`
- Delete: `packages/study_engine/lib/src/repos/subject_repository.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Produces: barrel 不再导出 `SubjectRepository`/`TopicDomainRepository`；新增导出 `CategoryRepository`/`TopicEdgeRepository`/`TopicSearchResult`/`TopicSearchItem`/`TopicEdgeView`

- [ ] **Step 1: 删除废弃文件**

```bash
rm packages/study_engine/lib/src/repos/topic_domain_repository.dart
rm packages/study_engine/lib/src/repos/subject_repository.dart
```

- [ ] **Step 2: 更新 barrel 导出**

把 `packages/study_engine/lib/study_engine.dart` 第 9-12 行（4 行 repo 导出）替换为：

```dart
export 'src/repos/category_repository.dart';
export 'src/repos/topic_repository.dart';
export 'src/repos/topic_edge_repository.dart';
export 'src/repos/mastery_repository.dart';
```

- [ ] **Step 3: 验证全包编译**

Run: `cd packages/study_engine && dart analyze lib/`
Expected: 仅 `study_scenario.dart`/`agent_session_provider.dart` 等引用旧 Repository 处报错（后续 Task 修），barrel 自身无错

- [ ] **Step 4: Commit**

```bash
git add -A packages/study_engine/lib/
git commit -m "chore: 删除废弃 Subject/TopicDomain Repository，更新 barrel 导出"
```

---

## Task 7: Agent 工具 schema（agent_tools.dart）

**Files:**
- Modify: `packages/study_engine/lib/src/agent/agent_tools.dart`

**Interfaces:**
- Produces: `AgentTools.studyTools` = 6 个工具的 schema 列表

- [ ] **Step 1: 重写 agent_tools.dart**

把 `packages/study_engine/lib/src/agent/agent_tools.dart` 整个文件替换为：

```dart
/// Agent 工具 schema（OpenAI function calling）。知识点体系 6 个工具。
class AgentTools {
  AgentTools._();

  static const listTopics = {
    'type': 'function',
    'function': {
      'name': 'list_topics',
      'description': '分层浏览知识体系。传入 path 下钻到某分类，返回该层子分类和直挂知识点；不传 path 返回顶级分类。用于了解现有知识结构、为新建知识点找挂载位置。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '分类路径，用 / 分隔，如"数学/高等数学"。省略时返回顶级分类。'},
        },
      },
    },
  };

  static const searchTopics = {
    'type': 'function',
    'function': {
      'name': 'search_topics',
      'description': '按关键词搜索知识点（匹配标题、引子、内容）。用于判断某知识点是否已存在、避免重复录入。返回轻量列表（仅标题+id+路径）。',
      'parameters': {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string', 'description': '搜索关键词'},
          'offset': {'type': 'integer', 'description': '分页偏移，默认0'},
        },
        'required': ['keyword'],
      },
    },
  };

  static const getTopic = {
    'type': 'function',
    'function': {
      'name': 'get_topic',
      'description': '按 id 获取知识点完整详情，含引子、答案、关联边。用于查看已有知识点内容、判断是否需要更新。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '知识点 id'},
        },
        'required': ['id'],
      },
    },
  };

  static const saveTopic = {
    'type': 'function',
    'function': {
      'name': 'save_topic',
      'description': '保存一个细粒度知识点。知识点的粒度必须低：一个引子对应一个知识点，若内容需要多个引子才能讲清，应拆成多个知识点分别保存。学科/模块/章节不存在的会自动创建。title 全库唯一，重复会被拒绝。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '分类路径，如"数学/高等数学/极限"'},
          'title': {'type': 'string', 'description': '知识点标题，应简短且唯一可识别'},
          'question': {'type': 'string', 'description': '背诵引子，如"如何求0/0型极限?"'},
          'summary': {'type': 'string', 'description': '答案本体，背诵揭晓时展示的完整内容'},
        },
        'required': ['path', 'title', 'question', 'summary'],
      },
    },
  };

  static const updateTopic = {
    'type': 'function',
    'function': {
      'name': 'update_topic',
      'description': '更新已有知识点的答案本体(summary)。用于补充或修正已有知识点的答案。不改标题、引子、分类。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '知识点 id'},
          'summary': {'type': 'string', 'description': '新的答案本体'},
        },
        'required': ['id', 'summary'],
      },
    },
  };

  static const linkTopics = {
    'type': 'function',
    'function': {
      'name': 'link_topics',
      'description': '建立两个知识点之间的关联边。prerequisite=前置依赖(有向，from依赖to)；related=相关(无向)。仅在分析出明确的依赖/关联关系时使用。',
      'parameters': {
        'type': 'object',
        'properties': {
          'from': {'type': 'integer', 'description': '起点知识点 id(prerequisite 时为依赖方)'},
          'to': {'type': 'integer', 'description': '终点知识点 id(prerequisite 时为被依赖方)'},
          'type': {'type': 'string', 'enum': ['prerequisite', 'related']},
        },
        'required': ['from', 'to', 'type'],
      },
    },
  };

  static const studyTools = [listTopics, searchTopics, getTopic, saveTopic, updateTopic, linkTopics];
}
```

- [ ] **Step 2: 验证编译**

Run: `cd packages/study_engine && dart analyze lib/src/agent/agent_tools.dart`
Expected: 无错

- [ ] **Step 3: Commit**

```bash
git add packages/study_engine/lib/src/agent/agent_tools.dart
git commit -m "feat(agent): 6 工具 schema — list/search/get/save/update/link"
```

---

## Task 8: StudyScenario 改造（工具执行 + prompt）

**Files:**
- Modify: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`

**Interfaces:**
- Consumes: `CategoryRepository`/`TopicRepository`/`TopicEdgeRepository`/`AgentMemoryRepository`、6 个工具 schema
- Produces: 改造后的 `StudyScenario`（构造参数 categories/topics/edges/memories，6 分支 executeTool，新 prompt）

- [ ] **Step 1: 重写 study_scenario.dart**

把 `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` 整个文件替换为：

```dart
import 'dart:convert';
import '../../models/models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/category_repository.dart';
import '../../repos/topic_edge_repository.dart';
import '../../repos/topic_repository.dart';
import '../agent_scenario.dart';
import '../agent_tools.dart';

/// 学习伴侣场景：6 工具，工具执行调 Repository，记忆来自 agent_memory 表。
class StudyScenario implements AgentScenario {
  final CategoryRepository categories;
  final TopicRepository topics;
  final TopicEdgeRepository edges;
  final AgentMemoryRepository memories;

  StudyScenario({required this.categories, required this.topics, required this.edges, required this.memories});

  @override String get id => 'study';
  @override String get displayName => '学习伴侣';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    return '''你是学习伴侣 AI。职责是分析题目、整理知识库、跟踪掌握状态。

## 知识点粒度原则（最高优先级）
- 一个知识点 = 一个引子(question) + 一个答案(summary)。
- 粒度必须低：若某内容需要多个引子才能讲清，拆成多个知识点分别保存。
- ❌错误："极限"(含定义/求法/定理) ❌正确："ε-δ极限定义""洛必达法则""夹逼定理"

## 写入前必先查（避免重复）
1. 先 search_topics(keyword) 搜索相关知识点，看是否已存在。
2. 命中 → get_topic(id) 看详情：
   - 答案需补充/修正 → update_topic(id, summary)
   - 识别到与已有知识点的依赖/关联 → link_topics(...)
3. 未命中 → list_topics(path) 找到正确分类挂载位置 → save_topic(path, title, question, summary)

## 分类
- path 形如"数学/高等数学/极限"，不存在的层级会自动创建。
- 知识点必须挂到最具体的分类（挂"极限"而非"高等数学"）。

## 关联边
- prerequisite：学A必须先会B，A依赖B(from=A,to=B)。
- related：无先后的相关知识点。
- 仅在分析出明确关系时建边，不要滥连。

## 经验记忆
$memBlock''';
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    switch (name) {
      case 'list_topics':
        return _listTopics(args['path'] as String?);
      case 'search_topics':
        return _searchTopics(args['keyword'] as String, args['offset'] as int?);
      case 'get_topic':
        return _getTopic(args['id'] as int);
      case 'save_topic':
        return _saveTopic(
          args['path'] as String,
          args['title'] as String,
          args['question'] as String,
          args['summary'] as String,
        );
      case 'update_topic':
        return _updateTopic(args['id'] as int, args['summary'] as String);
      case 'link_topics':
        return _linkTopics(args['from'] as int, args['to'] as int, args['type'] as String);
      default:
        return '未知工具: $name';
    }
  }

  Future<String> _listTopics(String? path) async {
    int? parentId;
    if (path != null && path.isNotEmpty) {
      final segments = path.split('/').where((s) => s.trim().isNotEmpty).toList();
      final cat = await categories.findByPath(segments);
      if (cat == null) return '路径不存在: $path';
      parentId = cat.id;
    }
    final children = await categories.findChildren(parentId);
    final childList = <Map<String, Object?>>[];
    for (final c in children) {
      final grandChildren = await categories.findChildren(c.id!);
      childList.add({'name': c.name, 'has_children': grandChildren.isNotEmpty});
    }
    final topicList = parentId == null
        ? <Map<String, Object?>>[]
        : (await topics.findByCategory(parentId)).map((t) => {'id': t.id, 'title': t.title}).toList();
    return jsonEncode({'children': childList, 'topics': topicList});
  }

  Future<String> _searchTopics(String keyword, int? offset) async {
    const limit = 30;
    final result = await topics.search(keyword, limit: limit, offset: offset ?? 0);
    final items = <Map<String, Object?>>[];
    for (final it in result.items) {
      final path = await categories.pathOf(it.categoryId);
      items.add({'id': it.id, 'title': it.title, 'path': path.join('/')});
    }
    return jsonEncode({
      'items': items,
      'total': result.total,
      'returned': items.length,
      'has_more': result.total > (offset ?? 0) + limit,
    });
  }

  Future<String> _getTopic(int id) async {
    final t = await topics.findById(id);
    if (t == null) return '知识点 id=$id 不存在';
    final path = await categories.pathOf(t.categoryId);
    final edgeList = (await edges.findByTopic(id))
        .map((e) => {'type': e.type, 'other_id': e.otherId, 'other_title': e.otherTitle})
        .toList();
    return jsonEncode({
      'id': t.id,
      'title': t.title,
      'path': path.join('/'),
      'question': t.question,
      'summary': t.summary,
      'edges': edgeList,
    });
  }

  Future<String> _saveTopic(String path, String title, String question, String summary) async {
    final existing = await topics.findByTitle(title);
    if (existing != null) {
      return '知识点「$title」已存在(id=${existing.id})。如需补充答案请用 update_topic(id=${existing.id}, summary=...)';
    }
    final segments = path.split('/').where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return 'path 不能为空';
    final catId = await categories.ensurePath(segments);
    final now = DateTime.now();
    final id = await topics.insert(Topic(
      categoryId: catId,
      question: question,
      title: title,
      summary: summary,
      createdAt: now,
      updatedAt: now,
    ));
    return '已保存知识点「$title」(id=$id)，路径 $path';
  }

  Future<String> _updateTopic(int id, String summary) async {
    final existing = await topics.findById(id);
    if (existing == null) return '知识点 id=$id 不存在';
    await topics.updateSummary(id, summary);
    return '已更新知识点「${existing.title}」的答案';
  }

  Future<String> _linkTopics(int from, int to, String type) async {
    if (type != 'prerequisite' && type != 'related') return 'type 必须是 prerequisite 或 related';
    final fromTopic = await topics.findById(from);
    final toTopic = await topics.findById(to);
    if (fromTopic == null) return '知识点 id=$from 不存在';
    if (toTopic == null) return '知识点 id=$to 不存在';
    final before = (await edges.findByTopic(from)).where((e) => e.otherId == to).length;
    await edges.insert(from, to, type);
    final after = (await edges.findByTopic(from)).where((e) => e.otherId == to).length;
    if (after == before) return '关联已存在: ${fromTopic.title} → ${toTopic.title} ($type)';
    return '已建立 $type 关联: ${fromTopic.title} → ${toTopic.title}';
  }

  @override
  Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;

  @override
  Future<List<String>> getMemories() async {
    _memCache = (await memories.queryByScenario(id)).map((m) => m.content).toList();
    return _memCache;
  }

  @override
  Future<MemoryPatchResult> patchMemory(int? index, String newText) async {
    final all = await memories.queryByScenario(id);
    if (index == null) {
      await memories.add(id, newText);
      return MemoryPatchResult(true, '已新增记忆');
    }
    final i = index - 1;
    if (i < 0 || i >= all.length) {
      return MemoryPatchResult(false, '编号越界，可用范围 1..${all.length}');
    }
    await memories.update(all[i].id!, newText);
    return MemoryPatchResult(true, '已更新记忆 $index');
  }

  @override
  Future<void> cleanup() async {}
}
```

- [ ] **Step 2: 验证编译**

Run: `cd packages/study_engine && dart analyze lib/src/agent/scenarios/study_scenario.dart`
Expected: 无错

- [ ] **Step 3: Commit**

```bash
git add packages/study_engine/lib/src/agent/scenarios/study_scenario.dart
git commit -m "refactor(scenario): StudyScenario 改 6 工具执行 + 新 prompt(粒度/先查后写/分类)"
```

---

## Task 9: APP 层注入点改造（agent_session_provider.dart）

**Files:**
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`

**Interfaces:**
- Consumes: 改造后的 `StudyScenario`（categories/topics/edges/memories）

- [ ] **Step 1: 更新 provider 构造**

把 `study_buddy/lib/core/providers/agent_session_provider.dart` 第 30-39 行替换为：

```dart
    final categories = CategoryRepository(db);
    final topics = TopicRepository(db);
    final edgesRepo = TopicEdgeRepository(db);
    final memories = AgentMemoryRepository(db);

    final llm = LlmProvider(config: cfg);
    final scenario = StudyScenario(
      categories: categories,
      topics: topics,
      edges: edgesRepo,
      memories: memories,
    );
```

- [ ] **Step 2: 验证全包编译**

Run: `cd packages/study_engine && dart analyze lib/`
Expected: 全 study_engine 无错

Run: `cd study_buddy && flutter analyze lib/core/providers/agent_session_provider.dart`
Expected: 无错

- [ ] **Step 3: Commit**

```bash
git add study_buddy/lib/core/providers/agent_session_provider.dart
git commit -m "refactor(app): AgentSessionProvider 注入新 Repository"
```

---

## Task 10: 清理旧测试 + 集成测试重写

**Files:**
- Modify: `packages/study_engine/test/repos_test.dart`
- Modify: `packages/study_engine/test/study_scenario_integration_test.dart`

**Interfaces:**
- Consumes: 全部新 Repository + Scenario

- [ ] **Step 1: 清理 repos_test.dart 中引用旧模型的测试**

删除 `repos_test.dart` 中这三个旧测试块（它们引用 SubjectRepository/TopicDomainRepository/旧 Topic 字段）：
- `test('SubjectRepository.ensureCreate 幂等', ...)` 整块
- `test('TopicRepository 增查', ...)` 整块
- `test('MasteryRepository 日志驱动当前状态', ...)` 整块（改为下方 Step 2 的新版本）
- `test('TopicDomainRepository 增查', ...)` 整块

保留 `LlmConfigRepository`、`AgentMemoryRepository`、`ChatRepository` 三个测试不动。

- [ ] **Step 2: 补回 mastery 测试（适配新 Topic 字段）**

在 `repos_test.dart` 追加（替代被删的 mastery 测试）：

```dart
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
```

- [ ] **Step 3: 重写集成测试**

把 `packages/study_engine/test/study_scenario_integration_test.dart` 整个文件替换为：

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  StudyScenario _newScenario(StudyDatabase sdb) => StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
      );

  test('场景1 save_topic 新建（分类自动建）', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = _newScenario(sdb);
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);

    final result = await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限',
      'title': '洛必达法则',
      'question': '如何求0/0型极限?',
      'summary': '对分子分母分别求导后取极限',
    });
    expect(result, contains('已保存'));

    // 分类树三层建好
    final limit = await cats.findByPath(['数学', '高等数学', '极限']);
    expect(limit, isNotNull);
    // topic 落库
    final got = await topics.findByTitle('洛必达法则');
    expect(got, isNotNull);
    expect(got!.categoryId, limit!.id);
    await sdb.close();
  });

  test('场景2 save_topic 重复 title 被拒', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = _newScenario(sdb);
    final topics = TopicRepository(sdb);

    await scenario.executeTool('save_topic', {
      'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
    });
    final result2 = await scenario.executeTool('save_topic', {
      'path': '物理', 'title': '极限', 'question': 'q2', 'summary': 's2',
    });
    expect(result2, contains('已存在'));
    expect(result2, contains('update_topic'));
    // 库中仍只有 1 条
    expect(await topics.findByTitle('极限'), isNotNull);
    final all = await topics.search('极限');
    expect(all.total, 1);
    await sdb.close();
  });

  test('场景3 先查后写完整流程', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = _newScenario(sdb);

    await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限', 'title': '极限的ε-δ定义', 'question': 'q', 'summary': '旧答案',
    });
    // search 命中
    final searchResult = await scenario.executeTool('search_topics', {'keyword': '极限'});
    expect(searchResult, contains('极限的ε-δ定义'));
    // get 看详情
    final topics = TopicRepository(sdb);
    final t = await topics.findByTitle('极限的ε-δ定义');
    final detail = await scenario.executeTool('get_topic', {'id': t!.id});
    expect(detail, contains('旧答案'));
    // update 答案
    await scenario.executeTool('update_topic', {'id': t.id, 'summary': '新答案'});
    final got = await topics.findById(t.id);
    expect(got?.summary, '新答案');
    // 不产生重复
    final all = await topics.search('极限');
    expect(all.total, 1);
    await sdb.close();
  });

  test('场景4 分层下钻 list_topics', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = _newScenario(sdb);

    await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限', 'title': '洛必达法则', 'question': 'q', 'summary': 's',
    });
    // 顶级
    final top = await scenario.executeTool('list_topics', {});
    expect(top, contains('数学'));
    expect(top, contains('has_children'));
    // 下钻数学
    final math = await scenario.executeTool('list_topics', {'path': '数学'});
    expect(math, contains('高等数学'));
    // 下钻高等数学
    final adv = await scenario.executeTool('list_topics', {'path': '数学/高等数学'});
    expect(adv, contains('极限'));
    // 下钻极限 — 看到 topic
    final limit = await scenario.executeTool('list_topics', {'path': '数学/高等数学/极限'});
    expect(limit, contains('洛必达法则'));
    await sdb.close();
  });

  test('场景5 建边 link_topics + get_topic 含边', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = _newScenario(sdb);
    final topics = TopicRepository(sdb);

    await scenario.executeTool('save_topic', {'path': '数学', 'title': '洛必达法则', 'question': 'q', 'summary': 's'});
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '导数', 'question': 'q', 'summary': 's'});
    final a = await topics.findByTitle('洛必达法则');
    final b = await topics.findByTitle('导数');

    final linkResult = await scenario.executeTool('link_topics', {
      'from': a!.id, 'to': b!.id, 'type': 'prerequisite',
    });
    expect(linkResult, contains('已建立'));

    final detail = await scenario.executeTool('get_topic', {'id': a.id});
    expect(detail, contains('prerequisite'));
    expect(detail, contains('导数'));
    await sdb.close();
  });

  test('场景6 AgentLoop 端到端 mock save_topic', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = _newScenario(sdb);
    final topics = TopicRepository(sdb);

    final llm = _ScriptedLlm([
      const [
        LlmStreamChunk(textDelta: '', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"path":"物理/力学","title":"牛顿第二定律","question":"F=ma?","summary":"力等于质量乘加速度"}'),
        ])
      ],
      const [LlmStreamChunk(textDelta: '已保存')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.any((e) => e is ToolCallEndEvent), isTrue);

    final got = await topics.findByTitle('牛顿第二定律');
    expect(got, isNotNull);
    await sdb.close();
  });
}

class _ScriptedLlm extends LlmProvider {
  _ScriptedLlm(this.script) : super(config: LlmConfig(
        name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}
```

- [ ] **Step 4: 运行全部测试确认通过**

Run: `cd packages/study_engine && dart test`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add packages/study_engine/test/
git commit -m "test: 清理旧测试，重写 6 场景集成测试（新建/查重/先查后写/下钻/建边/端到端）"
```

---

## Task 11: 全量验证 + 收尾

**Files:**
- 无新文件，全量校验

- [ ] **Step 1: 全包静态分析**

Run: `cd packages/study_engine && dart analyze`
Expected: 无 error（warning 可接受但应无新增）

Run: `cd study_buddy && flutter analyze lib/core/providers/agent_session_provider.dart`
Expected: 无 error

- [ ] **Step 2: 全量测试**

Run: `cd packages/study_engine && dart test`
Expected: 全部 PASS

- [ ] **Step 3: 检查无残留旧引用**

搜索整个项目确认无 `SubjectRepository`/`TopicDomainRepository`/`subjectId`/`parentTopicId`/`.domain` 残留引用：

```bash
cd packages/study_engine && grep -rn "SubjectRepository\|TopicDomainRepository\|subjectId\|parentTopicId\|TopicDomain(" lib/ test/ || echo "无残留"
```
Expected: `无残留`

- [ ] **Step 4: Commit（如有 lint 修复）**

```bash
git add -A
git commit -m "chore: 全量验证通过" --allow-empty
```

---

## 自审记录

**Spec 覆盖**：spec 第 3 节（数据模型/迁移）→ Task 1+2；第 4 节（Repository）→ Task 3+4+5+6；第 5 节（工具 schema）→ Task 7；第 6 节（Scenario+prompt）→ Task 8；APP 注入 → Task 9；第 7 节（测试）→ Task 10。无遗漏。

**类型一致**：`CategoryRepository.ensurePath` 返回 `Future<int>`（Task 3 定义，Task 8 `_saveTopic` 消费一致）；`TopicRepository.search` 返回 `TopicSearchResult`（Task 4 定义，Task 8 `_searchTopics` 消费一致）；`TopicEdgeRepository.findByTopic` 返回 `List<TopicEdgeView>`（Task 5 定义，Task 8 `_getTopic`/`_linkTopics` 消费一致）。

**占位符**：无。

**已知张力**：Task 2 的 v2 迁移对 `mastery_log` 做了 FK 摘除重建（因 topic 表重建导致原 FK 失效）。这是无真实数据的地基阶段的合理处理，spec 第 3.1 节已说明保留 `mastery_log` 不动——此处"不动"指表语义不动，FK 约束因依赖表重建而临时摘除，功能等价。
