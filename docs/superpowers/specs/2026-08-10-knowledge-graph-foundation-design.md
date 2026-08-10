# 知识点管理体系重设计 — 分类树 + 知识图骨架

- **日期**: 2026-08-10
- **项目**: study_buddy（Flutter 学习伴侣 APP）
- **阶段**: 知识点体系重设计（地基阶段的演进）
- **状态**: 已确认，待实施计划

## 1. 背景与目标

### 1.1 问题

地基阶段（见 `2026-08-06-study-buddy-foundation-design.md`）建立了知识点的最小数据闭环：AI 通过 `save_topic`/`query_topics` 存查知识点。但探索发现四个根本缺陷：

1. **结构断裂**：知识点只有扁平 `domain` 字符串做分组，无层级。无法表达「数学→高等数学→极限→洛必达法则」这种常识结构。
2. **无查重机制**：`save_topic` 直接写库，DB 无唯一约束，prompt 仅一句软引导。AI 实际无法知道知识点是否已存在，重复录入不可避免。
3. **`topic_domain` 表孤立**：建了表和 Repository，但 `save_topic` 不写它，永远是空表。
4. **无背诵能力**：知识点只有 `summary` 描述，无「引子→回忆→揭晓」的主动回忆机制。

### 1.2 本 spec 目标

重构知识点管理体系，建立**写入侧闭环**：让 AI 能往一个有效的树形体系里，存带引子的细粒度知识点，能下钻巡视、精准定位、按需更新、建立关联，从源头替代脆弱的事后去重。

### 1.3 非目标（推到后续 spec）

| 推后项 | 理由 |
|---|---|
| 消费侧 UI（背诵卡片、知识树浏览、图可视化） | 独立大块，本次是写入侧闭环 |
| 掌握度激活（`mastery_log` 写入触发点） | 现状死代码，背诵+复习机制是另一话题 |
| 题目（Question）实体与知识点关联 | spec 已列为后续子项目 |
| `save_topic` 内部查重的进一步演进（语义去重） | 本次用 title 唯一约束 + 工具内查重，够用 |

## 2. 设计输入（已确认决策）

| 维度 | 决策 |
|---|---|
| 结构形态 | 分类树骨架（分类节点 + 知识点叶子，分表）→ 图为演进目标。本次建树骨架 + 知识点关联边（图的基础能力） |
| 图的边类型 | 仅 `prerequisite`（有向，前置依赖）+ `related`（无向，相关）两种 |
| 知识点粒度 | 强制细粒度：一个引子对应一个知识点。内容需多个引子则拆多个知识点 |
| 内容模型 | `Topic` 加 `question`（**必填**，引子）+ `summary` 改**必填**（答案本体，背诵揭晓内容） |
| 概览工具形态 | 分层下钻（`list_topics(path)`），结构化返回 `{children, topics}`，非无参全量 |
| 量级前提 | 千级知识点、跨学科。推翻「无参全量返回」假设 |
| 更新能力 | `update_topic(id, summary)` 仅更新答案，不改 title/分类/引子 |
| 建边方式 | 独立工具 `link_topics`，不绑死 `save_topic`，控制 AI 归类负担 |
| 查重策略 | `save_topic` 内部按 title 全库查重；命中则拒绝并提示 AI 改用 `update_topic`（方案 A） |
| title 唯一性 | **全库唯一**（跨学科），同名细粒度知识点用前缀区分（如「物理·向量」「数学·向量」） |
| 搜索范围 | `search_topics` 匹配 title + question + summary 三字段 |
| 搜索实现 | SQLite `LIKE '%kw%'` 子串匹配，不引入 FTS |
| 搜索分页 | 默认限量（30）+ `total`/`has_more` 提示剩余 |
| 边详情返回 | `get_topic` 返回该 topic 参与的所有边（扁平列表，不区分方向），AI 凭 type 理解 |
| 边删除级联 | `ON DELETE CASCADE`，删知识点连带删边，避免孤儿 |
| 扁平 domain | 废弃（`Topic.domain` 字段 + `topic_domain` 表），干净重建 |
| 学科归宿 | `subject` 表并入 `category` 顶级节点，整个体系统一为一棵树 |

### 2.1 为什么树为骨架、图为演进（不直接上纯图）

纯图（一切皆节点、一切关系皆边）表达力最强，但对「AI 边分析题目边归档」这个高频写场景，归类负担过重（每次存知识点要决定连哪些边、边的类型）。

分类树只表达 `belongs_to`（归属）一种关系，AI 归类只需「给知识点选一个挂载分类」，负担可控。在此之上加一张关联边表，即获得 `prerequisite`/`related` 两种关系，演化为图。

**关键**：分类树是图的子集（只有 belongs_to 边的图就是树）。本次建树骨架 + 关联边，不推翻、不返工，后续加更多边类型或消费侧图可视化都是增量。

## 3. 数据模型与数据库迁移

### 3.1 表结构（v2 迁移）

**废弃**：`Topic.domain` 字段、`topic_domain` 表。地基阶段无真实数据，干净重建。`subject` 表数据并入 `category` 顶级节点。

**新增/改造 4 张表**：

```sql
-- 分类节点表（自引用树，承载 学科→模块→章节）
CREATE TABLE category (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id INTEGER,                    -- 自引用，顶级分类为 NULL
  name TEXT NOT NULL,                   -- 如"数学""高等数学""极限"
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (parent_id) REFERENCES category(id) ON DELETE RESTRICT
);
CREATE INDEX idx_category_parent ON category(parent_id);

-- 知识点表（改造：废弃 domain，加 question，挂 category）
CREATE TABLE topic (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL,         -- 挂载到分类节点（替代原 subject_id+domain）
  question TEXT NOT NULL,               -- 必填：背诵引子
  title TEXT NOT NULL UNIQUE,           -- 知识点标题，全库唯一
  summary TEXT NOT NULL,                -- 答案本体（背诵揭晓内容），必填
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,          -- 新增：update_topic 用
  FOREIGN KEY (category_id) REFERENCES category(id)
);
CREATE INDEX idx_topic_category ON topic(category_id);

-- 知识点关联边表（图：知识点间横向/纵向关系）
CREATE TABLE topic_edge (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_topic_id INTEGER NOT NULL,
  to_topic_id INTEGER NOT NULL,
  type TEXT NOT NULL,                   -- 'prerequisite'（有向）| 'related'（无向）
  created_at INTEGER NOT NULL,
  FOREIGN KEY (from_topic_id) REFERENCES topic(id) ON DELETE CASCADE,
  FOREIGN KEY (to_topic_id) REFERENCES topic(id) ON DELETE CASCADE,
  UNIQUE(from_topic_id, to_topic_id, type)  -- 防重复边
);
CREATE INDEX idx_topic_edge_from ON topic_edge(from_topic_id);
CREATE INDEX idx_topic_edge_to ON topic_edge(to_topic_id);
```

**保留不动**：`mastery_log`（死代码，后续掌握度激活）、`agent_memory`。

`kCurrentDbVersion` 1 → 2。

### 3.2 模型类（models.dart）

```dart
class Category {
  final int? id;
  final int? parentId;
  final String name;
  final int sortOrder;
  final DateTime createdAt;
  // fromMap / toMap 略
}

class Topic {
  final int? id;
  final int categoryId;      // 替代原 subjectId + parentTopicId + domain
  final String question;     // 必填（原无）
  final String title;
  final String summary;      // 改必填（原可选）
  final DateTime createdAt;
  final DateTime updatedAt;  // 新增
}

class TopicEdge {
  final int? id;
  final int fromTopicId;
  final int toTopicId;
  final String type;         // 'prerequisite' | 'related'
  final DateTime createdAt;
}
```

**废弃**：`TopicDomain` 类。`Subject` 类标记 deprecated（过渡期保留，迁移用）。

## 4. Repository 层

沿用手写 SQL + sqflite helper 风格（和现有 `TopicRepository` 一致）。

### 4.1 CategoryRepository（新增）

| 方法 | 用途 | 服务于 |
|---|---|---|
| `ensurePath(List<String> segments)` | 逐级创建分类，已存在则跳过，返回末端 category id | `save_topic` |
| `findByPath(List<String> segments)` | 按 name 逐级下钻，返回末端 category 或 null | `list_topics` |
| `findChildren(int? parentId)` | 返回直接子分类（parent_id=NULL 时返回顶级） | `list_topics` |
| `pathOf(int categoryId)` | 向上回溯到根，返回完整路径段列表 | `search`/`get_topic` 重建可读 path |

**`ensurePath` 行为**：传 `["数学","高等数学","极限"]`，逐级查/建——「数学」不存在则建顶级节点，「高等数学」挂数学下，「极限」挂高等数学下。取代原 `SubjectRepository.ensureCreate`，支持多级。`save_topic` 每次走 ensurePath，分类随知识点自然生长，AI 无需单独「建分类」工具。

### 4.2 TopicRepository（改造）

| 方法 | 用途 | 服务于 |
|---|---|---|
| `insert(Topic t)` | 插入（question+summary 必填） | `save_topic` |
| `findById(int id)` | 取单条 | `get_topic` |
| `findByCategory(int categoryId)` | 返回某分类直挂知识点（仅 id+title） | `list_topics` |
| `findByTitle(String title)` | 精确匹配 title（全库唯一的基础） | `save_topic` 查重 |
| `search(String keyword, {int limit, int offset})` | 跨 title+question+summary LIKE 匹配，返回 `(items, totalCount)` | `search_topics` |
| `updateSummary(int id, String summary)` | 更新 summary + 刷新 updated_at | `update_topic` |

**`search` SQL 思路**：
```sql
-- items
SELECT id, title, category_id FROM topic
WHERE title LIKE ? OR question LIKE ? OR summary LIKE ?
LIMIT ? OFFSET ?;
-- totalCount（用于"还有 N 条未展示"）
SELECT COUNT(*) FROM topic
WHERE title LIKE ? OR question LIKE ? OR summary LIKE ?;
```
items 拿到 `category_id` 后调 `CategoryRepository.pathOf` 重建可读路径。

### 4.3 TopicEdgeRepository（新增）

| 方法 | 用途 | 服务于 |
|---|---|---|
| `insert(int from, int to, String type)` | 插入边（UNIQUE 约束防重复，冲突时忽略） | `link_topics` |
| `findByTopic(int topicId)` | 双向查该 topic 参与的所有边（from 或 to 匹配） | `get_topic` |

**`findByTopic` 返回**：该 topic 参与的所有边，每条带 `type` + 对端 topic 的 `id`+`title`。不在此层区分「我依赖谁 vs 谁依赖我」，AI 凭 type 和上下文理解（prerequisite 有向、related 无向）。

```sql
SELECT e.type, e.from_topic_id, e.to_topic_id,
       t.id AS other_id, t.title AS other_title
FROM topic_edge e
JOIN topic t ON t.id = CASE WHEN e.from_topic_id=? THEN e.to_topic_id ELSE e.from_topic_id END
WHERE e.from_topic_id=? OR e.to_topic_id=?;
```

### 4.4 废弃

- `SubjectRepository`、`TopicDomainRepository` —— 删除（domain 废弃、学科并入 category）
- `MasteryRepository` —— 保留不动（死代码，后续掌握度激活用）

## 5. Agent 工具 schema

6 个工具（`query_topics` 删除，被 `list_topics`+`search_topics` 取代）。5 只读查询 + 1 新建 + 1 更新 + 1 连边。

### 5.1 `list_topics` —— 分层下钻

```jsonc
{
  "name": "list_topics",
  "description": "分层浏览知识体系。传入 path 下钻到某分类，返回该层子分类和直挂知识点；不传 path 返回顶级分类。用于了解现有知识结构、为新建知识点找挂载位置。",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "分类路径，用 / 分隔，如\"数学/高等数学\"。省略时返回顶级分类。"
      }
    }
  }
}
```
**返回**：`{children: [{name, has_children}], topics: [{id, title}]}`。`has_children` 让 AI 知道该子分类能否继续下钻（避免无谓往返）。

### 5.2 `search_topics` —— 关键词搜索

```jsonc
{
  "name": "search_topics",
  "description": "按关键词搜索知识点（匹配标题、引子、内容）。用于判断某知识点是否已存在、避免重复录入。返回轻量列表（仅标题+id+路径）。",
  "parameters": {
    "type": "object",
    "properties": {
      "keyword": {"type": "string", "description": "搜索关键词"},
      "offset": {"type": "integer", "description": "分页偏移，默认0"}
    },
    "required": ["keyword"]
  }
}
```
**返回**：`{items: [{id, title, path}], total, returned, has_more}`。默认限量 30。

### 5.3 `get_topic` —— 看详情

```jsonc
{
  "name": "get_topic",
  "description": "按 id 获取知识点完整详情，含引子、答案、关联边。用于查看已有知识点内容、判断是否需要更新。",
  "parameters": {
    "type": "object",
    "properties": {
      "id": {"type": "integer", "description": "知识点 id"}
    },
    "required": ["id"]
  }
}
```
**返回**：`{id, title, path, question, summary, edges: [{type, other_id, other_title}]}`。边为该 topic 参与的所有边（扁平列表）。

### 5.4 `save_topic` —— 新建

```jsonc
{
  "name": "save_topic",
  "description": "保存一个细粒度知识点。知识点的粒度必须低：一个引子对应一个知识点，若内容需要多个引子才能讲清，应拆成多个知识点分别保存。学科/模块/章节不存在的会自动创建。title 全库唯一，重复会被拒绝。",
  "parameters": {
    "type": "object",
    "properties": {
      "path": {"type": "string", "description": "分类路径，如\"数学/高等数学/极限\""},
      "title": {"type": "string", "description": "知识点标题，应简短且唯一可识别"},
      "question": {"type": "string", "description": "背诵引子，如\"如何求0/0型极限?\""},
      "summary": {"type": "string", "description": "答案本体，背诵揭晓时展示的完整内容"}
    },
    "required": ["path", "title", "question", "summary"]
  }
}
```
**执行逻辑**：先 `findByTitle` 查重；命中则返回「知识点「{title}」已存在(id={id})。如需补充答案请用 update_topic(id={id}, summary=...)」并拒绝插入；未命中则 `ensurePath` 建分类 + `insert`。

### 5.5 `update_topic` —— 更新答案

```jsonc
{
  "name": "update_topic",
  "description": "更新已有知识点的答案本体(summary)。用于补充或修正已有知识点的答案。不改标题、引子、分类。",
  "parameters": {
    "type": "object",
    "properties": {
      "id": {"type": "integer", "description": "知识点 id"},
      "summary": {"type": "string", "description": "新的答案本体"}
    },
    "required": ["id", "summary"]
  }
}
```

### 5.6 `link_topics` —— 建关联边

```jsonc
{
  "name": "link_topics",
  "description": "建立两个知识点之间的关联边。prerequisite=前置依赖(有向，from依赖to)；related=相关(无向)。仅在分析出明确的依赖/关联关系时使用。",
  "parameters": {
    "type": "object",
    "properties": {
      "from": {"type": "integer", "description": "起点知识点 id(prerequisite 时为依赖方)"},
      "to": {"type": "integer", "description": "终点知识点 id(prerequisite 时为被依赖方)"},
      "type": {"type": "string", "enum": ["prerequisite", "related"]}
    },
    "required": ["from", "to", "type"]
  }
}
```
**返回**：边已存在（UNIQUE 冲突忽略）时返回「关联已存在」，否则「已建立 {type} 关联: {from_title} → {to_title}」。

### 5.7 工具集

```dart
static const studyTools = [
  listTopics, searchTopics, getTopic, saveTopic, updateTopic, linkTopics
];
```

## 6. Scenario 业务逻辑 + prompt 约束

### 6.1 StudyScenario 改造

构造函数注入 4 个 Repository（替代原 subjects+topics+memories）：

```dart
class StudyScenario implements AgentScenario {
  final CategoryRepository categories;
  final TopicRepository topics;
  final TopicEdgeRepository edges;
  final AgentMemoryRepository memories;
  // ...
}
```

### 6.2 executeTool 六个分支

- **`list_topics`**：`findByPath` 解析 path → `findChildren` + `findByCategory`，children 每个算 `has_children`，topics 仅 id+title。
- **`search_topics`**：`search(keyword, limit:30, offset)`，每条调 `pathOf` 重建 path，返回 items + total + has_more。
- **`get_topic`**：`findById` + `pathOf` + `findByTopic`，返回全字段 + 边。
- **`save_topic`**：`findByTitle` 查重 → 命中拒绝提示 update；未命中 `ensurePath` + `insert`。
- **`update_topic`**：`findById` 校验存在 → `updateSummary`。
- **`link_topics`**：校验 from/to 存在 → `insert`（UNIQUE 冲突忽略）。

### 6.3 prompt 约束

```dart
@override
String buildSystemPrompt(AgentScenarioContext ctx) {
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
```

prompt 三重约束：
1. **粒度**：正反例把「一引子一知识点」从规则变成可操作判断。
2. **先查后写**：编号流程 search→get→(update|save)，堵住「直接 save」漏洞。
3. **分类精度**：必须挂最具体分类，避免知识点堆在粗分类下。

### 6.4 查重的双层保证

- **硬保证**：`save_topic` 内部 `findByTitle` 查重 + DB `UNIQUE(title)` 约束，prompt 失效也不会产生重复 title。
- **软引导**：prompt 编号流程引导 AI 先 search 再 save，避免「save 被拒→重试」的往返浪费。

## 7. 测试策略

沿用现有测试风格（`packages/study_engine/test/`），轻量、聚焦数据正确性。

### 7.1 Repository 单元测试（repos_test.dart 扩展）

**CategoryRepository**：
- `ensurePath` 多级创建 + 幂等
- `findByPath` 逐级下钻正确，错误路径返回 null
- `pathOf` 向上回溯重建完整路径

**TopicRepository**：
- `search` 跨字段命中（title/question/summary 各一例）+ 分页（total/has_more）
- `findByTitle` 精确匹配
- `updateSummary` 更新 summary 并刷新 updated_at

**TopicEdgeRepository**：
- `insert` UNIQUE 冲突忽略
- `findByTopic` 双向查询正确

### 7.2 Scenario 集成测试（study_scenario_integration_test.dart 扩展）

mock LLM 注入工具调用序列，端到端验证：

- **场景1 新建（分类自动建）**：`save_topic(path="数学/高等数学/极限", ...)` → category 树三层 + topic 落库
- **场景2 重复 title 被拒**：连续两次同 title `save_topic` → 第二次返回「已存在」提示，库中仍 1 条
- **场景3 先查后写完整流程**：`search` → `get` → `update` → 验证不重复、summary 被覆盖
- **场景4 分层下钻**：`list_topics()` → `list_topics(path="数学")` → `list_topics(path="数学/高等数学")` → 验证 has_children
- **场景5 建边**：两次 `save_topic` + `link_topics(prerequisite)` → `get_topic` edges 含对端

### 7.3 不测的（YAGNI）

- prompt 约束的 LLM 遵守度（无法稳定单测，靠人工验收）
- 掌握度（死代码，不动）
- UI 层（本次不涉及）

## 8. 关键文件清单

| 改动 | 文件 |
|---|---|
| 模型 | `packages/study_engine/lib/src/models/models.dart` |
| 迁移 | `packages/study_engine/lib/src/db/database_migrations.dart`（v2） |
| DB 门面 | `packages/study_engine/lib/src/db/database.dart` |
| Repository | `packages/study_engine/lib/src/repos/{category,topic,topic_edge}_repository.dart`（新增/改造） |
| 工具 schema | `packages/study_engine/lib/src/agent/agent_tools.dart` |
| Scenario | `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` |
| 测试 | `packages/study_engine/test/repos_test.dart`、`study_scenario_integration_test.dart` |
| APP 层注入 | `study_buddy/lib/core/providers/agent_session_provider.dart`（构造新 Repository） |

## 9. 已知缺口（留 v3）

- **语义去重**：title 全库唯一只能防「标题完全相同」，无法防同义词（「二次方程求根」vs「一元二次方程」）。语义去重要 embedding，成本高，留 v3。
- **prompt 软约束遵守度**：硬保证已兜底重复 title，但 AI 是否每次都先 search 再 save 仍靠 LLM 自觉，靠人工验收。
