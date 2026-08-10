# 知识点详情页 AI 深度交流 — 设计文档

## 1. 目标

在知识点详情页(`TopicDetailPage`)提供「问 AI」入口,点击弹出底部抽屉,与 AI 就当前知识点进行**多轮持久化深度交流**:AI 自动感知当前知识点(免用户复述),可读相关知识点辅助讲解,可将交流成果(update_topic / link_topics)沉淀回知识库。每个知识点绑定一条持久会话,再次进入可接着聊。

## 2. 背景

现有 AI 交互(`ai_panel_sheet.dart`)是**截图驱动 + 单轮 + 纯内存**——截图触发、一次问答、关闭即失。本需求是另一种模式:**知识点驱动 + 多轮 + 持久化**。

既有可复用基建:
- `AgentLoop.run(messages, {context})` 原生支持多轮(调用方维护 `List<ChatMessage>` 历史)与 `AgentScenarioContext` 动态注入。
- `AgentSession.run(messages)` 是 App 层无状态入口,**未透传 context**——需扩展。
- `StudyScenario` 已有 `get_topic`/`search_topics`/`list_topics`/`update_topic`/`link_topics`/`save_topic` 工具。
- `StudyScenario.buildSystemPrompt(ctx)` 已读 `ctx.extra` 做注入。
- `ChatRepository` 有 `createSession`/`addMessage`(只写),底层 `chat_session` + `chat_message` 表已建,但**无读取方法、`chat_session` 无 `topic_id`**。

## 3. 设计决策(已与用户确认)

| 决策项 | 选择 |
|---|---|
| 会话作用域 | 每知识点持久化会话(`chat_session` 关联 `topic_id`) |
| 交互形态 | 底部 Modal 抽屉(复用 `ai_panel_sheet` 机制) |
| 上下文注入 | 抽屉打开时自动注入当前知识点到 system prompt(免复述) |
| AI 能力边界 | 读 + 改当前点(`update_topic` / `link_topics`),**不含 `save_topic` 新建** |
| 改动知情度 | 静默生效 + 工具调用轨迹可见(沿用 `ai_panel_sheet` 的 `_toolEvents` + 绿色提示) |
| 持久化时机 | 每轮对话结束实时写库(`addMessage` user + assistant) |

## 4. 架构

### 4.1 数据流

```
TopicDetailPage(topicId)
   │ 点击「问 AI」
   ▼
TopicChatSheet(topicId)
   │ 1. ChatRepository.findOrCreateByTopic(topicId, title) → sessionId
   │ 2. ChatRepository.listMessages(sessionId) → List<ChatMessage>(历史)
   │ 3. 构造 AgentScenarioContext(extra: {'current_topic': {...知识点快照...}})
   ▼
用户输入 → messages.add(userMsg) → AgentSession.run(messages, context: ctx)
   │ 流式 AgentEvent
   ▼
TextDelta → 实时追加到当前 AI 气泡
ToolCallEnd(update_topic) → 绿条「✎ 已更新答案」+ 标记详情页待刷新
ToolCallEnd(link_topics)  → 绿条「✓ 已建关联」
AgentDone → addMessage(sessionId, userMsg) + addMessage(sessionId, assistantMsg)
```

### 4.2 组件

- **`TopicChatSheet`**(新建,App 层 `features/knowledge/topic_chat_sheet.dart`):`ConsumerStatefulWidget`,持有 `topicId`、`sessionId`、`List<ChatMessage> _history`、`List<_Bubble>` 渲染列表、输入框、流订阅。`showTopicChat(context, {required int topicId, required String title})` 入口。
- **`TopicDetailPage`**(改造):summary 区下方加「问 AI」按钮,点击调 `showTopicChat`。
- **`ChatRepository`**(扩展,引擎层):加 `findOrCreateByTopic` / `listMessages`;`createSession` 加可选 `topicId` 参数。
- **`AgentSession.run`**(扩展,App 层):加可选 `context` 参数透传给 `AgentLoop.run`。
- **`StudyScenario.buildSystemPrompt`**(增强,引擎层):读 `ctx.extra['current_topic']`,追加「当前知识点」一节。

### 4.3 AgentLoop 前置修复(load-bearing)

**现状缺陷**:`AgentLoop.run(messages, {context})` 接收 `context` 但**从未使用**;`scenario.buildSystemPrompt(ctx)` 与 `scenario.getMemories()` 在整个 engine 中**无任何调用方**。`LlmProvider.chatStreamWithTools` 只把传入的 `messages` 原样发给 LLM,因此 system prompt 从不注入——现有截图悬浮窗场景的 AI 也从未收到 `StudyScenario.buildSystemPrompt` 的约束与记忆。

**修复**:`AgentLoop.run` 在循环前构造 system 消息并插入 `msgs` 首位:

```dart
Stream<AgentEvent> run(List<ChatMessage> messages, {AgentScenarioContext? context}) async* {
  yield AgentStartedEvent();
  final msgs = [...messages];
  // 前置修复：注入场景 system prompt（含 context 动态信息）
  if (msgs.isEmpty || msgs.first.role != 'system') {
    final sysPrompt = scenario.buildSystemPrompt(context ?? const AgentScenarioContext());
    msgs.insert(0, ChatMessage(role: 'system', content: sysPrompt));
  }
  ...
}
```

- 若调用方已传 system 消息则不再注入(向后兼容既有测试与用法)。
- `buildSystemPrompt` 内部负责 `getMemories()` 填充记忆块(需在 prompt 构造时同步调用 `getMemories()` 缓存)。
- 该修复同时激活既有死代码 `buildSystemPrompt`/`getMemories`,对截图悬浮窗场景是改善(恢复知识点粒度约束与经验记忆)。

### 4.4 UI/UX

抽屉布局(自上而下):
1. 抓把手(40×4 灰条)。
2. 当前知识点标题条(让用户知道在聊哪个点,可点击关闭抽屉回详情页看原文)。
3. 消息列表(`ListView.builder`,历史 + 当轮):AI 气泡左灰底圆角、用户气泡右绿底圆角;工具调用穿插小字「→ 调用工具:get_topic」「← 结果摘要」;`update_topic`/`link_topics` 成功后显示绿条「✎ 已更新答案」「✓ 已建关联」。
4. 底部输入框(`TextField` 多行)+ 发送按钮(`FilledButton`);AI 思考中禁用输入 + 显示"思考中..."。

详情页:「问 AI」按钮置于 summary 区下方,`FilledButton.tonalIcon`(icon `Icons.chat`)。

### 4.4 错误处理

- **LLM 未配置 vision 默认项**:`AgentSession.run` 抛 `StateError` → 抽屉 catch → 错误条「未配置支持视觉的默认 LLM」+ 引导(不做配置 UI,沿用既有引导)。
- **流 `onError`**:错误条 + 「重试」按钮(重发上一条 user 消息)。
- **读历史失败**(`listMessages` 抛错):当作空历史继续(不阻断新对话),SnackBar 提示。
- **写消息失败**(`addMessage` 抛错):SnackBar 提示,但内存 `_history` 仍保留(本轮对话不丢)。
- **`mounted` 守卫**:所有异步回调在每个 await 后 `if (!mounted) return;`(沿用 `ai_panel_sheet` 模式)。

## 5. 数据模型与迁移

### 5.1 v4 迁移

```sql
ALTER TABLE chat_session ADD COLUMN topic_id INTEGER REFERENCES topic(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX idx_chat_session_topic ON chat_session(topic_id);
```

- `topic_id` 可空(兼容未来无主题会话)。
- `UNIQUE(topic_id)` 保证一知识点最多一会话,支撑 `findOrCreateByTopic` 原子语义。
- `ON DELETE SET NULL`:知识点删除时会话保留(可追溯)。
- 依赖既有 `PRAGMA foreign_keys = ON`(`database.dart` onConfigure),不得移除。

`kCurrentDbVersion` → 4,`database_migrations.dart` 加 `case 4: _v4(batch)`。

### 5.2 ChatRepository 扩展

```dart
/// 创建会话。topicId 可空(向后兼容既有调用)。
Future<int> createSession(String scenarioId, String title, {int? topicId}) async { ... }

/// 按知识点查会话,无则创建。利用 UNIQUE(topic_id) 做原子语义。
Future<int> findOrCreateByTopic(int topicId, String title) async {
  final rows = await _db.db.query('chat_session',
      where: 'topic_id = ?', whereArgs: [topicId], limit: 1);
  if (rows.isNotEmpty) return rows.first['id'] as int;
  try {
    return await createSession('study', title, topicId: topicId);
  } catch (e) {
    // 并发下另一会话已建同 topic_id → UNIQUE 冲突 → 再查一次
    if (e.toString().contains('UNIQUE constraint failed')) {
      final r = await _db.db.query('chat_session',
          where: 'topic_id = ?', whereArgs: [topicId], limit: 1);
      if (r.isNotEmpty) return r.first['id'] as int;
    }
    rethrow;
  }
}

/// 读某会话全部消息,按 created_at 正序,反序列化回 List<ChatMessage>。
Future<List<ChatMessage>> listMessages(int sessionId) async { ... }
```

`addMessage` 已存在且序列化 content/tool_calls,直接复用。

### 5.3 AgentSession.run 扩展

```dart
Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {AgentScenarioContext? context}) async {
  ...
  return loop.run(messages, context: context);
}
```

`AgentLoop.run` 已支持 `context`,引擎循环逻辑不改。

### 5.4 StudyScenario.buildSystemPrompt 增强

读 `ctx.extra['current_topic']`(Map: id/title/path/question/summary/edges),在现有 prompt 追加:

```
## 当前知识点(用户正在查看)
- 标题:{title}
- 路径:{path}
- 引子:{question}
- 原文:{summary}
- 关联:{edges}

用户想就这个知识点深入交流。你可 get_topic/search_topics 查相关知识点辅助讲解,
可用 update_topic 补充/修正当前知识点原文,可用 link_topics 建关联边。
```

无 `current_topic` 时跳过该节(兼容截图悬浮窗等无主题场景)。

## 6. 测试策略

### 6.1 引擎层

- **`ChatRepository`**:`findOrCreateByTopic`(首次建、二次复用、并发 UNIQUE 兜底)、`listMessages`(空、多条、反序列化含 tool_calls 的 assistant 消息)、`createSession` 带/不带 topicId。
- **v4 迁移**:`topic_id` 列存在、UNIQUE 索引存在、旧库升级不丢数据。
- **`buildSystemPrompt`**:有 `current_topic` 时 prompt 含标题/路径/原文;无时不含该节。

### 6.2 App 层

- **`TopicChatSheet`**:打开加载历史(有/无)、首轮注入上下文、多轮往返(发→收→发)、工具轨迹显示(update_topic 绿条)、AgentDone 后写库(断言 `addMessage` 被调)。
- **`TopicDetailPage`**:「问 AI」按钮存在、点击弹出抽屉。

## 7. 约束

- 引擎 `packages/study_engine/` 零 Flutter 依赖,不得引入。
- `PRAGMA foreign_keys = ON` 不得移除。
- Riverpod 3.3.2:`ref.watch(provider).when(...)`;不暴露 `.when` 于 provider 对象。
- `AgentSession.run` 保持无状态(每次重建 LlmProvider/Scenario/Loop);多轮历史由调用方(`TopicChatSheet`)维护。
- commit 带 `Co-Authored-By: Claude <noreply@anthropic.com>` trailer。

## 8. 范围外

- 不做会话列表/历史浏览页(只"进入知识点→接着聊")。
- 不做会话删除 UI(留待后续)。
- 不引入 `save_topic`(新建知识点仍走截图悬浮窗场景)。
- 不做 LLM 配置 UI(沿用既有引导)。
