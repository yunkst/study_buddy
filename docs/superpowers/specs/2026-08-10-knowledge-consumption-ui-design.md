# 消费侧 UI — 浏览 / 搜索 / 背诵(间隔重复)

- **日期**: 2026-08-10
- **项目**: study_buddy（Flutter 学习伴侣 APP）
- **阶段**: 消费侧 UI（写入侧闭环完成后的消费闭环）
- **状态**: 已确认，待实施计划

## 1. 背景与目标

### 1.1 问题

写入侧闭环（见 `2026-08-10-knowledge-graph-foundation-design.md`）已落地：AI 能往分类树里存带引子的细粒度知识点。但 App 端**无任何消费入口**——首页只显示悬浮窗状态，用户无法浏览已存的知识点、无法背诵、无法搜索定位。知识点进库后即「黑箱」。

### 1.2 本 spec 目标

建立**消费侧闭环**：让用户在 App 内能

1. **浏览**：逐级下钻分类树，查看知识点详情（引子 + 答案 + 关联边）。
2. **搜索**：按关键词跨字段（标题/引子/答案）定位知识点。
3. **背诵**：基于间隔重复（SM-2 简化版）的记忆曲线复习——回顾今日新增或到期复习的知识点，三档自评反馈驱动下次抽取。

### 1.3 非目标（推到后续 spec）

| 推后项 | 理由 |
|---|---|
| 图可视化（依赖图谱） | 复杂度高，本次未纳入用户确认范围 |
| `mastery_log` 掌握度激活 | 仍死代码，背诵+掌握度是另一话题 |
| 复习推送通知 | 依赖系统能力，独立话题 |
| 从详情页发起单条背诵 | 背诵由队列驱动，单条背诵 YAGNI |
| 编辑/删除知识点 UI | 消费侧只读；编辑走 AI `update_topic` 工具 |
| `save_topic` 语义去重 | 留 v3 |

## 2. 设计输入（已确认决策）

| 维度 | 决策 |
|---|---|
| 功能范围 | 浏览 + 搜索 + 背诵（图可视化排除） |
| 背诵反馈粒度 | 三档：忘了 / 记得 / 轻松 |
| 背诵队列组织 | 两模式切换：今日新增 / 到期复习（不做随机抽查） |
| 记忆曲线算法 | 简化 SM-2（ease_factor × interval，三档映射） |
| 调度数据模型 | 新建 `review_schedule` 表（1:1 topic），不污染 topic |
| 调度初始化 | 懒初始化——agent 写入路径零改动，背诵时按需建 schedule |
| 首页导航 | 底部三 Tab：知识库 / 背诵 / 悬浮窗 |
| 树浏览形态 | 逐级下钻（每层一页，面包屑回退），非单页展开折叠 |
| 状态管理 | Riverpod，复用 `databaseProvider` |
| 消费侧权限 | 只读——不新增写入工具，编辑走 AI |

## 3. 引擎侧：间隔重复调度（study_engine）

### 3.1 数据库迁移 v3

新增 `review_schedule` 表（1:1 关联 topic）。`kCurrentDbVersion` 2 → 3。

```sql
CREATE TABLE review_schedule (
  topic_id         INTEGER PRIMARY KEY,       -- 1:1 topic，主键即外键
  ease_factor      REAL    NOT NULL DEFAULT 2.5,
  interval_days    INTEGER NOT NULL DEFAULT 0,
  next_review_at   INTEGER NOT NULL,          -- 毫秒时间戳
  review_count     INTEGER NOT NULL DEFAULT 0,
  last_reviewed_at INTEGER,                    -- 毫秒时间戳，首次为 NULL
  FOREIGN KEY (topic_id) REFERENCES topic(id) ON DELETE CASCADE
);
CREATE INDEX idx_review_schedule_next ON review_schedule(next_review_at);
```

**ON DELETE CASCADE**：删知识点连带删调度记录（避免孤儿）。依赖写入侧已启用的 `PRAGMA foreign_keys = ON`（`database.dart` onConfigure）。

**不改动**：`topic`/`category`/`topic_edge`/`mastery_log`/`agent_memory` 表结构；agent 工具 schema、`StudyScenario`、写入路径全部零改动。

### 3.2 模型类（models.dart 新增）

```dart
/// 间隔重复调度记录。1:1 关联 topic，懒初始化（首次背诵时建）。
class ReviewSchedule {
  final int topicId;            // 主键 = topic.id
  final double easeFactor;      // 难度系数，初始 2.5
  final int intervalDays;       // 当前间隔天数，首学为 0
  final DateTime nextReviewAt;  // 下次到期时间
  final int reviewCount;        // 已复习次数
  final DateTime? lastReviewedAt; // 最近一次复习时间，首次为 null
  const ReviewSchedule({
    required this.topicId,
    required this.easeFactor,
    required this.intervalDays,
    required this.nextReviewAt,
    required this.reviewCount,
    this.lastReviewedAt,
  });
  // fromMap / toMap
}

/// 背诵反馈三档。
enum ReviewFeedback { forgot, remembered, easy }
```

### 3.3 ReviewScheduleRepository（新增）

| 方法 | 用途 | 服务于 |
|---|---|---|
| `getByTopic(int topicId)` | 取调度记录，无则返回 null | 背诵卡片加载 |
| `upsert(ReviewSchedule s)` | 插入或更新（topic_id 主键） | 背诵反馈落地 |
| `findDue(DateTime now, {int limit = 200})` | `next_review_at <= now` 升序，限量 | 到期复习队列 |

注意：**今日新增不在此仓库**——它看 topic 的 `created_at` 而非 schedule（schedule 懒建，可能用户今天才第一次背昨天存的点），统一放 `ReviewQueueRepository`（见 3.5）。`startOfDay` 由调用方传入（本地时区当天 00:00 的毫秒时间戳）。todayNewQueue 会 LEFT JOIN 排除已建 schedule 的 topic——背过即移出今日新增，避免同会话二次 apply 导致 SM-2 interval 复合跳增。

### 3.4 SpacedRepetitionService（新增，纯函数无 DB）

核心算法，纯 Dart 可单测。输入旧 schedule + 反馈，输出新 schedule（`nextReviewAt` 基于 `now` 计算）。

```dart
class SpacedRepetitionService {
  /// 初始 ease。
  static const double kInitialEase = 2.5;
  static const double kMinEase = 1.3;
  static const double kMaxEase = 3.0;

  /// 首学记录（interval 0 → 首次反馈后落地）。
  static ReviewSchedule initial(int topicId, DateTime now) => ReviewSchedule(
        topicId: topicId,
        easeFactor: kInitialEase,
        intervalDays: 0,
        nextReviewAt: now,          // 立即可背
        reviewCount: 0,
        lastReviewedAt: null,
      );

  /// 应用反馈，返回新 schedule。now 为当前时间（调用方传入，便于测试）。
  static ReviewSchedule apply(ReviewSchedule prev, ReviewFeedback feedback, DateTime now) {
    double ease = prev.easeFactor;
    int interval;
    switch (feedback) {
      case ReviewFeedback.forgot:
        ease = (ease - 0.2).clamp(kMinEase, kMaxEase).toDouble();
        interval = 1;
        break;
      case ReviewFeedback.remembered:
        interval = prev.intervalDays == 0
            ? 1                              // 首学记得：1 天后
            : (prev.intervalDays * ease).round();
        break;
      case ReviewFeedback.easy:
        interval = prev.intervalDays == 0
            ? 2                              // 首学轻松：2 天后
            : (prev.intervalDays * ease * 1.3).round(); // 先用旧 ease 算 interval
        ease = (ease + 0.1).clamp(kMinEase, kMaxEase).toDouble(); // 再 ease+0.1
        break;
    }
    interval = interval < 1 ? 1 : interval;  // 下限 1 天
    return ReviewSchedule(
      topicId: prev.topicId,
      easeFactor: ease,
      intervalDays: interval,
      nextReviewAt: now.add(Duration(days: interval)),
      reviewCount: prev.reviewCount + 1,
      lastReviewedAt: now,
    );
  }
}
```

**算法边界**：
- 首学（intervalDays=0）：记得→1 天，轻松→2 天，忘了→1 天（ease 降）。
- `clamp` 保证 ease ∈ [1.3, 3.0]。
- interval 下限 1 天（`round` 可能得 0 时兜底）。
- `now` 由调用方传入——测试可固定时间，生产用 `DateTime.now()`。

### 3.5 ReviewQueueRepository（新增）

组装「可背诵的 topic 列表」——join schedule + topic 返回带 title/question 的轻量项。两个方法对应两模式：

| 方法 | 返回 | 语义 |
|---|---|---|
| `dueQueue(DateTime now, {int limit = 200})` | `List<ReviewQueueItem>` | 到期复习：自建 JOIN 一次查询（schedule JOIN topic），升序，限量 |
| `todayNewQueue(DateTime startOfDay)` | `List<ReviewQueueItem>` | 今日新增：LEFT JOIN review_schedule 排除已建 schedule 的 topic，`created_at >= startOfDay`，按 created_at 升序 |

```dart
class ReviewQueueItem {
  final int topicId;
  final String title;
  final String question;
  ReviewQueueItem(this.topicId, this.title, this.question);
}

/// todayNewQueue SQL 思路（LEFT JOIN 排除已建 schedule 的 topic——背过即移出今日新增，
/// 避免「再来一轮」对同一卡二次 apply 导致 SM-2 interval 复合跳增）：
/// SELECT t.id, t.title, t.question
/// FROM topic t LEFT JOIN review_schedule s ON s.topic_id = t.id
/// WHERE t.created_at >= ? AND s.topic_id IS NULL
/// ORDER BY t.created_at ASC;
```

**懒初始化语义在此闭合**：`todayNewQueue` LEFT JOIN review_schedule 查 topic 表（覆盖无 schedule 的今日新增，已建 schedule 的自动移出）；`dueQueue` 自建 JOIN 查 `review_schedule.next_review_at`（依赖 schedule）。背诵卡片加载时：`getByTopic` 返回 null → 视为首学 → 用 `SpacedRepetitionService.initial` 构造内存中的初始 schedule → 反馈后 `apply` → `upsert` 落地。

### 3.6 barrel 导出

`study_engine.dart` 导出 `ReviewSchedule` / `ReviewFeedback` / `ReviewScheduleRepository` / `SpacedRepetitionService` / `ReviewQueueRepository` / `ReviewQueueItem`。

## 4. App 侧：三 Tab 导航与页面（study_buddy）

### 4.1 路由与导航

废弃单页 `HomePage`，改为 `MainShell`（底部三 Tab `NavigationBar`）：

```
/  → MainShell
     ├─ Tab 0: KnowledgeBasePage     (知识库)
     ├─ Tab 1: ReviewPage            (背诵)
     └─ Tab 2: OverlaySettingsPage   (悬浮窗，原 HomePage 内容平移)
/permission-guide → PermissionGuidePage (不变)
/topic/:id → TopicDetailPage         (详情，从知识库/搜索/关联边跳转)
```

`buildRouter` 增 `/topic/:id` 路由；`/` 指向 `MainShell`。

### 4.2 OverlaySettingsPage（悬浮窗 Tab）

原 `HomePage` 的悬浮窗状态、权限引导、检查更新逻辑**整体平移**到此页，无新逻辑。`PendingScreenshotStore` 消费仍在 `MainShell`/`app.dart` 层处理（首帧回调，与 Tab 无关）。

### 4.3 KnowledgeBasePage（知识库 Tab）

**布局**：顶部搜索框 + 列表。两种视图由搜索框是否聚焦/有输入切换：

- **浏览视图**（无输入）：面包屑（`数学 / 高等数学`，可点逐级回退，根级显示「全部」）+ 当前层列表。列表项混排：**子分类**（前置文件夹图标 + 名称 + `has_children` 指示）在前，**直挂知识点**（前置文档图标 + title）在后。点分类 push 下一层；点知识点跳 `/topic/:id`。
- **搜索视图**（有输入）：实时调 `TopicRepository.search`（防抖 300ms），列表项 = title + 路径（`CategoryRepository.pathOf` 重建），点进 `/topic/:id`。

**数据源**：复用引擎 Repository（`CategoryRepository.findChildren` / `findByPath` / `pathOf`、`TopicRepository.findByCategory` / `search`），不走 agent。某层列表用 `FutureProvider.family<int? parentId>`（null 表根级）。

**搜索触发**：搜索框 `onChanged` 防抖 300ms，**文本非空**时切搜索视图（不依赖聚焦）；清空回浏览视图。

**空状态**：库空 → 「知识库还是空的，用悬浮窗截图让 AI 帮你存知识点」；某分类空 → 「这个分类下还没有知识点」。

### 4.4 TopicDetailPage（详情页）

只读。布局：

- 标题（大字）
- 分类路径（面包屑式 `数学 / 高等数学 / 极限`，只读）
- 引子 question（「📖 引子」标签 + 大字）
- 答案 summary（「💡 答案」标签 + 正文，SelectableText 便于复制）
- 关联边（「🔗 关联」标签 + 列表，prerequisite 在前 related 在后；每条 `type + 对端 title`，可点跳对端 `/topic/:id`）

**数据源**：`TopicRepository.findById` + `CategoryRepository.pathOf` + `TopicEdgeRepository.findByTopic`。`FutureProvider.family<int topicId>`。

**无关联边**：隐藏「🔗 关联」区块（YAGNI 空文案）。

### 4.5 ReviewPage（背诵 Tab）

**布局**：顶部两模式切换（`今日新增` / `到期复习` `SegmentedButton`）+ 卡片区 + 底部统计。

**卡片流程**（状态机）：

```
[显示引子 question]
   ↓ 用户点「揭晓答案」
[显示答案 summary + 三档按钮：忘了 / 记得 / 轻松]
   ↓ 用户点某档
[apply 反馈 → upsert schedule → 加载下一张]
   ↓ 队列耗尽
[统计：共背 N / 记得 X / 忘了 Y / 轻松 Z + 「再来一轮」]
```

**状态**：
- `currentItem: ReviewQueueItem?` — 当前卡
- `revealed: bool` — 是否已揭晓
- `stats: (int remembered, int forgot, int easy)` — 本轮统计
- `mode: ReviewMode { todayNew, due }`

**加载逻辑**：进入模式时拉队列（`todayNewQueue` / `dueQueue`），取队首为 `currentItem`。反馈后从队列移除首项，取下一项；队空进统计态。

**反馈落地**：
1. `getByTopic(topicId)` 取旧 schedule；null → `SpacedRepetitionService.initial`。
2. `apply(schedule, feedback, DateTime.now())` 得新 schedule。
3. `upsert(newSchedule)`。
4. 更新 stats，加载下一张。

**空状态**：今日新增空 → 「今天还没有新增知识点」；到期复习空 → 「今日已背完 🎉」。

### 4.6 Providers（core/providers 新增）

provider 返回的聚合类型定义在 `knowledge_providers.dart` 内并**公开导出**（不加 `_` 前缀，因页面跨文件引用）：

| Provider | 类型 | 职责 |
|---|---|---|
| `categoryRepositoryProvider` | `Provider` | 从 `databaseProvider` 构造 `CategoryRepository` |
| `topicRepositoryProvider` | `Provider` | 构造 `TopicRepository` |
| `topicEdgeRepositoryProvider` | `Provider` | 构造 `TopicEdgeRepository` |
| `reviewScheduleRepositoryProvider` | `Provider` | 构造 `ReviewScheduleRepository` |
| `reviewQueueRepositoryProvider` | `Provider` | 构造 `ReviewQueueRepository` |
| `categoryChildrenProvider` | `FutureProvider.family<int?, List<CategoryChild>>` | 某层子分类+知识点 |
| `topicDetailProvider` | `FutureProvider.family<int, TopicDetail>` | 详情聚合 |
| `reviewQueueProvider` | `FutureProvider.family<ReviewMode, List<ReviewQueueItem>>` | 背诵队列 |

聚合类型（公开）：

```dart
/// 知识库某层列表项：分类或知识点。
class CategoryChild {
  final bool isCategory;
  final int id;            // category.id 或 topic.id
  final String name;       // category.name 或 topic.title
  final bool hasChildren;  // 仅分类有意义：是否有子分类
  CategoryChild({required this.isCategory, required this.id, required this.name, this.hasChildren = false});
}

/// 详情页聚合数据。
class TopicDetail {
  final Topic topic;
  final List<String> path;                 // 分类路径段
  final List<TopicEdgeView> edges;         // 关联边（prerequisite 在前）
  TopicDetail({required this.topic, required this.path, required this.edges});
}

/// 背诵模式。
enum ReviewMode { todayNew, due }
```

Repository 类无状态，provider 每次从 db 构造（和现有 `agentSessionProvider` 风格一致）。

## 5. 数据流

```
知识库浏览：
  KnowledgeBasePage
    → categoryChildrenProvider(parentId)
    → CategoryRepository.findChildren + TopicRepository.findByCategory
    → StudyDatabase (SQLite)

搜索：
  KnowledgeBasePage (搜索框)
    → TopicRepository.search(keyword)
    → 每条 CategoryRepository.pathOf(categoryId)
    → StudyDatabase

详情：
  TopicDetailPage
    → topicDetailProvider(topicId)
    → TopicRepository.findById + CategoryRepository.pathOf + TopicEdgeRepository.findByTopic
    → StudyDatabase

背诵加载：
  ReviewPage
    → reviewQueueProvider(mode)
    → ReviewQueueRepository.dueQueue / todayNewQueue
    → StudyDatabase

背诵反馈：
  ReviewPage (三档按钮)
    → ReviewScheduleRepository.getByTopic
    → (null? SpacedRepetitionService.initial)
    → SpacedRepetitionService.apply
    → ReviewScheduleRepository.upsert
    → StudyDatabase
```

## 6. 错误处理

| 场景 | 处理 |
|---|---|
| 知识库查询失败 | 列表区显示错误 + 重试按钮 |
| 搜索失败 | 搜索结果区显示错误 + 重试 |
| 详情加载失败 | 全屏错误 + 重试 |
| 背诵队列加载失败 | 卡片区错误 + 重试 |
| 背诵反馈 upsert 失败 | SnackBar 提示「保存复习记录失败」，卡片不前进（留在当前卡，允许重试） |
| 库空 | 各页空状态文案（见 4.3/4.5） |

背诵反馈失败**不静默吞**——记忆曲线数据丢失会破坏调度，必须让用户感知并重试。

## 7. 测试策略

### 7.1 引擎单测（重点，packages/study_engine/test/）

**SpacedRepetitionService**（纯函数，重点测）：
- 三档映射：忘了→interval=1+ease降0.2；记得→interval=round(old×ease)；轻松→interval=round(old×ease×1.3)+ease升0.1
- 首学边界：intervalDays=0 时，记得→1、轻松→2、忘了→1
- ease 上下限：连续忘了到 1.3 不再降；连续轻松到 3.0 不再升
- interval 下限：round 得 0 时兜底为 1
- `nextReviewAt` = now + interval 天
- `reviewCount` 递增、`lastReviewedAt` = now

**ReviewScheduleRepository**：
- `getByTopic` 无记录返回 null
- `upsert` 插入后能 `getByTopic` 取回；二次 upsert 更新（不报主键冲突）
- `findDue` 只返回 `next_review_at <= now`，升序，限量生效

**ReviewQueueRepository**：
- `dueQueue` 返回带 title/question 的轻量项，限量生效
- `todayNewQueue` 查 topic.created_at（LEFT JOIN 排除已建 schedule 的 topic），含无 schedule 的今日新增；跨天边界（昨天的不算今天）

**db_test.dart 扩展**：v3 迁移建 `review_schedule` 表断言（表名 + 列）；CASCADE 回归（删 topic 连带删 schedule）。

### 7.2 App widget 测试（study_buddy/test/）

- KnowledgeBasePage：渲染分类 + 知识点混排列表；点分类触发下钻（验证 provider 调用）
- TopicDetailPage：渲染 question/summary/edges；无 edges 时隐藏区块
- ReviewPage：卡片流程——引子→揭晓→三档按钮→点「记得」触发 upsert（mock repository 验证调用）

widget 测试用 mock repository provider 覆盖，不依赖真实 DB。

### 7.3 不测的（YAGNI）

- 间隔重复算法的长期收敛性（靠单测覆盖映射规则即可）
- 搜索防抖时序（实现细节，靠人工验收）
- 真实 LLM / agent 交互（已有集成测试覆盖写入侧）

## 8. 关键文件清单

| 改动 | 文件 |
|---|---|
| 迁移 v3 | `packages/study_engine/lib/src/db/database_migrations.dart` |
| DB 版本 | `packages/study_engine/lib/src/db/database.dart`（kCurrentDbVersion 2→3） |
| 模型 | `packages/study_engine/lib/src/models/models.dart`（ReviewSchedule / ReviewFeedback） |
| 调度算法 | `packages/study_engine/lib/src/review/spaced_repetition_service.dart`（新增） |
| 调度仓库 | `packages/study_engine/lib/src/repos/review_schedule_repository.dart`（新增） |
| 队列仓库 | `packages/study_engine/lib/src/repos/review_queue_repository.dart`（新增） |
| barrel | `packages/study_engine/lib/study_engine.dart`（导出新模块） |
| 引擎测试 | `packages/study_engine/test/spaced_repetition_test.dart`（新增） |
| 引擎测试 | `packages/study_engine/test/repos_test.dart`（扩展 review_schedule） |
| 引擎测试 | `packages/study_engine/test/db_test.dart`（v3 建表 + CASCADE） |
| 路由 | `study_buddy/lib/router.dart`（MainShell + /topic/:id） |
| 主壳 | `study_buddy/lib/features/home/main_shell.dart`（新增，三 Tab） |
| 悬浮窗 Tab | `study_buddy/lib/features/home/overlay_settings_page.dart`（原 home_page 平移） |
| 知识库 | `study_buddy/lib/features/knowledge/knowledge_base_page.dart`（新增） |
| 详情 | `study_buddy/lib/features/knowledge/topic_detail_page.dart`（新增） |
| 背诵 | `study_buddy/lib/features/review/review_page.dart`（新增） |
| Providers | `study_buddy/lib/core/providers/knowledge_providers.dart`（新增） |
| 删除 | `study_buddy/lib/features/home/home_page.dart`（内容平移到 main_shell + overlay_settings_page） |
| App 测试 | `study_buddy/test/...`（widget 测试，新增） |

## 9. 已知缺口（留后续）

- **记忆曲线长期调优**：简化 SM-2 的 ease/间隔系数是经验值，真实遗忘因人/学科而异。需积累数据后看是否引入遗忘曲线参数化。本次用经验系数。
- **跨时区/跨日边界**：`startOfDay` 用设备本地时区 00:00。跨时区旅行场景（用户飞跨时区，本地日期突变）可能导致今日新增/到期判断抖动。本次不处理，按设备本地时区。
- **复习推送**：到期复习无主动通知，依赖用户主动进背诵 Tab。后续可加本地通知。
- **背诵统计历史**：本轮统计只在当前会话显示，不持久化。长期复习曲线/热力图留后续。
