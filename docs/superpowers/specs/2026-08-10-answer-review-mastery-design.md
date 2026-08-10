# 作答批改与掌握度维护 设计

> **For agentic workers:** 本 spec 描述「学习伴侣 agent」的能力扩展:支持批改用户作答、诊断薄弱知识点/技巧、维护掌握度、产出可复盘的批改卡片。需配合 writing-plans 落实施计划。

## 背景

study_buddy 的「学习伴侣 agent」当前职责仅「分析题目、整理知识库」。提示词写「跟踪掌握状态」却是空头支票——掌握度机制虽已完整落地却**全程空转**:

- `MasteryStatus { unknown, learning, mastered, weak }` 枚举已存在
- `mastery_log` 表已建(只追加日志,`currentStatus` 取最新一条派生)
- `MasteryRepository` 三方法齐全(`log`/`currentStatus`/`timeline`)
- **但全项目无任何代码调用它**;6 个 agent 工具全是知识库 CRUD,无写掌握度、无批改、无记录作答的入口

用户需求(原话):用户拍照/截图,可能不仅是询问题目,也可能在询问自己作答的是否正确,**批改下用户的答案,并分析这份答案体现的用户知识点或技巧存在哪些薄弱点;如果知识点出现问题,调整/创建相关知识点并设置掌握程度;技巧也是知识的一种,也要用相似的方式处理**。后续补充:**批改需要一个专门工具保存批改情况,调用后展示特殊卡片,用户可进入卡片查看批改、并与 AI 探讨错误原因、梳理问题和知识点。**

本设计把这些需求接通到已有的掌握度地基上。

## 目标

1. agent 能识别用户意图:纯题目求解答 vs 含作答求批改
2. 批改:逐题判定对/部分对/错,给出解析
3. 诊断:从错误作答中识别暴露薄弱的知识点/技巧
4. 落库:对薄弱点创建或更新知识点,并维护掌握度(mastery_log)
5. 批改卡片:AI 用专门工具保存结构化批改明细,UI 渲染纸感卡片,可进入详情页查看、可在此继续对话复盘
6. 技巧与知识点同等待遇(归类为普通 topic,挂「技巧」分类)

## 全局约束

- **engine 零破坏性改动**:复用已有 `MasteryStatus`/`mastery_log`/`MasteryRepository`,不重写掌握度机制
- **单 agent 架构**:保持 `AgentLoop` 单 agent ReAct;用提示词阶段化 + 工具职责单一消解过载;数据接缝为未来拆子 agent 预留,但当下不拆
- **无新增第三方依赖**
- 批改明细走**新增 `review` 单表 + JSON 明细**(不用 `mastery_log` 装逐题明细)
- 敏感模式:不硬编码 `ixunke`/`xkh5-token`/`Authorization.*Bearer`/`study.keyky.cn` 字面值
- 现有测试全绿回归(engine 34 + app 59,以实际为准)

## 设计决策(用户拍板)

| # | 决策点 | 选择 | 理由 |
|---|---|---|---|
| 1 | 技巧建模 | 归类为普通 topic,靠分类路径区分(如 `数学/高等数学/技巧/换元法`) | 与「技巧也是知识的一种、相似方式处理」一致;零 schema 风险,掌握度/关联边/搜索全复用 |
| 2 | 批改留痕 | 对话(`chat_message`)+ `mastery_log`(reason 记诊断)+ **`review` 表**(批改明细) | 掌握度变化进 mastery_log;逐题批改明细进 review 表供卡片渲染与复盘注入 |
| 3 | 掌握度映射 | 全对→升一级(`unknown`/`weak`→`learning`、`learning`→`mastered`、`mastered` 保持);部分对→`learning`(已 `mastered` 回退);全错→`weak` | 错误即时暴露为薄弱;「掌握」需多次答对巩固才达成 |
| 4 | agent 架构 | 单 agent + 阶段化提示词 | 批改/诊断/落库是链式流水线,非多视角并行;不现在为抽象买单 |

## 数据模型

### 复用(零改动)

- `MasteryStatus` 枚举:`unknown | learning | mastered | weak`
- `mastery_log` 表:`id, topic_id, status, reason, changed_at`(只追加,`currentStatus` 取最新一条)
- `MasteryRepository.log/currentStatus/timeline`

### 新增:`review` 表(单表 + JSON 明细)

```sql
CREATE TABLE review (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_session_id INTEGER,             -- 归属哪个对话（app 经 context.extra 注入；可空以兼容工具直调测试）
  summary TEXT NOT NULL,               -- 摘要,如"批改3题,对1错2,薄弱:洛必达适用条件"
  items TEXT NOT NULL,                 -- 逐题明细 JSON 数组
  created_at INTEGER NOT NULL,
  FOREIGN KEY (chat_session_id) REFERENCES chat_session(id)
);
CREATE INDEX idx_review_session ON review(chat_session_id, created_at);
```

`items` JSON 数组元素结构:
```json
{
  "seq": 1,
  "question": "求 lim(x→0) sin x / x",
  "user_answer": "0",
  "verdict": "wrong",
  "analysis": "等价无穷小 sin x ~ x,极限应为 1,非 0",
  "topic_ids": [12, 34]
}
```
- `verdict`:`correct | partial | wrong`
- `topic_ids`:本题涉及的知识点/技巧 id 列表(已通过 `save_topic` 创建或命中)
- 单表 JSON 满足卡片渲染与复盘注入;将来若需按知识点聚合统计(雷达图),再拆 `review_item` 表,现阶段不做

### 新增模型类(StudyEngine)

`Review`(主记录)与 `ReviewItem`(明细,反序列化自 `items` JSON)。`ReviewRepository`:
- `Future<int> save({int? chatSessionId, required String summary, required List<ReviewItem> items})` → 返回 review_id(`chatSessionId` 可空,缺失时存 null)
- `Future<Review?> findById(int id)`
- `Future<List<Review>> findBySession(int chatSessionId)` → 按 created_at 倒序
- `items` 的 JSON 编解码在 Repository 内集中处理(模型对外暴露 `List<ReviewItem>`)

## Agent 工具设计

在现有 6 工具(`list_topics`/`search_topics`/`get_topic`/`save_topic`/`update_topic`/`link_topics`)基础上新增 3 个,`AgentTools.studyTools` 列表追加,`StudyScenario.executeTool` 加 case。

### `set_mastery` — 写掌握度(核心)

```yaml
name: set_mastery
description: |
  记录某知识点/技巧的掌握程度(基于一次作答或复习判定)。
  映射规则:全对→升一级(unknown/weak→learning、learning→mastered、mastered 保持);
  部分对→learning(已 mastered 则回退 learning);全错→weak。
parameters:
  topic_id: {type: integer, description: 知识点/技巧 id}
  status:   {type: string, enum: [learning, mastered, weak], description: 目标掌握状态}
  reason:   {type: string, description: 判定依据,如"洛必达题答错:混淆适用条件"}
required: [topic_id, status, reason]
```
- status 枚举**不含 `unknown`**:那是"从未记录"语义,不该由 agent 显式设置
- `reason` **必填**:保证每次掌握度变化可追溯诊断
- 实现:`mastery.log(topicId, status, reason: reason)`,一条日志

### `get_mastery` — 读现状

```yaml
name: get_mastery
description: 查询某知识点/技巧的当前掌握程度与最近变更历史。批改前了解现状以决定如何调整。
parameters:
  topic_id: {type: integer, description: 知识点/技巧 id}
required: [topic_id]
```
返回 JSON:
```json
{
  "topic_id": 12,
  "current_status": "learning",
  "log_count": 3,
  "recent": [{"status":"weak","reason":"...","changed_at":"..."}]
}
```
- `recent` 取最近 5 条(倒序),含 reason 历史,让 agent 知道上次为什么判定

### `save_review` — 保存批改明细

```yaml
name: save_review
description: |
  批改完成后保存结构化批改明细(逐题对错/解析/涉及知识点),供卡片展示与复盘对话。
  调用后前端会渲染一张批改卡片;用户可点进卡片查看详情、继续探讨。
  与 set_mastery 各司其职:set_mastery 写掌握度日志,save_review 写批改明细。
parameters:
  summary: {type: string, description: 批改摘要,如"批改3题,对1错2,薄弱:洛必达适用条件"}
  items:
    type: array
    description: 逐题明细
    items:
      type: object
      properties:
        seq: {type: integer}
        question: {type: string}
        user_answer: {type: string}
        verdict: {type: string, enum: [correct, partial, wrong]}
        analysis: {type: string}
        topic_ids: {type: array, items: {type: integer}}
      required: [seq, question, verdict, analysis]
required: [summary, items]
```
- 实现:`reviewRepo.save(...)`,返回 `已保存批改(共 N 题)`,review_id 回到 LLM 上下文,支持后续复盘追问
- `user_answer` 可空(纯口述题无笔答时)

### `get_topic` 不改动

保持原样,不加掌握度字段——工具单一职责,agent 需要时组合 `get_topic` + `get_mastery` 两次调用,减少对现有 6 工具的回归面。

## 提示词重写

`StudyScenario.buildSystemPrompt()` 从「分析题目/整理知识库/跟踪掌握状态」扩展为「分析题目/**批改作答**/整理知识库/**掌握度维护**」。原有「知识点粒度原则/写入前必先查/分类/关联边/经验记忆」全部保留,新增四块:

### ① 意图识别(置顶)

```
- 输入含用户作答(手写/文字答案) → 进入「批改流程」
- 纯题目(无作答) → 进入「分析流程」(原有:分析涉及的知识点并整理进知识库)
- 两者兼备 → 批改为主、分析为辅
```

### ② 批改流程(含作答时)

```
1. 逐题判定:对 / 部分对 / 错,给出解析
2. 从错误与部分对的作答中,识别暴露薄弱的知识点或技巧
3. 对每个薄弱点:search_topics 查 → 有则 get_topic+get_mastery 看现状/必要时 update_topic 补答案
   → 无则 save_topic 创建(技巧挂「技巧」分类)
4. set_mastery 维护掌握度(映射规则见 set_mastery 工具描述),reason 写明判定依据
5. save_review 保存结构化批改明细(逐题),随后引导用户点卡片查看、可追问复盘
```
> 「写入前必先查」自然融入第 3 步。

### ③ 技巧与知识点同等待遇

```
技巧也是知识:按 学科/.../技巧/<名> 挂载;有自己的引子(何时用)与答案(怎么用);
可建关联边、可设掌握度,处理方式与知识点完全一致。
```

### ④ 掌握度映射规则(提示词概述 + set_mastery 工具 description 双保险)

全对 → `unknown`/`weak`→`learning`、`learning`→`mastered`、`mastered` 保持;部分对 → `learning`(已 `mastered` 回退);全错 → `weak`。

**判定依据**:以题目要求为准判分,可参考知识库已有知识点,无标准答案时依据学科知识严谨判定(纯 LLM 推理,无需代码机制)。

## UI 设计(study_buddy,纸感)

### `_ReviewCard`(对话流内嵌)

AI 调用 `save_review` 后,对话流出现纸感批改卡片(非普通文本消息)。展示:
- 摘要:题数 / 对错比 / 薄弱点关键词
- 纸感视觉:米黄纸卡片 + 朱砂徽标(对=墨绿✓ / 部分对=朱砂◐ / 错=朱砂✗)
- 「查看详情」入口

### 详情页(全屏,push 新路由)

逐题展示:
- 判定徽标 + 题目 + 用户作答
- 解析
- 涉及知识点/技巧(可点击跳转知识点详情)+ 掌握度调整说明(如"洛必达法则:learning→weak")
- 底部输入框:走**同一个 chat session** 追加消息,不建独立会话;AI 上下文已含 `save_review` 调用历史,能直接答"第 N 题我为什么错"

### 复盘对话

= 现有多轮对话的继续,无新机制。详情页输入框即主对话的快捷入口,消息追加到同一 session,上下文连续。

## 装配点改动

`study_buddy/lib/core/providers/agent_session_provider.dart:36` 的 `StudyScenario(...)` 构造,多注入 `MasteryRepository(db)` 与 `ReviewRepository(db)`;engine 测试 `newScenario()` 同步加两个参数。

### chat_session_id 注入(接口最小扩展)

`save_review` 落库需要 `chat_session_id`,但工具参数不该让 LLM 接触(敏感且无意义)。现有 `AgentScenarioContext.extra` 是现成附加通道,但 `executeTool` 签名未透传 context——**需要一处最小接口扩展**:

1. `AgentScenario.executeTool` 增加可选参数 `AgentScenarioContext? context`(可空,现有实现零改动,向后兼容)
2. `AgentLoop.run` 已接收 `context`,在调用 `scenario.executeTool(...)` 处一并传入
3. app 层 `agent_session_provider` 调 `loop.run(messages, context: AgentScenarioContext(extra: {'chat_session_id': sessionId}))`
4. `StudyScenario.executeTool` 中 `save_review` 分支从 `ctx?.extra['chat_session_id'] as int?` 读取,透传 `reviewRepo.save(chatSessionId: ...)`
5. `chat_session_id` 缺失时(工具直调测试)review 仍可保存(列可空),卡片定位靠 `review_id`

> 该扩展同时为将来拆子 agent 预留了上下文通道。

## 前端事件流

`AgentLoop` 产生 `ToolCallEvent`/`ToolCallEndEvent`(已有事件机制)。`ai_panel_sheet` 监听工具事件:
- `save_review` 工具调用完成 → 在对话流对应位置渲染 `_ReviewCard`(替代该工具的普通 ※ 轨迹)
- 其他工具(set_mastery 等)仍走现有 `_ToolTrace` ※ 轨迹

## 分阶段交付

- **阶段 A(engine 纯行为)**:`set_mastery`/`get_mastery` 工具 + `StudyScenario` 注入 `MasteryRepository` + 提示词阶段化(意图识别置顶 + 批改流程步骤 1-4:逐题判定/薄弱诊断/先查后写/`set_mastery` 设掌握度 + 技巧同等待遇段落)。engine 内自洽,app 仅改装配。
- **阶段 B(批改工作台,engine + app)**:`review` 表迁移 + `Review`/`ReviewItem`/`ReviewRepository` + `save_review` 工具 + `executeTool` context 透传扩展 + 批改流程步骤 5(save_review + 卡片引导)+ `_ReviewCard` + 详情页 + 复盘输入。

两阶段可合并一次实现,也可分里程碑。建议合并实现(数据接缝统一),但实施计划按阶段切分 task,便于 SDD 逐 task 审查。阶段 A 可独立交付:批改流程到「设掌握度」即完成,批改结论以文本呈现;阶段 B 把结论升级为结构化卡片。

## 验证

### 测试矩阵

| 层 | 测试点 | 断言 |
|---|---|---|
| Engine | `set_mastery` 直调 | 落库 → `currentStatus` 变化 |
| Engine | `set_mastery` 覆盖 / 非法 status | 最新日志生效 / 拒绝 |
| Engine | `get_mastery` 结构 | current + recent + reason 可查 |
| Engine | 薄弱点链路 | `save_topic`→`set_mastery`(创建后设度) |
| Engine | `save_review` 直调 + `findBySession` | 批改明细持久、可查 |
| Engine | AgentLoop 端到端 mock | `set_mastery`/`save_review` 双落库 |
| Engine | 提示词断言 | 意图识别/批改流程/技巧待遇/映射规则四段存在 |
| App | `_ReviewCard` 渲染 | `save_review` 事件 → 对话流出现纸感卡片 |
| App | 详情页 | 逐题明细(徽标/解析/知识点/掌握度) |
| App | 复盘输入 | 同 session 追加,上下文连续 |
| 回归 | engine 现有测试 + app 现有测试 | 全绿 |

### 验证流程

1. `cd packages/study_engine && dart analyze` → 零 issue
2. `cd packages/study_engine && dart test` → 全绿(现有 + 新增)
3. `cd study_buddy && flutter analyze` → 零 issue
4. `cd study_buddy && flutter test` → 全绿(现有 + 新增)
5. 真机 `flutter run` 视觉验收(纸感卡片 / 详情页 / 复盘对话,亮暗两模式)

## 风险

| 风险 | 处置 |
|---|---|
| `save_review` 的 `items` 是嵌套 JSON,LLM 可能生成不规范 | 工具 description 给出明确 schema 与示例;Repository 编解码做防御性解析(缺字段给默认值);测试覆盖字段缺失场景 |
| LLM 批改判定本身可能出错(把对的判错) | 这是 LLM 能力边界,不在本次工程范围;提示词要求给出解析链路,用户可在复盘里质疑,agent 可用 `update_topic` 纠正 |
| 部分对的掌握度判定 LLM 自由发挥 | 提示词明确规则(部分对→learning),且 `set_mastery` description 内嵌映射,双重约束 |
| `save_review` 与 `set_mastery` 顺序耦合(应先设掌握度再存批改,topic_ids 才有效) | 提示词批改流程规定步骤:先 save_topic/set_mastery 落库拿到 topic_id,最后 save_review 引用 |
| review 单表 JSON 将来聚合难 | 接受当前 YAGNI;真做统计时拆 `review_item` 表 + 迁移,数据可无损升级 |
| 提示词膨胀导致 LLM 漂移 | 阶段化分段(意图识别置顶、各流程编号),`set_mastery` description 兜底映射规则;长期可在阶段 B 后评估是否拆子 agent |
