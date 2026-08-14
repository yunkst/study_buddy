# 设计文档：知识卡【为什么？】—— 等待态跳转 + 专属教学会话持久化

日期：2026-08-13
状态：已与用户逐节确认 ✅

## 背景与目标

现有【为什么？】（commit `8b85087`）点击后**立即**跳转全屏 `/ai` 页，随后
`startTopicTeaching` 无条件 `clear()` 主线会话 + 每次重新发开场消息。用户反馈三个痛点：

1. 点击后直接跳转，AI 尚未开口，进页面对的是空态/思考态，体验断裂。
2. 教学会话与主线共用 `currentChatProvider`，`clear()` 会清掉主线「问 AI」对话。
3. 教学会话与知识点无持久化关联（`chat_session` 表无 topic 字段），App 重启或
   「新对话」后丢失；每次点【为什么？】都重新发起 LLM，无法回看上次讲解。

目标行为（用户确认）：

- 点【为什么？】→ 按钮变「正在思考怎么和你解释..」（loading），**不立即跳转**。
- AI **开始返回内容（首个文字 token）** → 才跳转 AI 聊天页，**顶部常驻知识卡**。
- 教学会话是**全新专用上下文**，与主线「问 AI」会话**完全隔离、互不覆盖**。
- 教学会话**持久化**到该知识点；下次点【为什么？】→ **直接展示上次记录，不再请求 LLM**，并可在上次上下文上**继续追问**。

## 现状（作为设计基线）

- 详情页按钮：`topic_detail_page.dart:168` `FilledButton.tonalIcon` → `showAiPanel(context, topicId)`。
- `showAiPanel`（`ai_panel_sheet.dart:53`）→ `context.push('/ai', extra: AiPanelLaunch(topicId))`。
- `AiChatPage.initState` postFrameCallback → `currentChatProvider.notifier.startTopicTeaching(topicId)`
  （`chat_session_provider.dart:271`）= `clear()` + 内存态 `_teachingTopicId` + `send(_teachingOpeningPrompt)`。
- 会话持久化：`chat_session(id, scenario_id='study_plan', title, created_at, updated_at)` +
  `chat_message`。`ChatRepository` 提供 `createSession / appendMessages / loadMessages /
  latestSession / touchSession`。
- Agent：`AgentSession.run(msgs, chatSessionId, topicId)` 已有 topicId 参数，从 DB 读
  Topic 拼 `topic_context` 注入 system prompt（`DefaultPromptResolver` 条件渲染教学段）。
- 事件流：`TextDeltaEvent`（每 token）为「AI 开始返回内容」信号；`AgentStartedEvent`
  在文本之前；`AgentRoundEndEvent / AgentDoneEvent` 触发落库。
- 迁移版本当前 v10。

## 方案选型

教学会话与主线的隔离方式，两个候选：

- **方案 A：独立教学 Provider（采用）** — 新增全局 `topicTeachingProvider`
  （`ChatSessionNotifier` 实例，构造参数绑定 `topicId`）。主线 `currentChatProvider` 不动；
  `AiChatPage` 按 `initialTopicId` 编译期选定 watch 目标。教学会话写 `chat_session.topic_id`，
  主线 `hydrate()` 只取 `topic_id IS NULL`。
- 方案 B：单 provider 内按 topic 压栈切换 — 改动小但状态切换/暂存易错、clear/hydrate 语义被
  污染。**不采用**。

## 详细设计

### 1. 数据与持久化

**迁移 v11**（`packages/study_engine/lib/src/db/database_migrations.dart`）：

```sql
ALTER TABLE chat_session ADD COLUMN topic_id INTEGER;
```

`topic_id` 可空：`NULL` = 主线普通会话；非空 = 该知识点的专属教学会话（每 topic 至多一条）。

**`ChatRepository` 扩展**：

- `createSession(String scenarioId, String title, {int? topicId})` — 写入 `topic_id`。
- `latestSession(String scenarioId)` — 加 `topic_id IS NULL` 过滤（主线恢复不受教学会话污染）。
- `findTeachingSession(int topicId)` — `scenario_id='study_plan' AND topic_id=?` 按
  `updated_at DESC` 取最近一条；命中即复用，未命中返回 null。

**`ChatSessionNotifier` 改造**：

- 内存态 `_teachingTopicId` 改为 `int? _topicId`（**可变实例字段**：`startTeaching(topicId)`
  时设置、`clear()` 时重置——两个 provider 实例同构，且支持在不同知识点间切换教学）。
  `_initSession` 透传 `_topicId` 给 `createSession`；`send` 透传 `_topicId` 给
  `AgentSession.run`。**删除**旧 `_teachingTopicId`。
- 主线实例 `hydrate()` 用过滤后的 `latestSession`。

### 2. 启动流程与等待态

**核心变化：教学启动逻辑从 `AiChatPage` 移到详情页**。`AiChatPage` 进入时只负责展示
（会话已在后台运行或恢复完成）。

**`ChatSessionNotifier.startTeaching(int topicId)`**：

```dart
Future<void> startTeaching(int topicId) async {
  _sessionId = null;
  final restored = await _tryRestoreTeaching(topicId); // findTeachingSession + loadMessages
  if (restored) return;                                // ← 下次点击：零 LLM 调用
  final firstToken = Completer<void>();
  _firstToken = firstToken;
  unawaited(send(_teachingOpeningPrompt)); // 后台跑完整一轮
  await firstToken.future;                 // 等首个文字 token 即 resolve（不等整轮）
}
```

- `send()` 内部：收到 `TextDeltaEvent` 时 complete `_firstToken` Completer；
  `startTeaching` await 它（而非整轮 `done.future`）。恢复路径无流，直接 return。
- 错误路径：`send` 构造期抛错 / `AgentErrorEvent` → `_firstToken` completeError →
  `startTeaching` 抛出 → 详情页捕获恢复按钮。`unawaited(send(...))` 的 future 需
  `.catchError` 兜底，避免未处理异常（`_firstToken` 的 completeError 由 `_onEvent` /
  `send` 内部完成）。
- 恢复时该会话存在但**无消息** → 视为无历史，走开场路径。

**详情页按钮**（`topic_detail_page.dart`）：

```dart
// 局部状态 _teachingPhase: idle / starting
onPressed: _teachingPhase == starting ? null : () async {
  setState(() => _teachingPhase = starting);          // icon→小号 loading，label→「正在思考怎么和你解释..」
  try {
    await ref.read(topicTeachingProvider.notifier).startTeaching(widget.topicId);
    if (!context.mounted) return;
    await showAiPanel(context, topicId: widget.topicId); // 此时再跳转
    setState(() => _teachingPhase = idle);
  } catch (_) {
    if (!context.mounted) return;
    setState(() => _teachingPhase = idle);
    // SnackBar 提示失败，按钮恢复可点
  }
}
```

- loading 期 `onPressed: null` 防重复点击。
- 等待中用户返回（Navigator pop）：`context.mounted` 拦截跳转；后台教学会话继续跑并正常
  落库，下次进入仍可见（无害）。

**`AiChatPage` 调整**：

- 不再在 initState 调 `startTopicTeaching`。改为：`initialTopicId != null` 且
  `topicTeachingProvider` 处于空态（无历史且无进行中流）时，postFrameCallback 兜底调
  `startTeaching`（覆盖深链/分享直达 `/ai` 的边界）；已在流式中则直接展示 streamingText。
- `initialTopicId == null`（主线）才 `hydrate()` 主线；教学路径由教学 provider 自己恢复历史，
  不碰主线 hydrate。

### 3. AI 页顶部知识卡 + 历史展示/追问

**知识卡组件**（新私有 widget，`ai_panel_sheet.dart` 内）：

- 默认展开：标题 + 引子（截断 2 行）+ 答案（截断 2 行）；右上箭头折叠成一行标题条，再点展开。
- 点卡片主体 → 跳回详情页 `/topic/:id`（与现有 `_EdgeChip` 同模式）。
- 引子/答案剥 Markdown 记号后 `Text` 截断（`maxLines` + `ellipsis`），不引入完整渲染。
- 数据来源：`initialTopicId` + `TopicRepository.findById`（FutureBuilder；加载中显示标题占位）。
- 仅当 `initialTopicId != null` 时渲染。

**历史展示与续聊**：

- 复用历史后 `_buildMessage` 全量渲染上次消息（user / assistant / tool），渲染零改动。
- 输入框**可用**：发新消息 → `notifier.send(text)` → 用**上次会话上下文**（同一 sessionId +
  topicId）继续，开场指令不重复。
- 教学「新对话」按钮行为不变（clear 教学会话）；主线不受影响。

### 4. 错误处理、边界与测试

**错误/边界**：

1. 首次启动失败 → 按钮恢复可点 + SnackBar 提示（`send` 现有回滚逻辑保留）。
2. 等待中返回 → 不跳转；后台继续落库。
3. 深链/分享直达带 topicId → AiChatPage 兜底启动。
4. loading 期防重复点击。
5. 空历史会话 → 走开场路径。
6. 主线恢复过滤 `topic_id IS NULL`。
7. Riverpod 3 构建期约束：`topicTeachingProvider` 实例化不发请求；`startTeaching` 均由
   用户点击/首帧回调触发。

**测试策略**（沿用现有 fake `AgentSession` 模式）：

- Repository：`createSession` 带/不带 topicId；`latestSession` 过滤教学会话；`findTeachingSession` 命中/未命中。
- Notifier：`startTeaching` 有历史 → 不调 LLM、直接 resolve；无历史 → 发开场 + 首个
  `TextDeltaEvent` 才 resolve；失败 → 抛错；`send` 透传 topicId。
- 详情页：点为什么 → 按钮变 loading 且禁用；resolve 后 push `/ai`；失败恢复可点。
- AiChatPage：`initialTopicId` 渲染可折叠知识卡（展开/折叠）；历史正常渲染；续聊复用同一会话；
  教学不 hydrate 主线。
- 迁移：v11 对旧库升级兼容。

## 改动文件清单

| 文件 | 改动 |
|---|---|
| `packages/study_engine/lib/src/db/database_migrations.dart` | v11：`chat_session` 加 `topic_id` |
| `packages/study_engine/lib/src/repos/chat_repository.dart` | `createSession`+topicId；`latestSession` 过滤；`findTeachingSession` |
| `study_buddy/lib/core/providers/chat_session_provider.dart` | `_teachingTopicId`→可变 `_topicId`；`startTeaching`；首个 token 信号；新增 `topicTeachingProvider` |
| `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart` | provider 切换（~10 处 `currentChatProvider`→`chatProvider`）；顶部知识卡；hydrate 区分；兜底启动 |
| `study_buddy/lib/features/knowledge/topic_detail_page.dart` | 按钮 loading 态 + `startTeaching` + 条件跳转 |
| 相关测试 4-5 个文件 | 按测试策略更新/新增 |

## 不做的事（YAGNI）

- 不新建 `topic_teaching` 表（复用 `chat_session.topic_id`）。
- 不做多教学会话并存（每 topic 一条，复用最新）。
- 不给教学会话单独 scenario（沿用 `study_plan` + `topic_context` 教学段）。
- 不加跳转超时（失败即恢复按钮；如后续需要可加宽松兜底）。
