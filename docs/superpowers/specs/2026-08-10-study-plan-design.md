# 学习计划功能设计

> 日期：2026-08-10
> 状态：设计稿（待实现）
> 范围：study_buddy APP 新增"学习计划"功能——目标拆解 + 周期测评 + 进步曲线 + AI 对话调整

## 1. 背景与目标

用户需要一个学习计划功能：输入考试时间、考试内容、目标、每日学习时间，由 AI 制定科学的学习计划，并能随时沟通调整。

经澄清，功能定位为**目标管理工具**（非每日 todo 打卡）：

- **目标驱动**：用户定目标（如考研、目标分数 X），评测当前水平。
- **节点拆解**：AI 根据考试日期 + 当前水平 + 目标差距 + 每日学习时间，拆出关键里程碑节点（"什么时间点要达到什么程度"）。
- **周期测评**：定期提醒用户重新评测，手动录入分数。
- **进步曲线**：历次测评画成曲线，激励 + 提醒是否偏离目标。

### 关键决策（已与用户确认）

1. **计划与知识点体系的关系**：计划是轻量阶段目标排程，里程碑节点**不挂具体 topic**。计划独立于现有知识库，不强行关联。
2. **测评分数**：纯手动录入。不引入 AI 估分（误差大、范围膨胀）。
3. **多计划并行**：支持同时多个计划（考研 + 六级等），数据按 `plan_id` 隔离。
4. **AI 调整方式**：AI 用工具直接改库（增删改里程碑、录测评、改目标），与现有 `StudyScenario` 的工具模式一致。
5. **测评提醒**：APP 内静默检查（距上次测评超 N 天则提示），不引本地通知依赖。MVP 不做系统推送。
6. **创建计划交互**：纯对话式创建。工具 schema 必填字段兜底防信息缺漏——AI 调 `create_plan` 必须收齐考试日期/内容/目标/每日时长/当前水平，缺了会主动追问。
7. **AI 能力组织**：独立 `PlanScenario`（新场景）+ 独立工具集，APP 层做"计划会话"封装，注入当前 plan 概要到 system prompt（方案 C）。
8. **日期上下文**：`PlanSession` 在 system prompt 注入当前日期 + 距考试天数，确保 AI 排期准确。

## 2. 整体架构与模块边界

零新依赖，嵌入既有分层：

```
study_engine (纯 Dart, 不依赖 Flutter)
├── models/models.dart        + Plan / Milestone / Assessment 三个模型
├── db/
│   ├── database_migrations   v3: 新增 plan / milestone / assessment 三表
│   └── database.dart         不变
├── repos/
│   ├── plan_repository.dart        新增：plan + milestone + assessment 的 CRUD + 聚合查询
│   └── (既有 repo 不动)
├── agent/
│   ├── scenarios/
│   │   ├── study_scenario.dart     不动（截图分析）
│   │   └── plan_scenario.dart      新增：7 工具，管理计划全生命周期
│   └── agent_scenario.dart         不变（抽象沿用）
└── study_engine.dart  barrel 追加导出

study_buddy (Flutter APP)
├── core/providers/
│   ├── database_provider.dart        不变
│   └── plan_session_provider.dart    新增：组装 PlanScenario + AgentLoop，
│                                      注入当前 plan 概要 + 当前日期到 system prompt
├── features/
│   ├── home/home_page.dart           改：首页从空壳变"计划列表"入口（列表直接渲染在首页）
│   ├── plan/
│   │   ├── plan_detail_page.dart     计划详情：提醒横幅 + 曲线 + 节点时间线
│   │   ├── assessment_entry_sheet.dart  手动录分弹窗
│   │   └── plan_chat_sheet.dart      AI 对话调整（复用 ai_panel_sheet 流式模式）
│   └── (既有 overlay/external_qbank 不动)
└── router.dart                       + /plan/:id 路由
```

### 关键边界

- **引擎层**：新增三模型 + 一 repo + 一 scenario，零 Flutter 依赖，可在 `study_engine/test` 单测。
- **APP 层**：`PlanSession` 是 `AgentSession` 的镜像——同样从 DB 读 LlmConfig、构造 `PlanScenario`+`AgentLoop`，但额外注入当前 plan 概要 + 当前日期到 system prompt。两者共用 `AgentLoop`，不复制循环逻辑。
- **零新依赖**：曲线用 Flutter 内置 `CustomPainter` 手绘（不引 fl_chart）；提醒纯 APP 内检查（不引 local_notifications）。

## 3. 数据模型

### Plan（计划本体）

创建计划时用户给定、相对稳定的元信息。

| 字段 | 类型 | 说明 | 示例 |
|---|---|---|---|
| `id` | int? | 主键 | 1 |
| `name` | String | 计划名 | "考研冲刺" |
| `exam_date` | DateTime | 考试日期 | 2026-12-21 |
| `exam_content` | String | 考试内容/范围 | "政治、英语一、数学一、408" |
| `target` | String | 目标（分数/院校/通过等，灵活承载） | "总分 380，数学 120+" |
| `daily_minutes` | int | 每日学习时间（分钟） | 180 |
| `current_level` | String? | 创建时自评水平 | "做真题估 300 分，数学最弱" |
| `created_at` | DateTime | 时间戳 | |
| `updated_at` | DateTime | 时间戳 | |

> `target` 和 `current_level` 用文本而非纯数字——目标不一定是分数。**真正的分数走 Assessment 表**，避免和元信息混在一起。

### Milestone（里程碑节点）

AI 拆出的关键节点，按时间线序列排（按 `target_date` 排序）。

| 字段 | 类型 | 说明 | 示例 |
|---|---|---|---|
| `id` | int? | 主键 | 5 |
| `plan_id` | int | 外键 → plan | 1 |
| `title` | String | 节点名 | "数学基础过完" |
| `description` | String | 完成标志（达到什么程度算过） | "高数+线代基础课听完，能独立做基础题" |
| `target_date` | DateTime | 目标完成日期 | 2026-09-30 |
| `sort_order` | int | 顺序 | 2 |
| `status` | String | 状态枚举 `pending`/`done` | `pending` |
| `created_at` | DateTime | 时间戳 | |
| `updated_at` | DateTime | 时间戳 | |

> 节点不挂具体 `topic`——计划是"阶段目标排程"，不是知识点 todo。

### Assessment（测评记录）

每次手动录分，承载进步曲线数据点。

| 字段 | 类型 | 说明 | 示例 |
|---|---|---|---|
| `id` | int? | 主键 | 3 |
| `plan_id` | int | 外键 → plan | 1 |
| `score` | int? | 分数（可空：无法量化时只记 note） | 310 |
| `note` | String? | 备注 | "数学大题扣多，线代还行" |
| `assessed_at` | DateTime | 测评日期 | 2026-08-20 |
| `created_at` | DateTime | 时间戳 | |

> `score` 可空——曲线主路径用数值分数；实在无法量化时只存 `note`，曲线退化为"仅有备注的时间线"。

### 三者关系

```
Plan (1) ──< Milestone (N)     阶段时间线
Plan (1) ──< Assessment (N)    进步曲线数据点
```

不建 Milestone↔Assessment 关联——测评是对整体水平的快照，不绑定某个节点。AI 在对话里对照节点和测评做判断，那是 prompt 上下文层的事，不在表结构硬连。

## 4. AI 工具与提示词设计（PlanScenario）

### 工具清单（7 个）

| 工具 | 作用 | 关键参数（`*` 必填） |
|---|---|---|
| `create_plan` | 创建计划（含首次自评 → 自动生成第 1 条 Assessment） | name*, exam_date*, exam_content*, target*, daily_minutes*, current_level* |
| `get_plan` | 拉取计划完整结构（元信息 + 所有节点 + 所有测评） | plan_id* |
| `update_plan` | 改计划元信息（名称/日期/内容/目标/每日时长） | plan_id*, + 可选字段 |
| `add_milestone` | 加一个节点 | plan_id*, title*, description*, target_date* |
| `update_milestone` | 改节点（标题/描述/日期/状态） | milestone_id*, + 可选字段 |
| `delete_milestone` | 删节点 | milestone_id* |
| `add_assessment` | 录一次测评 | plan_id*, score*, note?, assessed_at? |

> 创建计划 6 字段全必填——AI 想建计划必须从用户那拿齐，缺了会追问。这是"对话式创建但不漏信息"的兜底机制。

### 工具执行逻辑要点

- **`create_plan`**：插 Plan 表后，自动把 `current_level` 解析成分数插进 Assessment 表作为起点分（曲线第一个点）。解析规则：从文本抽数字（"估 300 分" → 300）；抽不到则 `score` 留空、只存 `note`。
- **`get_plan`**：一次返回全部节点和测评（节点少，不分页），给 AI 完整上下文。
- **`update_milestone`**：`status` 限定 `pending`/`done`，非法值返回错误。
- **`add_assessment`**：`assessed_at` 不传默认今天。
- **`delete_plan` 不在 AI 工具里**——高危操作 AI 只建议、用户 UI 手动执行（删计划走 CASCADE 清节点和测评）。

### 系统提示词结构

```
你是学习计划助手 AI。职责：帮用户把考试目标拆成可执行的里程碑节点，
跟踪周期测评，画进步曲线，并根据进度随时调整计划。

## 当前时间
{APP 层注入：今天是 YYYY-MM-DD，距 <考试名> 考试还有 N 天}

## 创建计划（create_plan）必须收齐
- name：计划名
- exam_date：考试日期（YYYY-MM-DD）
- exam_content：考试内容/范围
- target：目标（分数/院校/通过等）
- daily_minutes：每日可学习时长（分钟）
- current_level：当前自评水平（最近做真题能考多少分，哪块弱）
缺任何一项都要先追问用户补齐，不要瞎猜。收齐后再 create_plan。

## 拆节点原则
- 按考试日期倒推，结合每日时长和当前差距排期。
- 薄弱项节点排前。
- 每个节点要有明确的"完成标志"（description 写清达到什么程度算过）。
- 节点数 4-8 个为宜，太细碎用户跟不上，太粗等于没拆。

## 调整原则
- 用户报进度落后/超前时，对照 get_plan 的节点和测评重排后续节点。
- 改目标时联动调整节点的分数预期。
- 高危操作（删节点）执行前向用户确认一句。

## 测评
- 用户提到做了真题/模考并报分时，用 add_assessment 录入。
- 鼓励用户定期测评，对照曲线看趋势。

## 当前计划上下文
{APP 层注入的当前 plan 概要：name / exam_date / target / 节点列表 / 最近测评}
```

### 上下文注入（方案 C 核心）

`PlanSession.run` 每次构造 messages 时，把以下信息塞进 `AgentScenarioContext.extra`，prompt 模板引用：

1. **当前日期 + 距考试天数**：AI 排期、判断"进度落后几天"、算"距上次测评多少天"都准。运行时注入，不写死。
2. **当前 plan 概要**：用户在某个计划详情页打开对话时，APP 注入该计划的元信息 + 节点列表 + 最近测评。AI 知道"在聊哪个计划"，用户说"把第 3 个节点提前一周"不用解释。

### PlanScenario 与 StudyScenario 的关系

完全平行的两个 scenario，各自独立工具集和 prompt，共用 `AgentLoop`（循环逻辑零改动）。`AgentSession`（截图分析）和 `PlanSession`（计划管理）是 APP 层两个入口。

**LLM 配置差异**：计划场景**不需要视觉**，`PlanSession` 取默认配置时 `vision: false`（而 `AgentSession` 是 `vision: true`）。避免强制要求用户配视觉模型才能用计划功能。

## 5. UI 与页面流

### 页面 1：首页（改造现有 home_page.dart）

当前首页是空壳（只显示悬浮窗状态）。改成**计划列表入口**，悬浮窗状态降级为次要信息：

- AppBar：`Study Buddy`
- 主体：`ListView` 渲染 Plan 列表（从 `plan_repository` 读）。每张卡片显示：图标 + 名称 + 考试日期 + 目标 + 进度（done/total）+ 最近测评分。点进详情页。
- 底部：`+ 新建计划` FilledButton，打开 `PlanChatSheet`（空 plan_id 模式）。
- 原有 `_overlayGranted` 逻辑保留但移到页面底部小字次要区。

### 页面 2：计划详情（plan_detail_page.dart）

三段式纵向滚动：

1. **提醒横幅**（条件显示）：进页面时查 Assessment 最近 `assessed_at`，超 14 天显示"距上次测评 X 天，该测了"。无测评记录时不显示。
2. **进步曲线**：`CustomPainter` 画分数折线 + 目标虚线。数据来自 Assessment 列表（按 `assessed_at` 排序）。`score` 为 null 的点跳过绘制、只显示备注标记。无测评时显示空态"还没有测评记录，记一次吧"。曲线下方 `[+ 记录测评]` 按钮弹 `AssessmentEntrySheet`。
3. **里程碑时间线**：列出所有 Milestone（按 `target_date` 排序）。每条右侧勾框，点一下调 `update_milestone` 切 `status`（done 灰色打勾）。顶部汇总"X/Y 已完成"。临近节点（`target_date` 前后 3 天内）高亮。AppBar 的 💬 打开 `PlanChatSheet`（注入当前 plan_id）。

### 弹窗 1：录分（assessment_entry_sheet.dart）

直接调 `plan_repository.addAssessment`，不走 AI（录分是确定性操作）。字段：分数（数值，必填）、备注（可选）、日期（默认今天，可改）。本地校验：score 非数字/空 → 提示；日期格式校验。存完回详情页，曲线刷新。

### 弹窗 2：AI 对话（plan_chat_sheet.dart）

复用 `ai_panel_sheet` 结构（底部抽屉 + 流式回复 + 工具调用轨迹），但：

- 无截图缩略图（计划场景不拍照）。
- 顶部多一行当前计划名："正在调整：考研冲刺"。
- 用 `PlanSession` 而非 `AgentSession`，system prompt 注入当前 plan 概要 + 当前日期。
- 两种模式：
  - **新建模式**（首页"新建计划"进）：`plan_id` 为空，AI 从零对话建计划，`create_plan` 后 APP 拿到返回的 plan_id，关闭弹窗跳详情页。
  - **调整模式**（详情页 💬 进）：已带 `plan_id`，AI 直接基于上下文调整。

### 路由（router.dart）

```dart
GoRoute(path: '/', builder: ... HomePage),           // 改造后
GoRoute(path: '/plan/:id', builder: ... PlanDetailPage),
// /permission-guide 保留
```

### 状态管理（Riverpod，仿现有 providers）

- `planRepositoryProvider`：从 `databaseProvider` 取 db 构造 `PlanRepository`。
- `planListProvider`：`FutureProvider<List<Plan>>`，首页 watch。
- `planDetailProvider(id)`：`FutureProvider` family，详情页 watch，返回 Plan + Milestones + Assessments 聚合。
- `planSessionProvider`：仿 `agentSessionProvider`，构造 `PlanScenario` + `AgentLoop`，取 `vision: false` 默认 LlmConfig。

## 6. 数据库迁移 v3

`kCurrentDbVersion` 2 → 3，新增三表。**只增不改**，不碰既有表，升级安全：

```sql
CREATE TABLE plan (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  exam_date INTEGER NOT NULL,
  exam_content TEXT NOT NULL,
  target TEXT NOT NULL,
  daily_minutes INTEGER NOT NULL,
  current_level TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE milestone (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  plan_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  target_date INTEGER NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE
);
CREATE INDEX idx_milestone_plan ON milestone(plan_id);

CREATE TABLE assessment (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  plan_id INTEGER NOT NULL,
  score INTEGER,
  note TEXT,
  assessed_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE
);
CREATE INDEX idx_assessment_plan ON assessment(plan_id, assessed_at);
```

删除计划走 CASCADE（FK 已启用，节点和测评自动清掉）。

## 7. 错误处理

| 场景 | 处理 |
|---|---|
| LLM 未配置默认项 | `PlanSession.run` 抛错 → UI 显示"请先配置 LLM"，不崩 |
| 计划场景取默认配置 | `vision: false`（不要求视觉模型） |
| AI 工具参数缺失/非法 | 工具执行层防御：返回友好错误文本（AgentLoop 已内置 try-catch） |
| 录分输入非法 | 弹窗本地校验：score 非数字/空 → 提示；日期格式校验 |
| 无测评记录 | 不显示提醒横幅；曲线显示空态 |
| 曲线数据点异常 | score 为 null 的点跳过绘制、只显示备注标记；单点显示为单点 |

## 8. 测试策略

仿现有 `study_engine/test/` 模式（已有 `db_test` / `repos_test` / `study_scenario_integration_test`），新增对齐：

1. **模型测试**：`Plan` / `Milestone` / `Assessment` 的 fromMap/toMap 往返。
2. **迁移测试**：v2→v3 升级后三表可查；全新建库 v3 一次建齐。
3. **repo 测试**：`PlanRepository` CRUD、`getPlanDetail` 聚合（Plan+节点+测评）、CASCADE 删除、按 plan 隔离查询。
4. **scenario 集成测试**：`PlanScenario` 7 工具调用链——`create_plan` 自动生成首条 Assessment（含从 `current_level` 抽分数）、`update_milestone` 状态切换、`delete_milestone`、`get_plan` 完整返回等。核心断言：**AI 缺参数时 create_plan 不落库**（防御）。

APP 层 UI 测试：本项目暂无 widget 测试习惯，维持 engine 层测试为主，UI 用手工验收清单（和现有 floating-screenshot-ai 的 `@test(app)` 模式一致）。

## 9. 不在 MVP 范围

| 能力 | 状态 | 备注 |
|---|---|---|
| 系统推送通知 | ❌ | APP 内提醒先行；本地通知留作独立增强 |
| AI 估分 | ❌ | 纯手动录分，避免范围膨胀 |
| 操作撤销/历史快照 | ❌ | 改完后悔靠对话上下文还原 |
| 跨计划时间冲突检测 | ❌ | 计划对 AI 是独立上下文 |
| 节点完成自动建议测评 | ❌ | 可选增强，后续可加 |
| 计划与知识点 topic 关联 | ❌ | 计划是轻量阶段排程，不挂 topic |
