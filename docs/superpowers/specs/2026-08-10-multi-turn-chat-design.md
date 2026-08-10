# 学习伴侣 APP — 纯内存多轮对话

- **日期**: 2026-08-10
- **项目**: study_buddy（Flutter 学习伴侣 APP）
- **阶段**: 第三阶段子能力（依附于截图悬浮窗阶段，可独立交付）
- **状态**: 已确认，待实施计划
- **前置依赖**: 外部题库集成阶段（已交付 master，含 `ai_panel_sheet` 与 `agent_session_provider`）

## 1. 背景与目标

study_buddy 当前的 AI 交互是**单次任务式**：用户截图 → `ai_panel_sheet` 弹出 → 一次分析 → 关掉抽屉即失。底层 `AgentLoop` 本身支持多轮 ReAct（LLM ↔ 工具 ↔ LLM，最多 50 轮），但那是模型内部的工具调用循环，**用户层面无法追问**——每次点"开始分析"都是全新会话，AI 不知道上一轮说了什么。

本 spec 实现**纯内存多轮对话**：一次截图分析后，用户在当前抽屉内能连续追问（带上文），AI 基于完整历史回答。截图与对话全程在内存，关掉抽屉或重启 App 即失，不落库、不回看、无历史列表。

### 1.1 MVP 交付目标

构建一个**最小可演示的多轮链路**：

1. 用户截图 → `showAiPanel` 弹出 → 首条消息含截图 → AI 流式分析
2. 分析完成后，输入框变为连续聊天框 → 用户打字追问（可选点"+加图"附新截图）→ AI 带完整历史回答
3. 关闭抽屉 → 会话清空（内存释放）

### 1.2 关键约束（用户硬要求 + 技术硬约束）

| 约束 | 解读 |
|---|---|
| **纯内存，不持久化** | 截图与对话全程内存，不落库、不回看。`ChatRepository`（已建表）仍是预留件，本阶段不接入。App 重启即无历史。 |
| **截图纯内存** | 沿用原硬约束：`CapturedScreenshot`（pngBytes + base64DataUri）只活在 `ChatMessage` 的 `ImageUrlPart` 里，随会话内存释放。 |
| **引擎业务逻辑零改动** | `AgentScenario` / `StudyScenario` / 工具 / `ChatRepository` 全部不动，22 个现有测试不受影响。**允许补强 `AgentLoop` 事件流的信息完整度**（见 §3.2 解法2）——让 `AgentDoneEvent` 携带本轮 tool_calls，这是修补"事件流信息不足"的接口缺口，非业务逻辑变更。 |
| **追问可选附图** | 追问轮文字为主，可选附图（每轮 0~1 张）。换题分析可附新截图。 |
| **AgentSession 保持无状态** | 沿用其现有设计注释（不内部持有 LlmProvider/会话态）。多轮状态下沉到新的 Riverpod `StateNotifier`。 |
| **首页/路由不动** | 入口仍是 WebView 浮窗 /（未来）系统悬浮球 → `showAiPanel`。无会话列表入口。 |

## 2. 设计输入（已确认决策）

| 维度 | 决策 | 依据 |
|---|---|---|
| 会话粒度 | 一次截图分析后，**当前抽屉内**连续追问（带上文） | 用户确认（收窄范围） |
| 持久化 | **纯内存**，不落库、不回看、重启即失 | 用户确认 |
| 历史列表 | **不要** | 用户确认（撤销早期"会话列表入口"选项） |
| 首页 | **不动** | 同上 |
| 追问带图 | 文字为主，**可选附图**（每轮 0~1 张） | 用户确认 |
| 会话状态 | **Riverpod StateNotifier** 持有 `List<ChatMessage>` | 用户确认 |
| 多轮消息重建 | **解法2**：`AgentRoundEndEvent` 在工具轮末携带本轮完整消息序列，Notifier 零格式知识直接 append；纯文本轮经 `AgentDoneEvent(finalText)` 追加最终 assistant 消息 | 架构可维护性分析（见 §3.2） |

## 3. 顶层架构

纯内存多轮的核心是"把 `AgentLoop` 内部已有的消息累积能力，在 UI 层复刻一份到 Riverpod 状态"。三层职责不变，只在 App 层加一个状态层：

```
┌─────────────────────────────────────────────────────────┐
│ UI Layer  (ai_panel_sheet.dart)                          │
│   单次表单  →  消息列表 + 连续输入框 + (可选)附图按钮     │
│   读 currentChatProvider 展示历史;流式事件回填           │
└──────────────────────┬──────────────────────────────────┘
                       │ watch / read
┌──────────────────────▼──────────────────────────────────┐
│ State Layer  (chat_session_provider.dart)  ← 新增         │
│   currentChatProvider: StateNotifier<ChatSessionState>    │
│     ├ List<ChatMessage> messages   (完整多轮历史,内存)    │
│     ├ String streamingText         (当前轮流式增量缓冲)   │
│     ├ List<ToolEvent> toolEvents    (当前轮工具轨迹)      │
│     └ bool busy / error                                  │
│   方法: send(text,[image]) / clear()                     │
└──────────────────────┬──────────────────────────────────┘
                       │ read(agentSessionProvider)
┌──────────────────────▼──────────────────────────────────┐
│ Agent Layer  (agent_session_provider.dart)  ← 不动        │
│   AgentSession.run(List<ChatMessage>) → Stream<AgentEvent>│
│   (无状态,每次收完整历史;引擎业务逻辑零改动)             │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│ Engine  (study_engine)  ← 仅补强事件流                    │
│   AgentLoop.run(messages) → ReAct 循环 (已支持任意历史)   │
│   AgentRoundEndEvent(newMessages) ← 唯一引擎改动(每轮完整消息)│
└─────────────────────────────────────────────────────────┘
```

**关键设计点：**
- **`AgentSession` 保持无状态**——仍只提供 `run(List<ChatMessage>)`，符合它现有的设计注释。状态全部下沉到新的 `currentChatProvider`，职责单一。
- **状态用 `StateNotifier`**——管理复杂对象（消息列表 + 流式缓冲 + 标志位），封装 `send`/`clear` 方法比散落的 `state = state.copyWith(...)` 更清晰可测。
- **单向依赖，无循环**：`ai_panel_sheet` → `currentChatProvider` → `agentSessionProvider` → `AgentLoop`。

### 3.1 数据流（多轮时序）

**第一轮（带截图，从浮窗/悬浮球触发）**
```
① 用户点浮窗/悬浮球 → 截图 → CapturedScreenshot(bytes, dataUri)
② showAiPanel(context, screenshot)
   → currentChatProvider.notifier.send(text, image: screenshot)
③ Notifier.send:
   ├ state = state.copyWith(busy:true, 清空 streamingText/toolEvents)
   ├ userMsg = ChatMessage(role:'user', content:[
   │     TextPart(text 或 "分析这道题涉及的知识点"),
   │     ImageUrlPart(dataUri, detail:'high')])   ← 截图进 content parts
   ├ append userMsg → state.messages
   ├ runInput = [...state.messages]                ← 完整历史(首轮就这一条)
   ├ stream = agentSessionProvider.run(runInput)
   └ listen(stream): 见"事件回填"
```

**第二轮及以后（追问，文字为主可选附图）**
```
④ 用户在输入框打字 → (可选)点"+加图"附新截图
⑤ 点发送 → currentChatProvider.notifier.send(text, image: image?)
⑥ Notifier.send(与③相同):
   ├ userMsg = 文字 + (可选)ImageUrlPart
   ├ append userMsg → state.messages   ← 此时 messages 已含第①轮全部历史
   ├ runInput = [...state.messages]     ← 带完整历史给 AgentLoop(续聊关键)
   └ stream = agentSessionProvider.run(runInput)
```

> **续聊的本质**：`AgentLoop.run()` 内部 `msgs = [...messages]` 起步（`agent_loop.dart:26`），把传入的完整历史作为上下文。所以"多轮"不是引擎新能力，而是 UI 层终于把历史**喂进去**了。

### 3.2 事件回填与消息回填（AgentRoundEndEvent）

**事件流 → state 映射**
```
stream.listen:
  AgentStartedEvent     → (busy 已置 true,无操作)
  TextDeltaEvent(delta) → state.streamingText += delta     ← 实时打字效果
  ToolCallStartEvent(n,id) → toolEvents.add(ToolEvent(n,'进行中'))
  ToolCallEndEvent(n,result,id) → 更新该 ToolEvent 结果
  ToolProgressEvent(p)  → toolEvents 追加进度文本
  CompactionEvent       → toolEvents 标记"上下文已压缩"
  RetryEvent(attempt)   → toolEvents 标记"重试第 N 次"
  AgentRoundEndEvent(newMessages) → 【逐轮回填完整消息,见下】
                                   → streamingText 清空(本轮文本已入 assistant 消息)
  AgentDoneEvent(finalText) → finalText==null → maxRounds 错误(busy=false)
                             否则 busy=false + streamingText 清空
                             + append ChatMessage(role:'assistant', content: finalText)
                             ← 纯文本轮的最终回答必须落进 messages(供下一轮上下文)
  AgentErrorEvent(msg)  → state.error=msg → busy=false
```

**`AgentRoundEndEvent` 的消息回填（多轮格式正确性的关键）**

流式期间 LLM 输出的 assistant 文本和工具调用分片到达，不能边到边 append（会破坏 OpenAI 多轮格式）。引擎在**每个工具调用轮结束时**，把该轮已产出的合法消息序列一次性 yield 出来：`[assistant(含 toolCalls 与最终文本), tool(每个调用一条,含 result), ...]`。Notifier 对此零格式知识——直接把 `newMessages` append 到 `state.messages`：

```
AgentRoundEndEvent(newMessages = [assistant(含toolCalls), tool, tool, ...]):
  state.messages += newMessages     ← 引擎已保证序列合法
  streamingText 清空                 ← 本轮文本已落入 assistant 消息
```

纯文本轮不 yield RoundEnd（引擎无合法消息批需回填），但 `AgentDoneEvent(finalText)` 携带累积的最终文本：Notifier 据此 append `ChatMessage(role:'assistant', content: finalText)` 进 `state.messages`，保证纯文本轮的回答同样进入历史序列（不只"流式呈现"），下一轮 `send` 时作为完整上下文续聊。

下一轮 `send` 时，`state.messages` 已含完整合法序列，`AgentLoop.run([...messages, newUser])` 续聊。

**为什么选 AgentRoundEndEvent（架构可维护性）：**

曾考虑两条路均不可行：**解法1**（Notifier 从事件流重建消息）查证发现 `ToolCallStartEvent`/`ToolCallEndEvent` **不带 arguments**，且 `ToolCall` 模型要求 `id`/`name`/`arguments` 三字段（`models.dart:285-289`），无法重建；**解法2**（`AgentDoneEvent +toolCalls`）发现 `AgentDoneEvent` 每轮 run 只发**一次**，无法携带中间轮的工具调用，只对"单轮工具调用"有效。

最终采用 `AgentRoundEndEvent`：引擎在轮末直接产出合法消息批（含 arguments 与 result），Notifier 只做 `append`——职责分配清晰，**引擎负责消息序列合法性，Notifier 零格式知识**。这正是最初设想的最彻底形态，实现代价仅一个事件类 + 工具分支一处 yield，并未更大。

### 3.3 引擎唯一改动（AgentRoundEndEvent）

```dart
// agent_event.dart — 新增 sealed 子类
class AgentRoundEndEvent extends AgentEvent {
  final List<ChatMessage> newMessages; // [assistant(含toolCalls), tool, tool, ...]
  AgentRoundEndEvent(this.newMessages);
}
```

`AgentLoop` 改动点（`agent_loop.dart` 工具调用分支）：`for (final tc in agg)` 循环结束后，`yield AgentRoundEndEvent(roundNewMsgs)`——`roundNewMsgs` 收集本轮 assistant 消息 + 各 tool 消息。纯文本轮不 yield。

`AgentDoneEvent` **保持原样**（`AgentDoneEvent(this.finalText)`，无 toolCalls 字段）——仍只在循环末尾发一次，`finalText==null` 表示达 maxRounds。

22 个现有测试不受影响（新事件只是追加 yield，旧事件流不变）。

## 4. 组件清单

### 新增

**`study_buddy/lib/core/providers/chat_session_provider.dart`** — 多轮会话状态（核心）
```dart
class ToolEvent {
  final String name;
  final String result;  // '进行中' 或实际结果摘要
  ToolEvent(this.name, this.result);
}

class ChatSessionState {
  final List<ChatMessage> messages;   // 完整多轮历史(含首轮截图)
  final String streamingText;          // 当前轮 LLM 流式增量累积
  final List<ToolEvent> toolEvents;    // 当前轮工具轨迹
  final bool busy;                     // agent 运行中(禁用输入)
  final String? error;
  // copyWith + 初始空状态
}

class ChatSessionNotifier extends StateNotifier<ChatSessionState> {
  ChatSessionNotifier(this._ref);
  final Ref _ref;

  /// 发送一轮:组装 user 消息(文字+可选图)→ append → 调 AgentSession.run
  /// 监听 Stream 把 TextDelta/ToolCall/Done/Error 回填到 state(见 §3.2)
  /// 构造期抛错回滚 user 消息(见 §5)
  Future<void> send(String text, {CapturedScreenshot? image});

  /// 重置整个会话(抽屉关闭时调用,清空内存,取消订阅)
  void clear();
}

final currentChatProvider =
    StateNotifierProvider<ChatSessionNotifier, ChatSessionState>(...);
```
- **职责单一**：只管"当前会话的内存状态 + 事件回填"。不直接持有 LLM/scenario（仍经 `agentSessionProvider`）。
- **`send` 内部**：append user 消息 → `ref.read(agentSessionProvider).run([...state.messages])` → `listen` 事件流回填。assistant+tool 消息在 `AgentRoundEndEvent` 时逐轮批量 append（引擎已保证序列合法，Notifier 零格式知识）。

### 修改

**`study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`** — 单次表单 → 消息列表
- 移除：`_aiText` StringBuffer、`_toolEvents`、`_busy`/`_saved`/`_errorText`、`_runAgent()` 里的流式监听（全部上移到 notifier）
- 移除：`_inputCtrl` 的"补充说明(可选)"单次语义 → 改为连续聊天输入框
- 新增：消息列表渲染（`ListView` of user/assistant 气泡，assistant 气泡下方挂工具轨迹 + streamingText）
- 新增："+ 加图"按钮（追问轮可选附图，首轮图来自截图入口）
- `showAiPanel` 入口签名不变（仍收 `CapturedScreenshot`），内部把首张图作为第一条 user 消息注入，交给 `currentChatProvider`
- 抽屉关闭 → `ref.read(currentChatProvider.notifier).clear()`

**`study_buddy/lib/core/providers/agent_session_provider.dart`** — 零改动
- `run(List<ChatMessage>)` 直接透传给 `AgentLoop.run`，本来就收完整列表。保持无状态。

### 不改动

- **引擎业务逻辑**：`AgentScenario` / `StudyScenario` / 工具 / `ChatRepository`（虽存在但不接入）全部不动。
- **首页/路由**：`home_page.dart`、`router.dart` 不动。
- **`webview_screenshot_provider.dart`**：`CapturedScreenshot` 类定义不动（第三阶段悬浮窗会迁移它，与本 spec 无关）。

## 5. 错误处理与边界

| 场景 | 处理 | 状态影响 |
|---|---|---|
| **追问时 agent 仍在运行**（连点发送） | `send()` 首行 `if (state.busy) return;` 守卫 | 无 |
| **LLM 调用失败**（AgentErrorEvent） | `state.error=msg`、`busy=false`；**不 append assistant 消息**；用户可重新发送 | user 消息已在历史中保留（见下说明） |
| **构造期抛错**（如未配 vision LLM，`run()` 抛 StateError） | catch → `state.error`、`busy=false`、`state.messages.removeLast()` **回滚**刚 append 的 user 消息 | user 消息回滚，上下文干净 |
| **流 onError** | 同 AgentErrorEvent 路径 | 同上 |
| **用户发送空文本且无图** | `send()` 前置校验直接 return，不 append | 无 |
| **CompactionEvent**（会话过长） | 引擎内部已压缩；Notifier 只在 toolEvents 标记，`state.messages` **不删**（它是下一轮 run 入参，引擎自己处理压缩） | 无 |
| **达到 maxRounds（50）** | `AgentDoneEvent(null, [])` → `finalText==null` 时不 append assistant 消息，只置 `busy=false` + `error="已达最大轮数"` | 无消息污染 |
| **抽屉中途关闭**（agent 仍在流式） | `clear()` 取消 StreamSubscription + 重置 state；AgentLoop 流因无订阅者自动取消（纯 async*，GC 回收） | 干净 |
| **App 重启** | provider 重建即初始空状态 | 无历史（符合纯内存） |

**失败回滚策略说明：**
- **构造期抛错**（`run()` 调用就炸，未产生任何事件流）：回滚 user 消息。因为此时上下文未被污染，回滚后用户重发时历史干净。
- **运行期失败**（`AgentErrorEvent`，assistant 可能已部分生成）：**不回滚**。因为 user 消息已进入历史，assistant 部分文本在 `streamingText`（未入 messages）——此时历史只有 user，是合法的"用户问了但 AI 没答完"状态。用户重发会再 append 一条 user（本 spec 不做"上条未完成"UI 提示，保持简单）。回滚反而会导致"用户看到自己发了消息但历史里没有"的错乱。

## 6. 测试策略

| 层 | 策略 | 数量预估 |
|---|---|---|
| **引擎** | 22 个现有测试全绿（硬约束验证）；**新增 2 个**：mock LLM 返回工具调用 → 断言 `AgentRoundEndEvent.newMessages` 携带 assistant(含 toolCalls)+tool 消息；mock LLM 无工具调用 → 断言不 yield RoundEnd | +2 |
| **Notifier 单元** | `ChatSessionNotifier` 用 mock `AgentSession`（返回预制事件流）测：① 首轮带图 → messages 含 user+assistant；② 二轮续聊 → run 入参含完整历史；③ 工具调用轮 → 经 RoundEnd 后 messages 含 assistant(含 toolCalls)+ tool 消息；④ busy 守卫；⑤ 构造期抛错回滚；⑥ clear() | ~7 |
| **Widget** | `ai_panel_sheet`：① 首轮截图预览 + 发送；② 追问输入框 + 加图按钮；③ 消息列表渲染 user/assistant 气泡；④ busy 时输入禁用；⑤ 流式 streamingText 实时显示 | ~4 |
| **不写** | 真实 LLM 集成（manual）；引擎 ReAct 循环（已有覆盖） | — |

测试关键点：Notifier 单元测试用 **mock AgentSession**（不碰真 LLM/DB），只验证"事件 → state.messages"的映射逻辑——这正是多轮格式正确性的核心。

## 7. 范围控制（MVP 不做）

- ❌ 对话历史持久化（`ChatRepository` 不接入，纯内存）
- ❌ 历史会话列表 / 回看 / 续聊旧会话
- ❌ 首页会话入口
- ❌ 追问轮多图（每轮最多 1 张）
- ❌ 删除/编辑已发送消息
- ❌ 会话标题生成
- ❌ 跨会话上下文记忆（`agent_memory` 表已有，但本阶段不联动）

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 多轮消息格式不合法导致下一轮 LLM 报错 | `AgentRoundEndEvent` 由引擎在轮末产出完整合法消息序列（assistant 含 toolCalls/arguments + 逐条 tool 消息带 result），Notifier 零格式知识直接 append；Notifier 单元测试覆盖回填逻辑 |
| 长会话上下文膨胀 | 引擎 `ContextCompactor` 已有压缩机制；Notifier 不干涉，`CompactionEvent` 仅展示提示 |
| 截图随多轮累积占内存 | 纯内存设计，抽屉关闭即 `clear()` 释放；单会话内图片数量由用户控制（每轮最多 1 张） |
| `AgentRoundEndEvent` 新增破旧测试 | 新事件只在工具轮追加 yield，旧事件流不变；sealed `AgentEvent` 下游 switch 须补分支（Task 3 重写 `ai_panel_sheet.dart` 时已覆盖）；22 测试回归验证 |
| 抽屉关闭时流未取消 | `clear()` 显式 cancel StreamSubscription；AgentLoop 纯 async* 无订阅者自动取消 |

## 9. 硬约束自检

1. **纯内存，不持久化**：`ChatRepository` 不接入，`chat_session`/`chat_message` 表仍为预留件。截图与对话随 `currentChatProvider` 内存生命周期，`clear()` 即清。
2. **引擎业务逻辑零改动**：`AgentScenario`/`StudyScenario`/工具/`ChatRepository` 不动，22 测试通过。唯一引擎改动是新增 `AgentRoundEndEvent` 事件类 + 工具分支一处 yield（事件流信息补强，非业务逻辑）。`AgentDoneEvent` 保持原样。
3. **截图纯内存**：`CapturedScreenshot` 只活在 `ChatMessage` 的 `ImageUrlPart`，随会话内存释放，不落盘不入库。
4. **AgentSession 保持无状态**：`run(List<ChatMessage>)` 不变，多轮状态下沉到 `currentChatProvider`。

---

**下一步**：spec 自审 → 用户审阅 → 调用 writing-plans 生成实施计划（按引擎补强 + Notifier + UI 改造 + 测试拆任务，SDD 执行）。
