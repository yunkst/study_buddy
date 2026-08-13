# Study Buddy 架构债重构：统一对话 + 拆上帝文件 + 依赖清理

> 设计日期：2026-08-13
> 状态：已批准，待实施计划
> 前置：agent 融合已合入 master（`2f2495e`，`StudyScenario`+`PlanScenario` → `StudyPlanScenario`，app 侧统一为 `agentSessionProvider`）

## 1. 背景与问题

引擎层 agent 已融合为单一 `StudyPlanScenario`（24 工具），app 侧 provider 也已统一为单一 `agentSessionProvider`（`planSessionProvider` 已删除）。但 app 消费层仍残留两处重复：

1. **两套 agent 状态机并存**：`chat_session_provider.dart` 的 `ChatSessionNotifier._onEvent`（L135-202，12 分支 switch）与 `plan_chat_sheet.dart` 的 `_PlanChatSheetState`（L33-166，11 分支 switch）逐行重复。引擎新增事件需同步改两处。
2. **plan 专属对话入口**（`plan_chat_sheet.dart`，底部弹窗）与统一 AI 对话页（`/ai`）形态分裂，产品上"问 AI"与"计划对话"两个入口割裂，agent 能力本已融合却被人为拆成两个 UI。

此外有三处独立积债：

3. **上帝文件**：`external_qbank/ai_panel_sheet.dart` 1256 行 = `AiChatPage` 状态机 + 12 个私有 widget + 一个独立页面 `ReviewDetailPage`（未注册路由，靠 `Navigator.push` 压栈，且 `TextEditingController` 在 build 里创建从不 dispose——内存泄漏）。
4. **循环 import + 全局静态**：`app.dart` ↔ `main.dart` 双向循环引用（仅为取 `PendingScreenshotStore`）。
5. **版本号硬编码**：`settings_page.dart:410,451` 硬编码 `'0.1.0-preview.6'`（pubspec 已到 `0.1.0-preview.8`），用户可见过期版本，且无单一常量源。

## 2. 设计目标

- **统一对话界面**：删除 plan 专属对话入口，所有 AI 交互（问 AI、拍题、批改、计划创建/调整）统一走 `/ai` 全屏对话页；只剩一套 `ChatSessionNotifier` 状态机。
- **透明注入**：从计划详情页进入对话时，AI 静默获知当前计划上下文（借鉴 hermes-agent `_prepend_note_to_message` 的"追加注入"模式），不改 system prompt、不分场景分支、不注入 system message（保护 prompt cache）。
- **消除上帝文件**：`ai_panel_sheet.dart` 拆为多个职责单一文件，`ReviewDetailPage` 入路由，修内存泄漏。
- **消除循环 import 与过期版本号**。

## 3. 透明注入机制（核心设计）

### 3.1 原理（镜像 hermes `_prepend_note_to_message`，cli.py:3237）

hermes 的做法：不碰 system prompt、不设场景分支、不注入 system message（注释明言 "avoid injecting system messages mid-history which breaks providers and prompt caching"）。上下文作为一条一次性 note 前置到下一条 user 消息的文本里：

```
note（用户不可见） + "\n\n" + user 消息原文
```

note 是普通文本（`[Note: ...]` 前缀），随这条 user 消息一起进入历史，随消息持久化。触发方只往一个 `_pending_*_note` 字段写一句话；真正发送时统一消费、随即清空（一次性）。

### 3.2 改动：`ChatSessionNotifier` 增加 note 通道

文件：`study_buddy/lib/core/providers/chat_session_provider.dart`

- 新增私有字段 `String? _pendingContextNote`。
- 新增公开方法 `void injectContextNote(String note)`：`_pendingContextNote = note`（后写覆盖先写）。
- 修改 `send(String text, {CapturedScreenshot? image})`：构造 `userContent` 时，若 `_pendingContextNote != null`，把 note prepend 到首个 TextPart 文本前（`'$note\n\n$text'`），随后置 `_pendingContextNote = null`（一次性消费）。
  - 现状 L79-82：`TextPart(trimmed.isEmpty ? '分析这道题涉及的知识点' : trimmed)`。注入后 `text` 取 `trimmed.isEmpty ? '分析这道题涉及的知识点' : trimmed`，再拼 note。
  - `send` 早退分支（L77 `if (trimmed.isEmpty && image == null) return;`）不消费 note——note 保留到真正发送。
- 修改 `clear()`（L230-241）：追加 `_pendingContextNote = null`，避免"进对话不发消息直接退出"后残留。
- **`send` 签名不变**，外部调用方零改动。

### 3.3 入口收口

**删除** `study_buddy/lib/features/plan/plan_chat_sheet.dart`（含 `showPlanChat` 与 `_PlanChatSheet`）。

| 调用点 | 现状 | 改后 |
|---|---|---|
| `today_page.dart:81`（"还没有学习计划，去创建"，`onEmptyCreate`） | `await showPlanChat(context); ref.invalidate(planListProvider)` | `context.push('/ai')`；返回后 `ref.invalidate(planListProvider)`（对话可能创建了计划，刷新列表）。无需 note——新建场景由 agent 自主引导收齐字段。 |
| `plan_detail_page.dart:27`（AppBar "和 AI 调整"按钮） | `await showPlanChat(context, planId, planName); ref.invalidate(...)` | 拼装当前计划 note → `ref.read(currentChatProvider.notifier).injectContextNote(note)` → `context.push('/ai')`；返回后 `ref.invalidate(planDetailProvider(planId))`（对话可能改了计划）。 |

**note 拼装**（`plan_detail_page.dart` 内新增私有函数，数据源 `planDetailProvider(planId)` 的 `PlanDetail`）：

```
[Note: 用户正从学习计划的详情页发起对话，当前计划如下——
计划「<name>」（id=<id>）
考试：<examDate>，目标：<target>，每日时长：<dailyMinutes> 分钟
里程碑：<每行 "- M/D <title> [pending|done]">
最近测评：<score>（<note>）或无
用户接下来想围绕这个计划沟通（调整节点 / 每日任务 / 测评等）。]
```

拼法对齐 `agent_session_provider.dart:56-67` 的 `planSummary` 格式。`agent_session_provider.run` 的 `planId` 参数**保留不动**（服务层能力），UI 不再传；计划上下文职责由 note 接管。

### 3.4 清理注释

- `core/widgets/ask_user_input_semantics.dart:9-10`：注释称"两个 sheet（ai_panel_sheet、plan_chat_sheet）共享"→ 改为仅 ai_panel_sheet 使用。
- `features/plan/day_task_calendar.dart:266`：注释提及 `showPlanChat` → 清理。

## 4. 拆 ai_panel_sheet.dart（1256 行 → 8 文件）

同目录拆分，**不改 `external_qbank` 目录名**（避免牵动所有 import，与拆文件正交，改名留作后续）。

```
features/external_qbank/
  ai_panel_sheet.dart      # 保留：showAiPanel + AiChatPage + _AiChatPageState（L38-492）
                           # 并 export 其他文件公开符号（AiChatPage/buildToolResultWidget/ReviewDetailPage）
  ai_chat_bubbles.dart     # UserBubble / AiNote / Polaroid / AttachedImageGrid（原私有去 _，公开）
  ai_empty_error.dart      # EmptyState / ErrorPanel
  ai_chat_input.dart       # SendButton
  tool_result_widget.dart  # buildToolResultWidget + ToolTraceLine
  review_card.dart         # ReviewCard
  review_detail_page.dart  # ReviewDetailPage + ReviewItemTile + ReviewReplyBar
```

规则：

1. **对外接口零破坏**：`showAiPanel`、`AiChatPage`、`buildToolResultWidget` 的签名与 import 路径不变（router、today_page、topic_detail_page、app.dart、测试均不因本次改动改 import）。`ai_panel_sheet.dart` 用 `export` 汇聚子文件公开符号，保持既有 `import '.../ai_panel_sheet.dart'` 可用。
2. 原私有 widget（`_UserBubble`/`_AiNote`/`_Polaroid`/`_AttachedImageGrid`/`_SendButton`/`_EmptyState`/`_ErrorPanel`/`_ToolTraceLine`/`_ReviewCard`/`_ReviewItemTile`/`_ReviewReplyBar`）去下划线公开，按上述文件归类。`_AiChatPageState` 留在 `ai_chat_page.dart`，经 import 使用公开组件。
3. **ReviewDetailPage 入路由**：`router.dart` 新增 `GoRoute(path: '/review-detail/:id', builder: ...)`，`reviewId` 用 `int.tryParse`，非法回 `/today`（对齐 `/plan/:id` 现有防御模式）。`_ReviewCard`（新 `review_card.dart`）的 `Navigator.of(context).push(MaterialPageRoute(...))`（原 L1070）改为 `context.push('/review-detail/$reviewId')`。
4. **修内存泄漏**：`ReviewDetailPage` 由 `ConsumerWidget` 改为 `ConsumerStatefulWidget`，`TextEditingController` 在 State 创建、`dispose()` 释放（原 L1087 在 build 里创建从不 dispose）。

## 5. 消除循环 import + PendingScreenshotStore

- `PendingScreenshotStore`（`main.dart:19-20` 静态字段）迁至新文件 `core/providers/pending_screenshot.dart`。
- `app.dart`（L14 import `main.dart`）、`today_page.dart`（L19 import `main.dart`）改为 import 新文件；`main.dart` 删除类定义。→ **循环 import 消除**（`app.dart` 不再 import `main.dart`）。
- 实现阶段验证原生 `MainActivity.kt`：冷启动分享是否已由 EventChannel 完整覆盖（`share_intent_provider.dart:52-54` 注释声称已覆盖、"不需要 PendingScreenshotStore 双通道"）：
  - 若已覆盖 → 删除 `PendingScreenshotStore` 整体机制 + `today_page.dart` 的 `_consumePendingScreenshot` 消费逻辑（净减一个脆弱通道）。
  - 若仍需兜底 → 保留，但位置已在 `core/providers/`，循环 import 已消除。
  - 判定写入实施计划；本 spec 允许两种终态，验收以"无循环 import + 冷启动分享不丢"为准。

## 6. 版本号硬编码（P0）

- 新增 `core/providers/app_info_provider.dart`：`FutureProvider` 读 `package_info_plus`（pubspec 已依赖 `package_info_plus: ^8.0.0`）的实际版本号。
- `settings_page.dart:410,451` 两处硬编码 `'0.1.0-preview.6'` → `ref.watch(appInfoProvider)`。
- 实现阶段确认 `core/update/app_update_service.dart` 是否已读真实版本；若已读，复用其取值逻辑，避免第三处来源。

## 7. 技术改动范围（文件级）

| 文件 / 模块 | 类型 | 改动 |
|---|---|---|
| `features/plan/plan_chat_sheet.dart` | 删除 | 整体删除（`showPlanChat` + `_PlanChatSheet`） |
| `features/today/today_page.dart` | 修改 | `onEmptyCreate` → `push('/ai')`；移除 plan_chat_sheet import；PendingScreenshotStore import 改源 |
| `features/plan/plan_detail_page.dart` | 修改 | 调整按钮 → `injectContextNote` + `push('/ai')`；移除 plan_chat_sheet import |
| `core/providers/chat_session_provider.dart` | 修改 | 新增 `_pendingContextNote` / `injectContextNote` / `send` 消费 / `clear` 清理 |
| `core/widgets/ask_user_input_semantics.dart` | 修改 | 清理"两个 sheet"注释措辞 |
| `features/plan/day_task_calendar.dart` | 修改 | 清理 `showPlanChat` 注释 |
| `external_qbank/ai_panel_sheet.dart` | 重构 | 拆 8 文件；export 汇聚；私有 widget 公开 |
| `router.dart` | 修改 | 新增 `/review-detail/:id` |
| `main.dart` | 修改 | 移除 `PendingScreenshotStore` 定义 |
| `core/providers/pending_screenshot.dart` | 新增 | `PendingScreenshotStore` 迁入 |
| `core/providers/app_info_provider.dart` | 新增 | 版本号读取 |
| `features/settings/settings_page.dart` | 修改 | 版本号硬编码 → provider |
| `study_engine` | 不动 | 无引擎改动 |

## 8. 明确不做的事

- **不改 `external_qbank` 目录名**（`features/ai` 重命名留作后续独立项）。
- **不做 Riverpod 3 `Notifier` 迁移**（`StateNotifier` legacy 与现状一致，独立事项）。
- **不收敛引擎僵尸接口/主题 token**（`patchMemory`/`cleanup` 零调用、`ToolProgressEvent` 引擎不发、阈值常量、`stampRed` 重复、硬编码字体等——均留作后续独立重构）。
- **不移动 `agent_session_provider.run` 的 `planId` 参数**（服务层能力保留，UI 不再传）。
- **不做跨设备同步 / i18n / 文案集中管理**。

## 9. 关键决策记录

- **为什么透明注入而非路由带 planId**：hermes 模式不改 system prompt（保护 prompt cache）、不分场景代码路径、note 随 user 消息走（持久化到历史、跨轮生效）。路由带 planId 需改 provider/路由/ChatSessionState 三处且让 system prompt 因 planId 变化而失效。
- **为什么 note 对用户透明（A 方案）而非可见引导**：用户打字界面保持纯净，上下文静默进入；对齐 hermes 语义。
- **为什么 plan 入口全删而非"只删今日页"**：用户已确认"完全统一，不带 planId"——产品上不再区分 AI 与计划对话，agent 融合后自主识别意图（`create_plan`/`get_plan` 等工具自动触发）。
- **为什么拆文件用 export 汇聚而非 part**：对外 import 路径零破坏；part 增加复杂度且影响测试可达性。私有组件公开化是可接受的代价（均为 feature 内部渲染组件）。
- **为什么本次不动引擎**：agent 融合已完成，引擎干净；剩余的僵尸接口/阈值/主题 token 属独立关注点，避免一次重构跨 app+engine 两层放大回归面。

## 10. 风险与开放问题

- **透明注入可见性**：note 对用户不可见，用户若在详情页进入对话后问"你怎么知道我的计划"——体验上 AI 表现自然即可，note 措辞以陈述计划事实为主、不渲染"系统注入了上下文"。
- **note 残留**：从详情页 push `/ai` 后不发消息直接退出 → `clear()` 清空兜底；再次进入 `/ai` 是新会话，无残留。已由测试覆盖。
- **`PendingScreenshotStore` 删/留**：取决于 `MainActivity.kt` 冷启动路径验证结果，两种终态均满足验收（见 §5）。
- **ReviewDetailPage 迁路由的导航行为**：从对话内卡片 `context.push('/review-detail/:id')` 进入后返回，回到对话流（root navigator 压栈），与原 `Navigator.push` 行为一致。

## 11. 测试

| 项 | 动作 |
|---|---|
| 透明注入 | 扩展 `test/core/providers/chat_session_provider_test.dart`：`injectContextNote` → `send` 后首条 user 消息含 note 前缀、一次性消费（第二轮无 note）、`clear` 清空、`send` 早退不消费 |
| 入口收口 | 更新 `test/features/today/today_page_test.dart`、`test/features/plan/plan_detail_page_test.dart`（如存在）：按钮跳 `/ai`、注入口径 |
| ReviewDetailPage 路由 | `test/router_test.dart` 补 `/review-detail/:id`（含非法 id 兜底） |
| 拆文件回归 | `test/features/external_qbank/ai_panel_sheet_test.dart`、`review_card_test.dart` 不改 import 路径，跑通即验证 export 汇聚 |
| 版本号 | 扩展 `test/features/settings/settings_page_test.dart`：版本显示来自 provider |
| 全量回归 | `flutter analyze` + 引擎/UI 全部单测（删除 plan_chat_sheet 后无专属测试，预期零遗留引用） |
