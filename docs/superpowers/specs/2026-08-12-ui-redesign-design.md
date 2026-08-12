# Study Buddy UI 重设计 + 间隔重复背诵系统

> 设计日期：2026-08-12
> 状态：已批准，待实施计划
> 预览：`docs/superpowers/specs/ui-redesign-preview.html`

## 1. 背景与问题

当前 App 的 UI 处于"完全不可用"状态，根因有两层：

1. **信息架构崩坏**：首页是纸感学术期刊式的单页长滚动，悬浮窗、日志、版本检查等系统功能占据主要版面，而真正的学习动作（问 AI、看知识点、背诵）埋在深处。用户打开 App 无法在首屏完成任何学习闭环动作。

2. **学习闭环断裂**：engine 早已具备完整的知识点数据模型（`Topic` / `MasteryStatus` / `MasteryLog` / `TopicEdge`），AI 在拍题问答中也会通过 `save_topic` 沉淀知识点——但这些知识点**存进数据库后再也无法在 UI 中被查看、浏览、背诵**。学过的东西沉在库底看不到、背不了。

更深的一层：现有的"掌握度"是 4 档离散状态（`unknown / learning / mastered / weak`），`MasteryRepository.timeline` 注释写"用于遗忘曲线"，但**离散状态变更拼不出连续的艾宾浩斯遗忘曲线**。3 个月前标过的"已掌握"，今天其实已遗忘，标签却不衰减；也没有任何机制决定"今天该复习哪些"。

## 2. 设计目标

- **学习闭环可见可达**：打开 App 第一屏就能问 AI、看今日计划、开始专注、清今日复习队列，不用滑、不用进二级页。
- **学过的看得见、背得了**：知识点从数据库里"解救"出来，可按分类浏览、可搜索、可进详情页、可背诵。
- **复习由算法驱动，而非用户手动翻牌**：用间隔重复（FSRS）的连续记忆模型取代离散掌握度标签，系统在该复习时把用户叫回来，平时不打扰。
- **负担可控**：每日复习队列有上限，逾期过多时按优先级截断、自然顺延，不会雪崩。
- **导航极简**：底部只留三块，每个 Tab 职责单一。

## 3. 信息架构

底部 3 Tab，用 `StatefulShellRoute.indexedStack` 承载（保留各 Tab 状态）：

| Tab | 职责 | 一句话 |
|---|---|---|
| **今日** | 学什么 | 问 AI、今日计划、今日专注、今日复习入口 |
| **知识** | 沉淀与背诵 | 分类浏览、搜索、知识点详情、复习入口 |
| **设置** | 系统 | 悬浮窗权限、版本更新、关于 |

现有 push 路由 `/permission-guide`、`/plan/:id`、`/focus`、`/daily-report`、`/logs/*` 全部保留为堆叠路由（在 shell 之上），不受 Tab 重构影响。

## 4. 今日 Tab

由现有 `home_page.dart` 的纸感刊头长滚动结构**拆除重建**而来。

- **问 AI**（置顶）：拍照 / 相册 / 直接聊 三入口并列。"直接聊"与拍照后都调用现有 `showAiPanel`，不新建聊天页。
- **今日计划**：当日学习计划摘要与入口（跳 `/plan/:id`）。
- **今日专注**：开始专注按钮（push `/focus` 全屏计时）+ 当日日报入口（`/daily-report`）。
- **今日复习入口**：当 `topic_schedule.due_at ≤ 今日` 的知识点数 > 0 时显眼提示（如"今日待复习 N 张"），点击进入复习流（见 §7）。

## 5. 知识 Tab + 知识点详情页

### 5.1 知识 Tab

- **分类树浏览**：基于 `CategoryRepository`（自引用树），按学科 / 模块 / 章节下钻到知识点列表。
- **搜索**：`TopicRepository.search(keyword)`（已在 title / question / summary 上 LIKE 查询）。
- **知识点列表项**：标题 + 掌握度标签（从 S 派生，见 §7.3）+ 下次复习时间提示。
- **复习入口**：与今日 Tab 共用同一个复习流页面。

### 5.2 知识点详情页（新增路由 `/topic/:id`）

从知识 Tab 列表点进，或从聊天里的知识点卡片跳转。展示与操作全部来自 engine 已有 API：

| 区块 | 内容 | 数据来源 |
|---|---|---|
| 顶部栏 | ‹ 返回 + 面包屑（学科 / 模块 / 章节） | `Category.pathOf` |
| 标题 | `Topic.title` | `Topic` |
| 掌握度标签 | 从 S 派生（薄弱/学习中/已掌握） | `TopicSchedule.stability` |
| 背诵引子 | `Topic.question`（卡片正面） | `Topic` |
| 答案（支持公式） | `Topic.summary`（卡片背面，Markdown + LaTeX） | `Topic` |
| 关联知识点 | 前置 / 相关 chips，点击跳对方详情页 | `TopicEdgeRepository.findByTopic` |
| 掌握度轨迹 | 时间线 | `MasteryRepository.timeline` |
| 底部操作 | 问 AI 深度交流 / 背诵 / 编辑 | 见下 |

- **问 AI 深度交流**：复用持久多轮聊天（与 §6 同一面板，预置该知识点上下文）。
- **背诵**：直接进入今日复习流（§7）。
- **编辑**：`update_topic` 改 `summary`。

## 6. 问 AI 聊天面板（复用 + 增强）

复用 `external_qbank/ai_panel_sheet.dart` 的 `showAiPanel`，视觉对齐纸感主题，补齐两点：

1. **公式 / 图表渲染**：AI 输出用 Markdown + LaTeX 渲染（数学 / 考研 408 场景必需）。新增依赖 `flutter_markdown` + `flutter_math_fork`（见 §8）。
2. **知识点卡片交互**：`save_topic` 工具调用不再渲染为灰字轨迹行，而是渲染为**可点击卡片**：
   - **已存在**（`save_topic` 返回"已存在 id=N"）：卡片显示该知识点当前掌握度标签（薄弱/学习中/已掌握）。
   - **新知识点**（返回"已保存 id=N"）：卡片标朱砂「新」。
   - 判定依据：`save_topic` 已用 `findByTitle` 查重，返回文本可区分；卡片解析出 id 后用 `TopicScheduleRepository`（新）/ `MasteryRepository` 查掌握度。
   - 点击卡片 → 跳转知识点详情页（`/topic/:id`）。

## 7. 间隔重复背诵系统（核心新增）

采用 **FSRS 简化版**（B 档）+ **纯翻面自评**交互。AI 不插手调度与测试——AI 只负责输入（`save_topic`）和深化（详情页深度交流），调度完全离线、零 LLM 成本。

### 7.1 数据模型

新增一张表 `topic_schedule`（每个知识点一行，`topic_id` 主键）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `topic_id` | INTEGER PK → `topic.id` | 关联知识点 |
| `stability` | REAL | 记忆稳定性 S（天）：多久后保留率降到阈值 |
| `difficulty` | REAL | 难度 D（1..10），初始 5.0 |
| `reps` | INTEGER | 完成复习次数 |
| `lapses` | INTEGER | 失误（评"忘了"）次数 |
| `last_reviewed_at` | INTEGER (ms) | 上次复习时间 |
| `due_at` | INTEGER (ms) | 下次到期时间 |

保留率（可提取度）采用 FSRS 的幂次衰减形式：

```
R(t) = (1 + t / (9 * S)) ^ -1     // t = 距 last_reviewed 的天数
```

> 注：`mastery_log` 表保留，继续作为掌握度**时间线轨迹**与 `set_mastery` 的写入目标；它**不再驱动调度**，调度依据是 `topic_schedule` 的 S 与 due。

### 7.2 FSRS 简化算法

四档评分 `Forgot(忘了) / Hard(困难) / Good(良好) / Easy(简单)`。**默认参数如下，全部可后续调**：

**首次评分**（`reps == 0`，设定初始 S）：

| 评分 | 初始 S（天） | 首次 due |
|---|---|---|
| Forgot | 0.02（~30 分钟） | 当日内重见 |
| Hard | 1.0 | 次日 |
| Good | 3.0 | 3 天后 |
| Easy | 8.0 | 8 天后 |

`Forgot` 不使 `reps` 增长（仍当新卡），`lapses += 1`；其余 `reps = 1`。

**后续评分**（`reps >= 1`，已知 S、D）：

```
D 更新：
  Hard:   D += 0.15
  Good:   D += 0.0
  Easy:   D -= 0.15
  Forgot: D += 0.5          // 忘了 → 视作更难记
  D = clamp(D, 1.0, 10.0)

S 更新（g = 增长系数，D 越大增长越慢）：
  Hard:   S_next = S * 1.2  * (10 - D) / 9
  Good:   S_next = S * 2.5  * (10 - D) / 9
  Easy:   S_next = S * 4.0  * (10 - D) / 9
  Forgot: S_next = max(0.4, S * 0.3)   // 失误重置路径，lapses += 1，reps 归 0

due_at = last_reviewed_at + interval
  interval = round(S_next) 天（转毫秒）
  Forgot 时 interval = 30 分钟（当日内）
```

`S_next`、`D` 用浮点存。算法实现为纯函数 `ReviewScheduler.grade(schedule, rating, now) -> TopicSchedule`，便于单测覆盖全部分支。

### 7.3 掌握度派生

展示用的掌握度标签（详情页、列表、聊天卡片）从 S 与 reps 派生，**不再从 `mastery_log` 读**：

```
reps == 0 且无 schedule 记录         → unknown（未学）
S < 1                                → weak（薄弱）
1 <= S < 21                          → learning（学习中）
S >= 21                              → mastered（已掌握）
```

`set_mastery`（AI 工具 + 详情页手动）仍写 `mastery_log`（留作轨迹），**并作为对 D 的修正信号**：手动标 `weak` 时把 D 拉高、`mastered` 时把 S 抬到 ≥21 区间，使人工判断能影响后续调度。**阈值（1 天 / 21 天）为默认值，可调。**

### 7.4 队列与负担控制

- **今日队列**：`TopicScheduleRepository.dueNow()` = `due_at <= now` 的知识点。
- **优先级排序**：`(now - due_at)` 越大（越逾期）越优先；逾期相同时 `stability` 越低越优先——最该抢救的排最前。
- **每日复习上限**：默认 **20** 张。
- **每日新卡上限**：默认 **5** 张（新知识点首评当日 due = 当日，计入新卡额度，避免新知识涌入压垮复习）。
- **顺延机制（无需显式逻辑）**：今日队列只取上限内的 N 张；剩余卡 `due_at` 不动，**明天仍满足 `due_at <= now` 且逾期更久 → 自动排在队首**。这就是"不会堆积成山"：每天清掉一部分，逾期越久越优先抢救。UI 对剩余展示"今日已完成，N 张明天见"。

### 7.5 复习交互流

纯翻面自评，全程离线：

1. 顶部进度条：`今日复习 · k / N`。
2. 卡片正面：`Topic.question`（背诵引子）+ 提示"先在脑里回忆，再翻面看答案"。
3. 点击翻面：展示 `Topic.summary`（答案，Markdown + 公式渲染）。
4. 底部四档按钮：`忘了 / 困难 / 良好 / 简单`，按钮下小字标注算法预估的下次间隔（如"良好 → 3 天"），所见即所得。
5. 点击评分 → 调 `ReviewScheduler.grade` 更新 `topic_schedule` → 自动进入下一张。
6. 清空队列 → 完成页（今日复习数、明日预告数）。

## 8. 公式渲染

新增依赖：

- `flutter_markdown`：Markdown 渲染。
- `flutter_math_fork`：LaTeX 公式渲染。

聊天 AI 输出（§6）与知识点详情页答案（§5.2）、复习翻面答案（§7.5）共用同一套渲染器（封装为一个 `MarkdownLatex` widget）。408 / 数学场景的公式（如 `T(n) = aT(n/b) + f(n)`、`Θ(n^{log_b a})`）正常显示。

## 9. 设置 Tab

由现有 `settings_page.dart` 收敛而来，悬浮窗权限、版本更新、关于、日志入口收敛为设置行。日志路由（`/logs/app`、`/logs/llm/:id`）保留。

## 10. 技术改动范围（文件级）

| 文件 / 模块 | 类型 | 改动 |
|---|---|---|
| `router.dart` | 重构 | 改 `StatefulShellRoute.indexedStack` 3 Tab；`/permission-guide`、`/plan/:id`、`/focus`、`/daily-report`、`/logs/*` 保留为堆叠路由；新增 `/topic/:id` |
| `home_page.dart` → `features/today/` | 重构 | 纸感刊头长滚动结构拆除，重建为今日 Tab：问 AI（拍照/相册/直接聊）+ 今日计划 + 今日专注 + 今日复习入口 |
| `features/knowledge/` | 新增 | 知识 Tab：分类树浏览 + 搜索 + 列表；知识点详情页（引子/答案/掌握度/关联/轨迹/三操作） |
| `features/review/` | 新增 | 复习流：今日队列 + 翻面卡 + 四档自评，调 `ReviewScheduler` |
| `features/settings/` | 新增/改造 | 设置 Tab：收敛为设置行 |
| `focus_page.dart` | 改造 | 由独立 Tab 改为今日页"开始专注"push 的全屏计时页；修掉 `Colors.deepPurple` 接入主题 |
| `external_qbank/ai_panel_sheet.dart` | 复用 + 增强 | 今日页"直接聊"与拍照后均弹此面板（不新建聊天页）；新增公式渲染 + 知识点卡片交互（去重判定、新/已有色、跳详情） |
| `study_engine` · `review_scheduler` | 新增 | FSRS 简化算法 + `TopicSchedule` 模型 + `TopicScheduleRepository` + `topic_schedule` 表迁移 + `dueNow` 查询 + 掌握度派生 |
| `pubspec.yaml` | 新增依赖 | `flutter_markdown` + `flutter_math_fork` |
| `app.dart` | 不动 | 生命周期（悬浮球 show/hide、截图回流 `_checkPending`）完全保留，仅随 router 调整接线 |
| `core/theme/*` | 不动 | 纸感主题不改；补 NavigationBar 主题 token |

## 11. 明确不做的事

- **拍题问答历史**：不做历史列表，聊天即用即走（与既有决策一致）。
- **复习阶段的 AI 测验**：本次明确选纯翻面自评，AI 不参与评分判分（负担、成本、速度优先）。
- **知识图谱可视化**：详情页用关联 chips + 跳转实现图谱浏览，不做全局图谱视图。
- **跨设备同步**：仍为本地 SQLite。

## 12. 关键决策记录

- **为什么 FSRS 简化版（B 档），而非 Leitner / 完整 FSRS**：Leitner 本质仍是离散状态机，没真正解决连续遗忘；完整 FSRS + half-life 拟合对单人工具过重、参数难调。简化 FSRS 是连续性的合理近似 + 负担可控 + 业界（Anki）验证的 sweet spot。
- **为什么纯翻面 + 自评，而非 AI 测验判分**：用户明确"负担要轻"。纯翻面离线零成本，20 张几分钟刷完；AI 测验每张一次 LLM 调用，又慢又贵。AI 价值留在"输入 + 深化"，不进调度 / 测试。
- **为什么掌握度标签从 S 派生，保留 mastery_log**：调度依据必须是连续的 S / due，而非静态标签；但 mastery_log 作为时间线轨迹与人工修正 D 的信号仍有价值，故保留。
- **为什么每日上限用"自然顺延"而非显式调度**：剩余卡 due 不动，明天自动因更逾期而排前，逻辑零特例、不会无限堆积。

## 13. 风险与开放问题

- **算法参数**：§7.2 的系数（1.2 / 2.5 / 4.0、D 步进 0.15 / 0.5、失误重置 0.3）为合理初值，需上线后按真实复习数据观察调整；初版不暴露给用户，后续可加设置项。
- **新卡来源与上限竞争**：新知识点首日进队会占用复习时间。每日新卡上限（默认 5）用于隔离，避免复习被新卡淹没；上限值上线后按反馈调。
- **掌握度派生阈值**（1 天 / 21 天）：考研 408 等长周期内容的"已掌握"门槛是否合适，需观察；作为可调参数处理。
- **知识点详情页公式渲染性能**：`flutter_math_fork` 渲染大量公式时可能卡顿，详情页与复习卡均为单条渲染，风险低；聊天流多条公式需关注，必要时缓存。
