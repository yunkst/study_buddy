# 学习伴侣 APP 设计文档 — 地基阶段（Agent 基座 + 数据层）

- **日期**: 2026-08-06
- **项目**: study_buddy（Flutter 学习伴侣 APP）
- **阶段**: 第一阶段（地基）
- **状态**: 已确认，待实施计划

## 1. 背景与目标

study_buddy 是一个 AI 驱动的学习伴侣 APP。完整愿景包含四大能力：

1. 拍题识别 → 多模态 AI 分析题目涉及的知识点 → 展示知识点选项
2. 知识点详情 → AI 讲解、追问、拍照分析用户解题过程
3. 知识点入库并标记掌握状态
4. 按知识点掌握情况智能出题与刷题

完整 APP 含多个独立子系统（题目识别、知识点对话、知识库与掌握度、出题刷题、AI agent 基座、数据层），无法用单一 spec 容纳。本 spec 仅覆盖**第一阶段：地基（AI Agent 基座 + 数据层）**，后续业务能力作为独立子项目各自 spec → plan → 实现。

### 1.1 地基阶段交付目标

构建一个**可独立验证的最小地基**：Agent ReAct 循环 + LLM Provider（含 vision）+ 数据层（迁移与 Repository）+ 1~2 个真实工具，带集成测试验证可跑通。**不做任何业务 UI 屏。**

## 2. 设计输入（已确认决策）

| 维度 | 决策 |
|---|---|
| 切入点 | 地基优先（Agent 基座 + 数据层） |
| 后端形态 | 纯 Dart，Flutter 即含后端 |
| 代码组织 | 独立 package `study_engine` + 顶层 app 依赖（方案 A） |
| LLM 接入 | OpenAI 兼容协议 + 可配多供应商；扩展 vision content |
| 数据库 | sqflite + 手写 Repository + 单文件迁移 |
| 路由 | go_router |
| 学科范围 | 用户/AI 动态创建（不预置学科） |
| 掌握状态 | 日志表驱动（mastery_log），支持遗忘曲线分析 |

### 2.1 参考实现

参考 `D:\my_space\novel_builder`（同样是纯 Dart/Flutter 的 agent 项目）。novel_builder 的 agent 循环、工具系统、提示词工程、LLM 流式调用、SQLite 数据层全部跑在前端 Dart 中（其 Python 后端仅做 ComfyUI 文生图，与 agent 无关）。**本设计移植其范式，不抄其代码。** novel_builder 的多模态仅限文生图，LLM 不看图——vision content 是我们要补的空白区。

可借鉴的关键范式：
- ReAct 循环（`agent_loop.dart`）：while 循环 + 流式 SSE + 三处取消 checkpoint + 每轮重试 + 上下文压缩 + maxRounds 强制总结
- AgentScenario 抽象（`agent_scenario.dart`）：system prompt + tools + 工具执行 + 记忆 patch
- LLM Provider 四层（DTO / 门面 / SSE / HTTP 客户端）
- sealed class 事件流
- SQLite 单文件迁移演进
- dispatch_subagent 子 agent 并行（地基阶段不实现，留接口）
- patch_memory 经验记忆（agent 自我进化）

## 3. 顶层架构（4 层）

```
┌─────────────────────────────────────────────────────────────┐
│ UI Layer (study_buddy/lib)                                  │
│   go_router 路由 + Riverpod 状态 + Widgets                  │
└────────────────────┬────────────────────────────────────────┘
                     │ Riverpod 注入
┌────────────────────▼────────────────────────────────────────┐
│ Application Layer (study_buddy/lib/core/providers)          │
│   AgentSessionProvider / SubjectProvider / TopicProvider    │
│   MasteryProvider / LlmConfigProvider                       │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────────┐
│ Engine Layer (study_engine/lib/src)                         │
│   Agent: AgentLoop + AgentScenario + Tools + Events         │
│   LLM: Provider + SSE + vision content 扩展                 │
│   Repos: Subject / Topic / Mastery / Question ...           │
│   DB: sqflite + migrations (v1 → vN)                        │
└────────────────────┬────────────────────────────────────────┘
                     │
                   SQLite（app 沙盒文件）
```

依赖方向：UI → Application → Engine → DB，反向不依赖。Engine 层不引用 `package:flutter`，仅依赖 `dart:io`/`dart:async`/`dart:math`/`meta`/`sqflite`，VM 测试用 `sqflite_common_ffi`。

### 3.1 目录结构

```
study_buddy/
├── packages/
│   └── study_engine/                      # 独立 Dart package
│       ├── lib/
│       │   ├── study_engine.dart          # barrel 导出
│       │   └── src/
│       │       ├── llm/                   # LLM Provider 四层
│       │       ├── agent/                 # ReAct 循环 + 工具 + 场景 + 事件
│       │       ├── db/                    # SQLite 迁移 + Database
│       │       ├── repos/                 # Repository
│       │       ├── models/                # 数据模型
│       │       └── llm_config_service.dart
│       └── test/                          # VM 集成测试（sqflite_common_ffi）
└── lib/                                   # Flutter app
    ├── main.dart                          # ProviderScope + app 入口
    ├── app.dart
    ├── router.dart                        # go_router 配置
    ├── core/providers/                    # Riverpod providers
    ├── features/                          # UI feature（地基阶段仅占位首页）
    └── theme/
```

## 4. 数据模型与数据层

### 4.1 核心实体（地基阶段建 8 张表）

**subject（学科）** — 动态创建，name 唯一。
- id, name, created_at

**topic（知识点）** — 核心实体。
- id, subject_id（归属学科）, parent_topic_id（自引用，前置/父子关系，nullable）, domain（领域标签，nullable）, title, summary（AI 生成后存入）, created_at

**topic_domain（领域）** — 学科内的领域分类，动态创建。
- id, subject_id, name, created_at

**mastery_log（掌握日志）** — 每次掌握状态变更记一条，不直接覆盖 topic 状态字段。当前状态 = 该 topic 最近一条 log 的 status。
- id, topic_id, status（unknown / learning / mastered / weak）, reason（变更原因，nullable）, changed_at

**llm_config（LLM 配置）** — 多供应商配置。
- id, name, api_url, api_key, model, supports_vision（bool）, is_default（bool）, sort_order, created_at

**agent_memory（经验记忆）** — agent 可用 patch_memory 工具读写自我进化。
- id, scenario_id, content, created_at

**chat_session + chat_message（对话历史）** — 支持续聊与回看。
- chat_session: id, scenario_id, title, created_at, updated_at
- chat_message: id, session_id, role, content（JSON 文本，兼容纯文本与 content parts）, tool_calls（JSON, nullable）, tool_call_id（nullable）, created_at

> 地基阶段 chat_session/message 仅建表 + Repository，不做 UI 回看。

### 4.2 掌握状态为何用日志表

掌握度会被多次更新（出题答错 → weak，复习后 → mastered）。日志表方案：
- 避免状态字段并发更新冲突
- 支持追溯历史、计算遗忘曲线（按时间间隔统计掌握状态衰减）
- 当前状态 = `SELECT status FROM mastery_log WHERE topic_id=? ORDER BY changed_at DESC LIMIT 1`

### 4.3 迁移策略

单文件 `db/database_migrations.dart`，每个版本一个 `case`，`onUpgrade` 顺序执行。v1 建齐上述 8 张表。后续每加一张表/字段 +1 版本号。

### 4.4 Repository（手写，无 ORM，共 7 个）

- `SubjectRepository`: CRUD + findByName + ensureCreate（按需自动建学科）
- `TopicRepository`: CRUD + queryBySubject + queryByDomain + queryByParent
- `MasteryRepository`: insert log + currentStatus(topicId) + statusTimeline(topicId)
- `TopicDomainRepository`: CRUD + queryBySubject
- `LlmConfigRepository`: CRUD + getDefault + getDefaultVision（取 supports_vision 的默认）
- `AgentMemoryRepository`: CRUD + queryByScenario + patchMemory（支撑 patch_memory 工具与 scenario.getMemories/patchMemory）
- `ChatRepository`: session/message 的 insert/query

## 5. Agent 系统

### 5.1 文件结构

```
study_engine/lib/src/agent/
├── agent_loop.dart              # ReAct 循环
├── agent_scenario.dart          # 抽象接口
├── agent_event.dart             # sealed class 事件流
├── agent_tools.dart             # 工具 schema 定义（OpenAI function calling）
├── context_compactor.dart       # 上下文压缩
├── subagent_runner.dart         # dispatch_subagent 调度（地基阶段留接口不实现）
├── tool_executor.dart           # 工具执行分发
└── scenarios/
    └── study_scenario.dart      # 学习伴侣场景实现
```

### 5.2 ReAct 循环逻辑

```
while round < maxRounds(50):
  response = llm.chatStreamWithTools(messages, tools)   # 流式
  aggregate tool_calls from SSE deltas
  if no tool_calls:
    invoke scenario.onNoToolCalls(messages)             # 可注入续轮
    emit AgentDoneEvent
    return
  for each tool_call:
    result = scenario.executeTool(name, args)           # 委托场景执行
    append {role:'tool', content: result} message
  if needs_compaction:                                  # 上下文超阈值
    messages = compactor.compact(messages)
  round++
```

支持：流式 SSE（TextDeltaEvent 实时推送）、三处取消 checkpoint（每轮 LLM 调用前后、工具执行前后，UI 可中断）、每轮网络重试 2 次、上下文压缩（保留 system + 最近 N 轮 + 早期摘要）、maxRounds 强制总结。

### 5.3 AgentScenario 抽象

```dart
abstract class AgentScenario {
  String get id;                       // e.g. "study"
  String get displayName;
  List<Map<String, dynamic>> get tools;        // OpenAI function calling schema
  String buildSystemPrompt(AgentScenarioContext ctx);
  Future<String> executeTool(
    String name, Map<String, dynamic> args, {
    void Function(String)? onProgress,
    String? toolCallId,
  });
  Future<String?> onNoToolCalls(List<ChatMessage> messages);
  Future<List<String>> getMemories();
  Future<MemoryPatchResult> patchMemory(int? index, String newText);
  Future<void> cleanup();
}
```

地基阶段实现 1 个：`StudyScenario`。系统提示词结构：
- 静态部分进 `buildSystemPrompt`：身份 + 工作原则 + 「## 经验记忆」段（`[N] 内容` 编号格式）
- 动态部分（用户当前学科、最近一次拍题结果）注入每轮 user message 头部
- 工具 schema 在 description 字段中用中文密集写使用规则，LLM 据此自主决策

### 5.4 事件流（sealed class）

```dart
sealed class AgentEvent {}
class AgentStartedEvent extends AgentEvent {}
class TextDeltaEvent extends AgentEvent { final String delta; }
class ToolCallStartEvent extends AgentEvent { final String name; final String toolCallId; }
class ToolCallEndEvent extends AgentEvent { final String name; final String result; final String toolCallId; }
class ToolProgressEvent extends AgentEvent { final String progress; }
class CompactionEvent extends AgentEvent {}
class RetryEvent extends AgentEvent {}
class AgentDoneEvent extends AgentEvent { final String? finalText; }
class AgentErrorEvent extends AgentEvent { final String message; }
```

UI 层用 Riverpod StreamProvider 订阅。

### 5.5 地基阶段工具集（2 个真实工具）

| 工具名 | 用途 | 涉及 repo |
|---|---|---|
| `save_topic` | 保存 AI 生成的知识点到知识库（学科按需自动创建） | SubjectRepository、TopicRepository |
| `query_topics` | 按学科/领域查询知识点列表 | TopicRepository |

这两个工具代码地基完整可用，后续拍照识题、出题等功能只需扩展新工具（analyze_image_question / analyze_user_solution / generate_question 等）。

### 5.6 子 Agent（不实现）

地基阶段不实现 dispatch_subagent 与 subagent_runner，留接口。后续"按整本书考点出题"等复杂任务再启用。有意 YAGNI。

## 6. LLM Provider（含 vision 扩展）

### 6.1 四层拆分

```
study_engine/lib/src/llm/
├── llm_provider.dart              # 门面（barrel 导出）
├── llm_provider_config.dart       # DTO：ChatMessage / LlmConfig / ToolCall
├── llm_provider_core.dart         # chat / chatForJson / chatStream / chatStreamWithTools
├── llm_provider_sse.dart          # SSE 解析 + tool_calls delta 聚合
└── llm_provider_client.dart       # IoLlmHttpClient（dart:io HTTP，可注入 mock）
```

### 6.2 vision content 扩展（我们要补的空白）

ChatMessage.content 既可以是纯字符串，也可以是 content parts 数组：

```dart
class ChatMessage {
  final String role;
  final Object content;   // String 或 List<ContentPart>
}

sealed class ContentPart {}
class TextPart extends ContentPart { final String text; }
class ImageUrlPart extends ContentPart {
  final String url;       // base64 data URI 或 http URL
  final String? detail;   // low / high / auto
}
```

序列化为 OpenAI vision 结构：
```json
{
  "role": "user",
  "content": [
    {"type": "text", "text": "分析这道题涉及哪些知识点"},
    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
  ]
}
```

### 6.3 多供应商配置

`LlmConfigService` 管理 llm_config 表中的多套配置：name/api_url/api_key/model/supports_vision/is_default/sort_order。不同场景可选不同配置。地基阶段支持「默认配置 + 视觉任务优先选 supports_vision=true」。API key 存 SQLite（个人本地应用，可接受；后续如需更强可加平台 keychain）。

## 7. 交付物清单

| # | 交付物 | 位置 |
|---|---|---|
| 1 | 独立 package study_engine 骨架 | packages/study_engine/ |
| 2 | DB 迁移 + 8 张表 | study_engine/lib/src/db/ |
| 3 | 7 个 Repository（subject/topic/mastery/topic_domain/llm_config/agent_memory/chat） | study_engine/lib/src/repos/ |
| 4 | 数据模型类 | study_engine/lib/src/models/ |
| 5 | LLM Provider 四层 + vision 扩展 | study_engine/lib/src/llm/ |
| 6 | Agent 系统（loop/scenario/event/tools/compactor/executor） | study_engine/lib/src/agent/ |
| 7 | StudyScenario + 2 个工具（save_topic / query_topics） | study_engine/lib/src/agent/scenarios/ |
| 8 | 顶层 app 接入：ProviderScope、go_router、占位首页 | study_buddy/lib/ |
| 9 | go_router 依赖、配置 | pubspec.yaml、lib/router.dart |

## 8. 验收标准

1. **flutter analyze** 全绿（app + engine 两个包）。
2. **flutter test** 通过，含集成测试：
   - 数据层集成测试（sqflite_common_ffi 在 VM 跑）：建库 → 插知识点 → 查知识点 → 更新掌握状态 → 按日志算当前状态。
   - Agent 集成测试（mock LLM Provider）：注入预设 tool_calls 响应，验证 agent 调用 save_topic 工具后知识点确实落库。
   - LLM vision 序列化测试：构造带图片的 ChatMessage，断言序列化 JSON 符合 OpenAI vision 结构。
3. **app 可启动**：`flutter run -d windows` 启动后显示占位首页，不崩溃。

## 9. 明确不做（YAGNI 边界）

- 拍照识题 / 解题分析 / 出题刷题的业务 UI 屏。
- 这些功能的 agent 工具（analyze_image_question 等）。
- dispatch_subagent 子 agent 并行。
- chat_session/message 的 UI 回看（仅建表 + Repository）。
- 掌握度看板 UI。
- 外部云端同步。

## 10. 依赖与初始化

- study_engine/pubspec.yaml：sqflite、sqflite_common_ffi（测试）、path、meta
- study_buddy/pubspec.yaml：已有 flutter_riverpod，新增 go_router、path，path 依赖 study_engine（相对路径）
- 依赖注入：app 启动时 openDatabase，通过 Riverpod provider 暴露 DB handle 与各 Repository；AgentSessionProvider 依赖这些。

## 11. 后续子项目（本 spec 之外）

地基完成后，按以下顺序各做独立 spec → plan → 实现：

1. 拍题识别与知识点提取（功能 1）— 扩展 analyze_image_question 工具 + 拍照 UI + 知识点选项 UI
2. 知识点详情与对话（功能 2）— 扩展 analyze_user_solution 工具 + 对话 UI + 掌握状态标记
3. 出题与刷题（功能 4）— 扩展 generate_question 工具 + 刷题 UI + 答题判分
4. 掌握度看板（功能 3 之 UI 部分）— 复用 mastery_log 数据 + 看板 UI + 遗忘曲线可视化
