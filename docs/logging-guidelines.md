# 日志使用指南 · study_buddy

> study_buddy 双日志体系的使用规范。涵盖 App 运行日志(LoggerService)与 LLM 调用日志(LlmLogger)的级别、分类、traceId 串联、engine sink 注入,以及设置页查看入口。
>
> 本文档基于本分支已落地的真实代码,API 引用以源码为准。

- **日期**:2026-08-11
- **范围**:engine 双 sink 接口 + app 双服务实现 + traceId 串联 + 设置页/查看页 + LLM 配置

---

## 1. 双日志体系概述

study_buddy 的可观测性由两个独立但关联的系统承担:

| 系统 | 职责 | 实现 | 存储介质 |
|---|---|---|---|
| **App 运行日志** | 记录应用生命周期、Agent 循环、数据库迁移、UI 交互等业务流程日志 | `LoggerService`(单例) | 内存 1000 条 FIFO + SharedPreferences(文件回退) |
| **LLM 调用日志** | 记录每次 LLM 请求/响应的完整内容、耗时、token 用量 | `LlmLogger`(单例) | JSONL 按日文件,7 天保留 |

两者通过 **traceId** 关联:同一次 Agent 会话内产生的所有 App 日志条目与 LLM 调用记录共享同一个 traceId,可在查看页交叉跳转定位。

**查看入口**:首页 `_Masthead` 右上角齿轮 → 设置页(`/settings`)→ 诊断板块 → 应用日志(`/logs/app`)/ LLM 调用日志(`/logs/llm`)。

---

## 2. engine 层:Sink 接口设计

engine 是纯 Dart 包(`packages/study_engine`,零 Flutter 依赖),负责定义日志出口接口与默认 Null 实现,自身不落盘、不依赖 `shared_preferences`/`path_provider`。落盘逻辑由 app 层实现并注入。

### 2.1 LoggerSink — App 运行日志出口

```dart
// packages/study_engine/lib/src/logging/logger_sink.dart

enum LoggerLevel { debug, info, warning, error }

abstract class LoggerSink {
  void log(
    LoggerLevel level,
    String message, {
    String category = 'general',
    String? traceId,
    String? stackTrace,
    List<String> tags = const [],
  });
}

class NullLoggerSink implements LoggerSink {
  const NullLoggerSink();
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general',
      String? traceId,
      String? stackTrace,
      List<String> tags = const []}) {}
}
```

**设计要点**:
- `LoggerLevel` 枚举顺序 `debug/info/warning/error` 与 app 层 `LogLevel` **index 对齐**,app 侧用 `LogLevel.values[level.index]` 直接映射。
- `category` 是字符串而非枚举:engine 不定义业务分类语义,由 app 约定(study 用 `database/ai/focus/plan/ui/general`),engine 只透传。
- `NullLoggerSink` 是 `const` 实现,零开销;engine 测试与未注入时默认使用,保证现有测试零改动。

### 2.2 LlmCallSink — LLM 调用观测出口

```dart
// packages/study_engine/lib/src/logging/llm_call_sink.dart

abstract class LlmCallSink {
  /// 记录请求开始,返回记录 id(engine 透传给 onResponse/onError)。
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  });

  /// 记录响应完成(含 token 统计与耗时)。
  void onResponse(
    String id, {
    required String responseBody,
    required int durationMs,
    required bool isSuccess,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
  });

  /// 记录请求失败。
  void onError(
    String id, {
    required String errorMessage,
    int? durationMs,
  });
}

class NullLlmCallSink implements LlmCallSink {
  const NullLlmCallSink();
  // onRequest 返回空串,onResponse/onError no-op
}
```

**调用流程**:`onRequest` 返回 id → engine 存住 id → `onResponse(id)` 或 `onError(id)`。id 关联由 sink 实现负责(engine 只透传,不解释 id 语义)。

### 2.3 为何 engine 不耦合 Flutter

engine pubspec 零 Flutter 依赖,仅用 `sqflite_common`/`path`/`meta`。若 sink 接口引入 `shared_preferences`/`path_provider`,会破坏 engine 的纯 Dart 可测性(测试需 Flutter binding)。故采用 **engine 抽象接口 + app 实现 + 注入** 模式:engine 定义接口与 Null 默认,app 实现接口,`AgentSession.run()` 在构造 `LlmProvider`/`AgentLoop` 时注入。

---

## 3. app 层:服务实现

### 3.1 LoggerService(App 运行日志)

文件:`study_buddy/lib/core/services/logger_service.dart`

```dart
enum LogLevel { debug, info, warning, error }       // index 与 LoggerLevel 对齐
enum LogCategory { database, ai, focus, plan, ui, general }  // 6 分类

class LoggerService implements LoggerSink {
  static LoggerService get instance => ...;          // 单例
  static const int _maxLogs = 1000;                  // 内存 FIFO 上限
  static const String _prefsKey = 'app_logs';        // SP 键
  static const String _fallbackFileName = 'app_logs_fallback.json';  // SP 失败时文件回退

  // 便捷方法
  void d(String message, {LogCategory category, List<String> tags, String? stackTrace, String? traceId});
  void i(String message, {LogCategory category, List<String> tags, String? stackTrace, String? traceId});
  void w(String message, {LogCategory category, List<String> tags, String? stackTrace, String? traceId});
  void e(String message, {LogCategory category, List<String> tags, String? stackTrace, String? traceId});

  // engine 调用(LoggerSink 实现)
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general', String? traceId, String? stackTrace, List<String> tags = const []});

  // traceId Zone 传播
  static String? get currentTraceId;
  static Future<T> withTraceId<T>(String traceId, Future<T> Function() action);

  // 查询
  List<LogEntry> getLogs();
  List<LogEntry> getLogsByLevel([LogLevel? level]);
  List<LogEntry> getLogsByCategory(LogCategory category);
  List<LogEntry> searchLogs(String query, {LogCategory? category});
  LogStatistics getStatistics();
  Future<void> clearLogs();
  Future<void> flush();           // 主动落盘(app 进入后台时调用)
  Future<File> exportToFile();    // 导出为 app_logs.txt
}
```

**存储策略**:
- 内存最近 1000 条 FIFO,超出 `removeAt(0)`。
- 持久化:批量异步,1s 间隔(`_flushIntervalMs`),`_isPersisting` 锁防并发写。先写 SharedPreferences,失败回退到 `app_logs_fallback.json`。
- **release 模式不写 debug**:`d()` 在 `kReleaseMode` 直接 return;`log()` 在 release 且级别为 debug 时 return。
- 通知:`ValueNotifier<int> logChangeNotifier`,查看页监听实时刷新。
- 测试辅助:`resetForTesting()` 取消 pending timer + 重建 notifier。

### 3.2 LlmLogger(LLM 调用日志)

文件:`study_buddy/lib/core/services/llm_logger/llm_logger.dart` + `llm_call_record.dart`

```dart
class LlmLogger implements LlmCallSink {
  static LlmLogger get instance => ...;              // 单例
  static const int _retentionDays = 7;               // 7 天保留
  static const int _maxResponseLength = 5 * 1024 * 1024;  // 5MB 截断
  static const int _cacheSize = 200;                 // 内存缓存上限
  static final ValueNotifier<int> changeNotifier = ...;

  Future<void> initialize();                         // 建目录 + 清过期 + 载缓存
  Future<List<LlmCallRecord>> getRecent({int limit = 50});
  Future<LlmCallRecord?> getById(String id);
  Future<void> clear();
  Future<int> getTotalSize();                        // 目录总占用字节
}
```

**存储策略**:
- JSONL 按日文件:`{appDocsDir}/llm_logs/llm_YYYYMMDD.jsonl`(UTC 日期)。
- 7 天保留:`initialize()` 时调用 `_cleanOldFiles()`,删除早于 cutoff 的 `.jsonl`。
- 响应体超 5MB 截断,尾部追加 `...(truncated at 5242880 bytes)`。
- 内存最近 200 条缓存,不足从文件补。
- 异步写入队列:`_writeQueue` + `_isWriting` 锁,append 模式追加当日文件。
- id 格式:`llm-{millisecondsSinceEpoch}-{counter}`(内部生成,`onRequest` 返回)。
- 通知:`ValueNotifier<int> changeNotifier`,查看页监听实时刷新。

**LlmCallRecord 字段**:

| 字段 | 类型 | JSON 键 | 说明 |
|---|---|---|---|
| id | String | `id` | 记录唯一 id |
| timestamp | DateTime(UTC) | `timestamp`(ms) | 请求时间 |
| endpoint | String | `endpoint` | 完整请求 URL |
| model | String? | `model` | 模型名 |
| isStreaming | bool | `is_streaming` | 是否流式 |
| requestBody | String | `request_body` | 请求体 JSON |
| responseBody | String? | `response_body` | 完整响应(截断后) |
| durationMs | int? | `duration_ms` | 耗时 |
| isSuccess | bool | `is_success` | 是否成功 |
| errorMessage | String? | `error_message` | 错误信息 |
| promptTokens | int? | `prompt_tokens` | 输入 token |
| completionTokens | int? | `completion_tokens` | 输出 token |
| totalTokens | int? | `total_tokens` | 总 token |
| **traceId** | String? | `trace_id` | 与 App 日志交叉关联 |

---

## 4. traceId 串联机制

traceId 是连接一次 Agent 会话内所有 App 日志条目与 LLM 调用记录的唯一标识。

### 4.1 生成与注入

```dart
// study_buddy/lib/core/providers/agent_session_provider.dart
class AgentSession {
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {int? chatSessionId}) async {
    // ...
    final traceId = 'agent-${DateTime.now().millisecondsSinceEpoch}';

    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,      // 注入 LlmCallSink 实现
      logger: LoggerService.instance,   // 注入 LoggerSink 实现
    );
    final loop = AgentLoop(llm: llm, scenario: scenario, logger: LoggerService.instance);

    LoggerService.instance.i('Agent 会话开始',
        category: LogCategory.ai, tags: const ['session-start'], traceId: traceId);

    return loop.run(messages,
        context: AgentScenarioContext(extra: ...),
        traceId: traceId);   // 显式透传给 engine
  }
}
```

### 4.2 透传路径

traceId 由 app 层 `AgentSession` 生成,**显式参数透传**(非 Zone 隐式),路径如下:

```
AgentSession.run() 生成 traceId
  ├─ LoggerService.i('Agent 会话开始', traceId: traceId)   // app 层日志带 traceId
  └─ AgentLoop.run(messages, traceId: traceId)
       ├─ logger.log(LoggerLevel.info, 'Agent 开始', traceId: traceId)   // engine 埋点带 traceId
       ├─ llm.chatStreamWithTools(messages, tools, traceId: traceId)
       │    ├─ llmSink.onRequest(traceId: traceId)        // LLM 记录入 traceId
       │    └─ logger.log(LoggerLevel.error, 'LLM 调用失败', traceId: traceId)  // 失败时 app 日志带 traceId
       └─ logger.log(..., traceId: traceId)               // round/工具调用/完成/异常 全带 traceId
```

**为何 engine 用显式参数而非 Zone**:
- engine 是纯 Dart,`dart:async` Zone 的隐式传参在测试中不透明(难以断言 traceId 来源)。
- 显式参数让埋点调用点自文档化,签名即契约。
- Zone 仅在 app 层 `LoggerService` 内部使用(`withTraceId`/`currentTraceId`),用于 app 自己的日志在异步回调中自动继承 traceId。

### 4.3 交叉关联

同一次 Agent 会话:
- App 日志查看页按 traceId 过滤 → 看到会话开始、每轮 round、工具调用、异常等全部条目。
- LLM 日志详情页显示 traceId → 同一次会话内可能有多轮 LLM 调用,共享同一 traceId。
- 双向定位:App 日志看到 LLM 调用失败条目 → 复制 traceId → LLM 日志页按 traceId 找到对应请求/响应。

---

## 5. 日志级别与分类

### 5.1 级别(4 级)

`LoggerLevel` 与 `LogLevel` 枚举顺序对齐,`index` 一致:

| index | 级别 | 场景 | release 是否写 |
|---|---|---|---|
| 0 | `debug` | 详细诊断信息:round 边界、迁移步骤、内部状态。仅开发期可见 | 否(`d()` 在 release 直接 return) |
| 1 | `info` | 关键业务节点:会话开始/完成、工具调用、迁移开始/完成、应用启动 | 是 |
| 2 | `warning` | 非致命异常:达到最大轮次、降级行为、可恢复错误 | 是 |
| 3 | `error` | 错误:Agent 异常、LLM 调用失败、迁移失败、未捕获异常 | 是 |

**示例**:

```dart
// debug:开发期诊断
LoggerService.instance.d('第 $round 轮开始',
    category: LogCategory.ai, tags: const ['round'], traceId: traceId);

// info:关键节点
LoggerService.instance.i('Agent 会话开始',
    category: LogCategory.ai, tags: const ['session-start'], traceId: traceId);

// warning:可恢复异常
LoggerService.instance.w('Agent 达到最大轮次 $maxRounds',
    category: LogCategory.ai, tags: const ['max-rounds'], traceId: traceId);

// error:错误(带堆栈)
LoggerService.instance.e('LLM 调用失败: $e',
    category: LogCategory.ai, tags: const ['llm'],
    stackTrace: st.toString(), traceId: traceId);
```

### 5.2 分类(6 类)

`LogCategory { database, ai, focus, plan, ui, general }`,对应 study 业务域:

| 分类 | 场景 | 示例 |
|---|---|---|
| `database` | 数据库迁移、表操作、查询异常 | `'数据库迁移开始: v$from → v$to'` |
| `ai` | Agent 循环、LLM 调用、工具调用、场景执行 | `'Agent 开始'`、`'工具调用: save_review'`、`'LLM 调用失败'` |
| `focus` | 专注时钟会话开始/停止/恢复、关联知识点 | `'专注会话开始: topicId=...'` |
| `plan` | 学习计划生成、计划项调整、计划会话 | `'计划会话开始: date=...'` |
| `ui` | 页面跳转、设置变更、用户交互关键节点 | `'设置入口点击'`、`'LLM 配置已保存'` |
| `general` | 应用生命周期、不属于上述域的通用日志 | `'应用启动'` |

**engine 侧 category 为字符串**:engine 调用 `logger.log(...)` 时传字符串(如 `'ai'`、`'database'`),app 侧 `LoggerService._parseCategory()` 映射到枚举,未知 category 归 `general`。

### 5.3 标签推荐

标签是 `List<String>`,用于细粒度过滤与搜索(`searchLogs` 同时匹配消息与标签):

| 标签 | 用途 | 出处 |
|---|---|---|
| `app-start` | 应用启动 | `app.dart` |
| `session-start` | Agent 会话开始 | `AgentSession.run()` |
| `agent-start` / `agent-done` / `agent-error` | Agent 循环生命周期 | `AgentLoop` |
| `round` | 每轮 ReAct 循环边界 | `AgentLoop` |
| `tool-call` | 工具调用执行 | `AgentLoop` |
| `max-rounds` | 达到最大轮次上限 | `AgentLoop` |
| `llm` | LLM 调用失败(engine error 级) | `LlmProvider` |
| `migration-start` / `migration-step` / `migration-done` / `migration-failed` | 数据库迁移各阶段 | `migrateDatabase` |

新增埋点时优先复用上述标签;若引入新业务域,标签命名用 kebab-case(如 `focus-start`、`plan-saved`)。

---

## 6. 如何在业务代码里打日志

### 6.1 app 层(直接调用 LoggerService)

```dart
import '../services/logger_service.dart';

// 基本用法:d/i/w/e 四级,默认 category 为 general
LoggerService.instance.i('应用启动',
    category: LogCategory.general, tags: const ['app-start']);

// 带 traceId(在 Agent 会话上下文中)
LoggerService.instance.i('Agent 会话开始',
    category: LogCategory.ai, tags: const ['session-start'], traceId: traceId);

// error 级带堆栈
try {
  // ...
} catch (e, st) {
  LoggerService.instance.e('操作失败: $e',
      category: LogCategory.database,
      stackTrace: st.toString(),
      tags: const ['my-op']);
  rethrow;
}
```

**参数说明**:
- `message`:必填,人类可读的中文描述。
- `category`:默认 `LogCategory.general`,按业务域选择。
- `tags`:默认空数组,用于细粒度过滤。
- `stackTrace`:仅 `e`/`w` 级常用,字符串形式(非 StackTrace 对象)。
- `traceId`:可选,在 Agent 会话上下文中传入;不传时 `LoggerService` 会尝试从 Zone 读取 `currentTraceId`。

### 6.2 engine 层(通过注入的 LoggerSink)

engine 模块不直接引用 `LoggerService`,而是持有可空的 `LoggerSink`,由 app 注入:

```dart
// engine 新模块构造时,logger 为可选参数,默认 NullLoggerSink
class MyEngineModule {
  final LoggerSink _logger;
  MyEngineModule({LoggerSink? logger}) : _logger = logger ?? const NullLoggerSink();

  void doWork({String? traceId}) {
    _logger.log(LoggerLevel.info, '工作开始',
        category: 'ai', traceId: traceId, tags: const ['my-module']);
    // ...
    _logger.log(LoggerLevel.info, '工作完成',
        category: 'ai', traceId: traceId, tags: const ['my-module-done']);
  }
}
```

**埋点规范**:
- 级别用 `LoggerLevel` 枚举(engine 不引用 app 的 `LogLevel`)。
- `category` 传字符串,与 app `LogCategory.name` 对齐(`'database'`/`'ai'`/`'focus'`/`'plan'`/`'ui'`/`'general'`)。
- `traceId` 总是从调用方接收透传,不在 engine 内部生成。
- 异常路径:同时打 `LoggerLevel.error` 日志(带 `stackTrace`),并视情况通过 `LlmCallSink.onError` 通知 LLM 记录。

### 6.3 现有埋点参考

| 模块 | 文件 | 典型埋点 |
|---|---|---|
| AgentLoop | `agent_loop.dart` | `agent-start`/`round`/`tool-call`/`agent-done`/`max-rounds`/`agent-error`(category `ai`) |
| LlmProvider | `llm_provider_core.dart` | 失败时 `LoggerLevel.error` + tag `llm`(category `ai`);成功路径由 `LlmCallSink` 记录 |
| migrateDatabase | `database_migrations.dart` | `migration-start`/`migration-step`(debug)/`migration-failed`(error)/`migration-done`(category `database`) |
| AgentSession | `agent_session_provider.dart` | `session-start`(category `ai`),生成 traceId 并透传 |
| app 生命周期 | `app.dart` | `app-start`(category `general`),`paused` 时 `flush()` |

---

## 7. 存储与清理策略

### 7.1 App 运行日志(LoggerService)

| 维度 | 策略 |
|---|---|
| 内存上限 | 1000 条 FIFO,超出移除最旧 |
| 持久化 | SharedPreferences 键 `app_logs`,批量异步写(1s 间隔) |
| 文件回退 | SP 写失败 → 写 `{appDocsDir}/app_logs_fallback.json` |
| 主动 flush | `app.dart` 监听 `AppLifecycleState.paused` 调用 `flush()`,避免未持久化丢失 |
| 清理 | 设置页查看页 AppBar「清空」按钮 → `clearLogs()`(确认对话框) |
| 导出 | 查看页 AppBar「导出」→ `exportToFile()` 写 `app_logs.txt` |

### 7.2 LLM 调用日志(LlmLogger)

| 维度 | 策略 |
|---|---|
| 文件格式 | JSONL,按日切分 `llm_YYYYMMDD.jsonl`(UTC 日期) |
| 目录 | `{appDocsDir}/llm_logs/` |
| 保留期 | 7 天,`initialize()` 时清理早于 cutoff 的 `.jsonl` 文件 |
| 响应体截断 | 超 5MB(`5 * 1024 * 1024` 字节)截断,尾部追加截断标记 |
| 内存缓存 | 最近 200 条,查看页优先读缓存,不足从文件补 |
| 清理 | LLM 日志列表页 AppBar「清空」→ `clear()`(确认对话框,删除整个目录并重建) |

---

## 8. 设置页与查看页

### 8.1 路由

```
/settings          → SettingsPage(设置页)
/logs/app          → AppLogViewerPage(App 运行日志列表)
/logs/llm          → LlmLogViewerPage(LLM 调用日志列表)
/logs/llm/:id      → LlmLogDetailPage(LLM 调用详情)
```

### 8.2 设置页

文件:`study_buddy/lib/features/settings/settings_page.dart`

设置页用纸感 `PaperScaffold` 包裹,含两个板块:

1. **LLM 配置板块**(`_LlmConfigSection`):编辑当前默认 LLM 配置
   - 名称(如「我的模型」)
   - API 地址(如 `https://api.example.com/v1`)
   - API Key(`obscure: true` 隐藏)
   - 模型(如 `gpt-4o`)
   - 「保存」按钮 → `llmConfigProvider.notifier.save()` + `refresh()`,SnackBar 反馈

2. **诊断板块**:两个导航行
   - 应用日志(图标 `article_outlined`)→ `/logs/app`
   - LLM 调用日志(图标 `smart_toy_outlined`)→ `/logs/llm`

### 8.3 App 日志查看页

文件:`study_buddy/lib/features/logs/app_log_viewer_page.dart`

- 顶部统计条:总数 + 各级占比
- 级别过滤 chip(多选级别)
- 关键词搜索框(匹配消息 + 标签)
- 列表项:时间 · 级别色标圆点 · `[分类]` · 消息(2 行截断) · traceId 末段(若有)
- 点击展开详情:全消息 + 堆栈 + 分类 + 标签 + traceId
- AppBar actions:清空(确认) · 导出(写文件 + toast 路径)
- 实时刷新:监听 `LoggerService.logChangeNotifier`

### 8.4 LLM 日志列表页

文件:`study_buddy/lib/features/logs/llm_log_viewer_page.dart`

- 统计条:条数 + 占用大小(`getTotalSize()`)
- 列表项:成功/失败色标图标 · model(monospace) · `流式` tag(若是) · previewText · 时间 · 耗时 · tokens
- 点击 → `/logs/llm/:id`
- AppBar actions:刷新 · 清空(确认)
- 实时刷新:监听 `LlmLogger.changeNotifier`

### 8.5 LLM 日志详情页

文件:`study_buddy/lib/features/logs/llm_log_detail_page.dart`

- 概要卡:时间 · 状态(成功/失败色) · model · Endpoint · 流式 · 耗时 · Tokens(prompt/completion/total) · traceId
- 请求体:JSON 格式化展示,SelectableText,monospace
- 响应体:JSON 格式化(失败时显示 errorMessage)
- AppBar actions:复制完整记录 JSON

---

## 9. LLM 配置

### 9.1 数据模型

LLM 配置存储在 `llm_config` 表,由 `LlmConfigRepository` 管理。关键字段:`name`/`api_url`/`api_key`/`model`/`supports_vision`/`is_default`/`sort_order`。

`AgentSession.run()` 通过 `LlmConfigRepository.getDefault(vision: true)` 获取默认的视觉支持配置;若不存在,`run()` 抛 `StateError`,UI 层捕获提示用户配置。

### 9.2 空表种子默认配置

文件:`study_buddy/lib/core/providers/llm_config_provider.dart`

`llmConfigProvider` 的 `build()` 方法在数据库表为空(全新安装)时,自动种子一条占位默认配置:

```dart
if (configs.isEmpty) {
  await repo.insert(LlmConfig(
    name: '默认配置',
    apiUrl: '',
    apiKey: '',
    model: '',
    supportsVision: true,
    isDefault: true,
    createdAt: DateTime.now(),
  ));
  configs = await repo.all();
}
```

这消除了 `AgentSession`/`PlanSession` 的 `getDefault()` 返回 null 抛 `StateError` 的崩溃路径,并让用户在设置页看到「待填写」的初始态。用户首次在设置页填写 URL/Key/Model 并保存后,配置生效。

### 9.3 设置页编辑

设置页 `_LlmConfigSection` 监听 `llmConfigProvider`,加载当前默认配置到四个 `TextEditingController`(名称/URL/Key/Model)。「保存」时调用 `save(cfg.copyWith(...))`:
- 名称为空时默认填「默认配置」。
- 其余字段 trim 后写入。
- 保存成功后 `refresh()` 刷新 provider,SnackBar 提示「LLM 配置已保存」。

下次 `AgentSession.run()` 会重新从 DB 读取配置构造 `LlmProvider`,即时生效。

---

## 10. 初始化时序

```
app.dart _StudyBuddyAppState.initState
  └─ addPostFrameCallback:
       ├─ await LoggerService.instance.init()     // 加载 SP 历史(失败回退文件)
       ├─ await LlmLogger.instance.initialize()   // 建 llm_logs 目录 + 清 7 天外文件 + 载 200 条缓存
       ├─ LoggerService.instance.i('应用启动', category: general, tags: ['app-start'])
       ├─ bootstrapOverlay(...)
       └─ recoverOrphan()

didChangeAppLifecycleState(paused) → LoggerService.instance.flush()   // 主动落盘
```

`LoggerService.init()` 与 `LlmLogger.initialize()` 失败均不阻塞应用:前者 SP 加载失败回退文件,文件也失败则 debugPrint;后者 catch + debugPrint,`_initialized` 保持 false 但不抛。

---

## 11. 迁移指南(替换旧日志方式)

### 11.1 替换 `dart:developer.log`

旧的 `dart:developer` 的 `log()`(如 `core/update/` 模块)应替换为 `LoggerService`:

```dart
// before
import 'dart:developer' as developer;
developer.log('下载失败: $e', name: 'update');

// after
import '../services/logger_service.dart';
LoggerService.instance.e('下载失败: $e',
    category: LogCategory.general, tags: const ['update']);
```

收益:落盘可查、分级过滤、release 屏蔽 debug、可在设置页导出。

### 11.2 新增 engine 模块埋点

1. 构造参数加 `LoggerSink? logger`,默认 `const NullLoggerSink()`。
2. 关键节点调用 `logger.log(LoggerLevel.info, message, category: '...', traceId: traceId, tags: const [...])`。
3. 异常路径打 `LoggerLevel.error` 并带 `stackTrace`。
4. 若模块涉及 LLM 调用,同样注入 `LlmCallSink?`,默认 `const NullLlmCallSink()`。
5. 测试时注入 fake sink 记录调用,断言埋点正确性;不注入时 Null 兜底,零负担。

### 11.3 app 层新功能埋点

1. 关键业务节点(会话开始、操作完成、异常)打 `i`/`e`。
2. 按 6 分类选 `category`,按 5.3 节标签表选 `tags`。
3. 在 Agent 会话上下文中,透传 `traceId` 参数。
4. 避免 debug 级在生产路径堆积:release 模式 `d()` 自动 no-op,无需手动判断。

---

## 12. 范围边界

### 本期已落地

- engine `LoggerSink`/`LlmCallSink` 接口 + Null 实现 + `study_engine.dart` 导出
- engine `AgentLoop` / `LlmProvider` / `migrateDatabase` 埋点
- app `LoggerService`(内存+SP+文件回退)+ `LlmLogger`(JSONL+traceId)
- `AgentSession.run()` 注入 sink + 生成 traceId + 显式透传
- `app.dart` 初始化时序 + paused flush
- 设置页 + 三个查看页(纸感)+ 路由 + 首页入口
- LLM 配置编辑(设置页)+ 空表种子默认配置
- engine/app 单元测试 + 查看 widget 测试

### 留扩展点(本期不做)

- **远程日志上报**:`LoggerService` 已有 reporter 回调钩子(对齐 novel_builder),未来接 Sentry/自建后端。
- **崩溃收集**:native crash handler 思路,本期不接。
- **日志级别运行时配置**:release 直接不写 debug,不做运行时开关。
- **app 层全量埋点**:仅埋关键路径(启动/会话/迁移/LLM),其余模块逐步迁移。
