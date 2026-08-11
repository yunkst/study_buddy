# 日志系统设计 · study_buddy

> 参照 `novel_builder` 的双日志体系(LoggerService + LlmLogger),适配 study_buddy 的 **engine(app 分层)** 架构。目标是提供一个可在 app 内查看 **App 运行日志** 和 **LLM 调用日志** 的地方,engine 全链路可观测,且 engine 保持纯 Dart 可测性。

- **日期**:2026-08-11
- **范围**:完整体系 MVP(engine 双 sink + app 双服务 + traceId + 设置页 + 三个查看页 + 关键埋点 + 文档)
- **参考**:`D:\my_space\novel_builder\novel_app\lib\services\logger_service.dart`、`.../llm_logger/`、`docs/logging-guidelines.md`

---

## 1. 背景与现状

### 1.1 study_buddy 现状(无日志系统)

- **engine 层完全静默**:`AgentLoop` / `migrateDatabase` / `LlmProvider` / `StudyScenario` 这些核心流程无任何运行日志,出问题只能靠测试断言。
- **app 层仅 update 模块有日志**:`core/update/` 用 `dart:developer` 的 `log()`,不落盘、不分级、不可配置、release 不屏蔽。
- **LLM 调用唯一出口**:engine 层 `llm_provider_client.dart` 的 `IoLlmHttpClient.postStream`(纯 dart:io HttpClient,SSE 流式),全程不可观测——请求发了什么、响应回了什么、耗时多少、token 用量,全黑盒。
- **无设置页**:go_router 5 个页面,无 settings 入口。

### 1.2 关键架构事实(决定设计)

| 事实 | 影响 |
|---|---|
| engine pubspec 零 Flutter 依赖(`sqflite_common`/`path`/`meta`) | sink 接口必须纯 Dart,绝不能引入 `shared_preferences`/`path_provider` |
| app 已有 `path_provider` + `shared_preferences` 依赖 | LoggerService/LlmLogger 直接用,无需加包 |
| `AgentSession.run()` 每次 `run()` 重新构造 `LlmProvider`/`AgentLoop`(LlmConfig 可能被用户改) | sink 跟随每次 run 注入,非全局单例 |
| `LlmProvider` 持有 `config`(model/apiUrl/apiKey),`chatStreamWithTools` 是 request 构造 + response 拼接的完整边界 | LLM 拦截最佳点是 `LlmProvider`,非 `IoLlmHttpClient`(后者只能拿 SSE 原始行) |
| 纸感主题:`PaperColors` extension + `NotoSerifSC` + `_Article` 容器 | 查看页套同一视觉体系 |

### 1.3 novel_builder 体系(参考对象)

- **LoggerService**:内存 1000 FIFO + SharedPreferences(文件回退),4 级 8 分类,traceId Zone 传播,ValueNotifier 通知。
- **LlmLogger**:JSONL 按日文件 + 7 天保留,由 HTTP 拦截器自动记录 req/resp/token/耗时,列表页 + 详情页。
- **文档** `docs/logging-guidelines.md`:级别/分类/标签规范 + 迁移指南。

差异:novel_builder 的 LlmLogger 拦截器在 app 层;study_buddy 的 LLM 出口在 engine 层。故 study_buddy 采用 **engine 抽象 sink + app 实现** 模式。

---

## 2. 总体架构

```
┌─────────────────── study_engine (纯 Dart,零 Flutter) ───────────────────┐
│                                                                          │
│  ① 新增 sink 抽象(纯 Dart 接口,默认 Null 实现):                        │
│     LoggerSink   ─ log(level, message, category, traceId, ...)           │
│     LlmCallSink  ─ onRequest→id / onResponse(id) / onError(id)           │
│                                                                          │
│  ② AgentLoop / LlmProvider / migrateDatabase 持有可空 sink,埋点上报      │
│     (sink 为 Null 时完全 no-op,engine 测试零负担)                        │
│                                                                          │
└──────────────────────────┬───────────────────────────────────────────────┘
                           │ 依赖方向:app → engine(engine 不反向依赖)
┌──────────────────────────┴──────────────── study_buddy (Flutter) ────────┐
│                                                                          │
│  ③ LoggerService (单例)  ─ 内存1000 FIFO + SP持久化(文件回退)            │
│     LlmLogger   (单例)  ─ JSONL按日文件 + 7天保留 + 完整响应体            │
│     两者实现 engine 的 sink 接口,AgentSession.run() 注入                 │
│                                                                          │
│  ④ traceId:AgentSession 生成 → 显式透传给所有 sink 调用                   │
│     app 层 LoggerService.withTraceId(Zone) 串联 app 自己的日志            │
│                                                                          │
│  ⑤ 查看页(纸感 _Article 风格):                                          │
│     /settings        ─ 设置页(承载入口,预留未来设置项)                  │
│     /logs/app        ─ App运行日志列表(过滤/搜索/详情/清空/导出)         │
│     /logs/llm        ─ LLM调用日志列表(列表/清空/占用)                   │
│     /logs/llm/:id    ─ LLM调用详情(请求/响应JSON + traceId)              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 核心设计决策

1. **engine 抽象 + app 实现**:engine 定义两个纯 Dart 接口,持有可空实例;app 实现接口,`AgentSession.run()` 注入。engine 保持纯 Dart 可测,app 换落盘实现 engine 零改动。
2. **traceId 显式透传,非 Zone 隐式**:traceId 由 `AgentSession`(app 层)生成,作为参数显式传入 engine 的 sink 调用。engine 是纯 Dart,不依赖 `dart:async` Zone 做隐式传参(测试不透明)。Zone 仅在 app 层 `LoggerService` 内部用于串联 app 自己的日志。
3. **LLM 拦截点选 `LlmProvider`** 而非 `IoLlmHttpClient`:LlmProvider 持有 model,且是 request 构造 + response 完整拼接的边界。HttpClient 层只能拿 SSE 原始行,拼不成完整 JSON。
4. **级别类型化,分类字符串化**:级别(debug/info/warning/error)跨项目通用,用 engine 枚举;分类是业务语义,engine 不定义业务枚举,用字符串让 app 自由约定,engine 只透传。

---

## 3. engine 层:Sink 接口与埋点

### 3.1 LoggerSink 接口

```dart
// study_engine/lib/src/logging/logger_sink.dart
enum LoggerLevel { debug, info, warning, error }

/// App 运行日志出口。engine 各模块通过此接口上报,默认 NullLoggerSink。
///
/// [category] 为字符串(非枚举):engine 不定义业务分类,由 app 约定
/// (study 用 database/ai/focus/plan/ui/general),engine 只透传。
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

/// noop 实现:engine 测试与未注入时使用。零开销。
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

### 3.2 LlmCallSink 接口

```dart
// study_engine/lib/src/logging/llm_call_sink.dart
/// LLM 调用观测出口。
/// id 由 sink 实现生成(onRequest 返回),engine 透传给 onResponse/onError 关联。
abstract class LlmCallSink {
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  });

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

  void onError(
    String id, {
    required String errorMessage,
    int? durationMs,
  });
}

class NullLlmCallSink implements LlmCallSink {
  const NullLlmCallSink();
  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) =>
      '';
  @override
  void onResponse(String id,
      {required String responseBody,
      required int durationMs,
      required bool isSuccess,
      String? errorMessage,
      int? promptTokens,
      int? completionTokens,
      int? totalTokens}) {}
  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {}
}
```

### 3.3 埋点注入与上报点

| 注入点 | 持有 sink | 构造默认 | 上报时机 |
|---|---|---|---|
| `AgentLoop` | `LoggerSink?` | `NullLoggerSink()` | round 开始/结束、工具调用开始/结束、compact、done、error |
| `LlmProvider` | `LlmCallSink?` + `LoggerSink?` | `NullLlmCallSink()` / `NullLoggerSink()` | `chatStreamWithTools`:开始(拼 request body)→ 流结束(拼完整 response + 提取 token + 计耗时)→ 异常(onError) |
| `migrateDatabase` | `LoggerSink?`(函数参数) | null | 每个版本迁移前后 |

#### 3.3.1 AgentLoop 埋点(伪代码)

```dart
class AgentLoop {
  final LoggerSink logger;
  // ...
  AgentLoop({
    required this.llm,
    required this.scenario,
    LoggerSink? logger,        // 新增,默认 Null
    ContextCompactor? compactor,
    this.maxRounds = 50,
  }) : logger = logger ?? const NullLoggerSink(),
       compactor = compactor ?? const ContextCompactor();

  Stream<AgentEvent> run(List<ChatMessage> messages, {AgentScenarioContext? context, String? traceId}) async* {
    logger.log(LoggerLevel.info, 'Agent 开始', category: 'ai', traceId: traceId, tags: ['agent-start']);
    // ...
    while (round < maxRounds) {
      logger.log(LoggerLevel.debug, '第 $round 轮开始', category: 'ai', traceId: traceId);
      // ... LLM 调用 ...
      for (final tc in agg) {
        logger.log(LoggerLevel.info, '工具调用: ${tc.name}', category: 'ai', traceId: traceId, tags: ['tool-call']);
        // ...
      }
      round++;
    }
    logger.log(LoggerLevel.info, 'Agent 完成', category: 'ai', traceId: traceId, tags: ['agent-done']);
  }
}
```

#### 3.3.2 LlmProvider 埋点(伪代码)

```dart
class LlmProvider {
  final LlmCallSink llmSink;
  final LoggerSink logger;
  // ...
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    final body = <String, Object?>{ /* 构造 request */ };
    final requestBody = jsonEncode(body);
    final sw = Stopwatch()..start();

    final id = llmSink.onRequest(
      endpoint: uri.toString(),
      model: config.model,
      requestBody: requestBody,
      isStreaming: true,
      traceId: traceId,
    );

    try {
      final fullResponse = StringBuffer();
      await for (final data in _client.postStream(uri, headers, body)) {
        fullResponse.write(data);   // 拼接完整响应
        // ... yield chunk ...
      }
      sw.stop();
      // 提取 token(从最后一个 chunk 的 usage,或聚合)
      llmSink.onResponse(id,
        responseBody: fullResponse.toString(),
        durationMs: sw.elapsedMilliseconds,
        isSuccess: true,
        promptTokens: ..., completionTokens: ..., totalTokens: ...,
      );
    } catch (e, st) {
      sw.stop();
      llmSink.onError(id, errorMessage: e.toString(), durationMs: sw.elapsedMilliseconds);
      logger.log(LoggerLevel.error, 'LLM 调用失败: $e', category: 'ai', traceId: traceId, stackTrace: st.toString());
      rethrow;
    }
  }
}
```

**注意**:SSE 流式响应的 token 统计——OpenAI 兼容协议流式模式下 `usage` 通常在末包或需设 `stream_options: {include_usage: true}`。本设计在 sink 实现层做尽力提取(LlmLogger 解析末包 usage),提取不到则 null。engine 侧只负责把原始数据传给 sink,不做协议级解析。

### 3.4 study_engine.dart 导出

```dart
// 新增导出
export 'src/logging/logger_sink.dart';
export 'src/logging/llm_call_sink.dart';
```

### 3.5 现有 engine 测试影响

- sink 构造参数可选且默认 Null,`AgentLoop`/`LlmProvider` 现有测试**零改动通过**。
- 新增 sink 的单元测试:注入 fake sink(记录调用),验证埋点正确性;Null sink 验证不爆。

---

## 4. app 层:服务实现

### 4.1 LoggerService(对齐 novel_builder,业务分类本地化)

| 维度 | 设计 |
|---|---|
| 存储 | 内存 1000 条 FIFO + SharedPreferences(文件回退 `app_logs_fallback.json`) |
| 分类枚举 | **`database` / `ai` / `focus` / `plan` / `ui` / `general`**(study 业务域) |
| 级别 | debug/info/warning/error,release 模式 debug 不写 |
| 通知 | `ValueNotifier<int> logChangeNotifier` 供查看页实时刷新 |
| 持久化 | 批量异步,1s 间隔,`_isPersisting` 锁防并发 |
| traceId | `withTraceId(id, action)` Zone 注入,app 层日志自动带;`currentTraceId` 读取 |
| 查询 | `getLogs` / `getLogsByLevel` / `getLogsByCategory` / `searchLogs` / `getStatistics` / `exportToFile` |
| 清理 | `clearLogs` / `removeLogsBefore` |
| 测试辅助 | `resetForTesting`(取消 pending timer + 重建 notifier) |

#### 实现 LoggerSink 接口

```dart
class LoggerService implements LoggerSink {
  @override
  void log(
    LoggerLevel level,
    String message, {
    String category = 'general',
    String? traceId,
    String? stackTrace,
    List<String> tags = const [],
  }) {
    // LoggerLevel → LogLevel 映射
    final ll = LogLevel.values[level.index]; // 枚举顺序对齐:debug/info/warning/error
    // category 字符串 → LogCategory(未知 category 归 general)
    final cat = _parseCategory(category);
    _writeLog(ll, message, category: cat, traceId: traceId, stackTrace: stackTrace, tags: tags);
  }
  // ... 其余对齐 novel_builder LoggerService ...
}
```

文件位置:`study_buddy/lib/core/services/logger_service.dart`

### 4.2 LlmLogger(对齐 novel_builder,新增 traceId 字段)

| 维度 | 设计 |
|---|---|
| 存储 | JSONL 文件 `llm_logs/llm_YYYYMMDD.jsonl`,7 天保留,异步写入队列 |
| 记录流程 | `onRequest`(仅更新内存缓存,不写文件)→ `onResponse`(合并 token/耗时/响应体,落盘)→ `onError` |
| 响应体 | 完整拼接,超 5MB 截断 |
| 缓存 | 内存最近 200 条,不足从文件补 |
| 通知 | `ChangeNotifier` + `ValueNotifier<int> changeNotifier` |
| id 生成 | 内部生成(时间戳 + 计数器),`onRequest` 返回 |
| 字段 | id/timestamp/endpoint/model/isStreaming/requestBody/responseBody/durationMs/isSuccess/errorMessage/prompt/completion/totalTokens/**traceId**(新增) |

#### 实现 LlmCallSink 接口

```dart
class LlmLogger implements LlmCallSink {
  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) {
    final id = _generateId();  // 内部生成
    final record = LlmCallRecord(
      id: id, timestamp: DateTime.now().toUtc(),
      endpoint: endpoint, model: model, isStreaming: isStreaming,
      requestBody: requestBody, isSuccess: false,
      traceId: traceId,  // 新增字段
    );
    _updateCache(record);  // 仅内存
    return id;
  }
  // onResponse / onError 对齐 novel_builder
}
```

文件位置:`study_buddy/lib/core/services/llm_logger/llm_logger.dart` + `llm_call_record.dart`

#### LlmCallRecord 数据模型

对齐 novel_builder,新增 `traceId` 字段:

```dart
class LlmCallRecord {
  final String id;
  final DateTime timestamp;
  final String endpoint;
  final String? model;
  final bool isStreaming;
  final String requestBody;
  final String? responseBody;
  final int? durationMs;
  final bool isSuccess;
  final String? errorMessage;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final String? traceId;  // 新增:与 App 日志交叉关联
  // fromJson / toJson / copyWith / previewText / durationText
}
```

### 4.3 AgentSession.run() 注入与 traceId

```dart
class AgentSession {
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {int? chatSessionId}) async {
    // ... 构造 db/repos ...
    final traceId = 'agent-${DateTime.now().millisecondsSinceEpoch}';

    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,      // 注入 LlmCallSink 实现
      logger: LoggerService.instance,    // 注入 LoggerSink 实现
    );
    final scenario = StudyScenario(/* ... */);
    final loop = AgentLoop(
      llm: llm,
      scenario: scenario,
      logger: LoggerService.instance,    // 注入 LoggerSink 实现
    );

    // traceId 经参数显式透传给 loop.run → llm.chatStreamWithTools
    return loop.run(
      messages,
      context: AgentScenarioContext(extra: ...),
      traceId: traceId,
    );
  }
}
```

### 4.4 初始化时序

```
app.dart _StudyBuddyAppState.initState
  └─ addPostFrameCallback:
       ├─ await LoggerService.instance.init()   // 加载 SP 历史
       ├─ await LlmLogger.instance.initialize() // 建目录 + 清过期 + 载缓存
       ├─ bootstrapOverlay(...)
       └─ recoverOrphan()

didChangeAppLifecycleState(paused) → LoggerService.instance.flush()
```

---

## 5. UI:纸感查看页 + 设置入口

### 5.1 路由新增(go_router)

```dart
// router.dart 新增
GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
GoRoute(path: '/logs/app', builder: (_, __) => const AppLogViewerPage()),
GoRoute(path: '/logs/llm', builder: (_, __) => const LlmLogViewerPage()),
GoRoute(path: '/logs/llm/:id', builder: (_, state) =>
    LlmLogDetailPage(recordId: state.pathParameters['id']!)),
```

### 5.2 设置页入口位置

首页 `_Masthead`(刊头)右上角加一个齿轮 IconButton(对齐状态栏,`context.go('/settings')`)。刊头本身无 AppBar,IconButton 用 Stack/Positioned 叠在 `_Masthead` 右上角,不破坏纸感主页结构,且不占正文纵向空间。

### 5.3 SettingsPage

纸感 `PaperScaffold` + `_Article` 容器,首个版块「诊断」:

```
┌─ 诊断 ─────────────────────────────────┐
│   应用日志            >  (→ /logs/app)  │
│   LLM 调用日志        >  (→ /logs/llm)  │
└─────────────────────────────────────────┘
```

为未来设置项(主题切换、LLM 配置管理、清除缓存)预留版块位。

### 5.4 AppLogViewerPage

- **顶部统计条**:总数 · 各级占比(DEBUG/INFO/WARN/ERROR)
- **级别过滤 chip**:多选级别
- **关键词搜索框**:匹配消息 + 标签
- **列表**:每条 = 时间 · 级别色标圆点 · `[分类]` · 消息(2 行截断) · traceId 末段(若有)
- **点击展开详情**:全消息 + 堆栈 + 分类 + 标签 + traceId,可复制
- **AppBar actions**:清空(确认) · 导出(写文件 + toast 路径)
- **实时刷新**:监听 `LoggerService.logChangeNotifier`
- **空态**:纸感插画 + "触发操作后将产生日志"

### 5.5 LlmLogViewerPage

- **统计条**:条数 · 占用大小(`getTotalSize`)
- **列表**:每条 = 成功/失败色标图标 · model(monospace) · `流式` tag(若是) · previewText(2 行) · 时间 · 耗时 · tokens
- **AppBar actions**:复制全部 · 刷新 · 清空(确认)
- **点击**:`context.go('/logs/llm/:id')`
- **实时刷新**:监听 `LlmLogger.changeNotifier`
- **空态**:"触发一次 AI 对话后将显示"

### 5.6 LlmLogDetailPage

- **概要卡**:时间 · 状态(成功/失败色) · model · Endpoint · 流式 · 耗时 · Tokens(prompt/completion/total) · **traceId**(可点击:跳转 App 日志并按 traceId 过滤)
- **请求体**:JSON 格式化缩进展示,SelectableText,monospace, maxHeight 360 滚动
- **响应体**:JSON 格式化(失败时显示 errorMessage)
- **错误信息**(若有且响应体也存在):独立分节
- **AppBar actions**:复制完整记录 JSON

### 5.7 纸感统一规范

所有新页面:
- `PaperScaffold` 包裹
- 列表项用极简 InkWell + 下沿 `PaperColors.ruleSoft` 细分隔线(对齐 `_PlanRow`),**不用 Material Card**
- 文章块容器复用 `_Article`(暖阴影 + 四角订书钉角标)——若查看页适合分块
- 字体:`NotoSerifSC`(标题/标签)+ monospace(model/JSON/endpoint)
- 级别色标:debug 灰 · info 苔绿(tertiary) · warn 金(paper.gold) · error 朱砂(primary)

---

## 6. 错误处理、测试、文档

### 6.1 错误处理

- **sink 调用全 try-catch 静默**:日志系统自身异常绝不影响业务(engine 侧 sink 调用包裹;app 侧 `_notifyReporter` 模式)。
- **LoggerService SP 写失败回退文件**(对齐 novel_builder),双失败标记 `_lastPersistSuccess = false`。
- **LlmLogger 初始化失败不阻塞应用**(catch + debugPrint)。
- **sink 注入为 null 时(engine 测试/未初始化)**:Null 实现,零开销 no-op。

### 6.2 测试策略

| 层 | 测试 | 工具 |
|---|---|---|
| engine sink 接口 | fake sink 记录调用,验证 AgentLoop/LlmProvider/migrateDatabase 埋点正确性;Null sink 验证不爆 | `test` 包,纯 Dart |
| engine 回归 | 现有 AgentLoop/LLM/DB 测试因 sink 默认 Null,零改动通过 | 现有测试 |
| LoggerService | 内存溢出 FIFO / SP 持久化往返 / 搜索 / 统计 / traceId Zone | `flutter_test`,`resetForTesting` |
| LlmLogger | req→resp 关联 / JSONL 读写 / 截断 / 7 天清理 / id 查询 | `flutter_test`,临时目录 |
| 查看页 widget | 列表渲染 / 级别过滤 / 搜索 / 清空确认 / 空态 | `flutter_test` |

### 6.3 文档

产出 `docs/logging-guidelines.md`(study 版,精简自 novel_builder):
- 日志级别规范(debug/info/warning/error 使用场景)
- 分类体系(database/ai/focus/plan/ui/general)
- engine sink 用法(如何在 engine 新模块埋点)
- 标签推荐
- 迁移指南(替换 `dart:developer.log`)

### 6.4 关键埋点清单(本期落地)

**engine 侧**:
- `migrateDatabase`:每版本迁移前后(INFO,database)
- `AgentLoop`:agent 开始/完成/错误、round 边界、工具调用(INFO/DEBUG,ai)
- `LlmProvider`:调用失败(ERROR,ai)—— 成功路径由 LlmCallSink 记录

**app 侧**:
- `app.dart`:启动初始化、生命周期 paused→flush(INFO,general)
- `AgentSession.run()`:traceId 生成、会话开始(INFO,ai)
- `update` 模块:现有 `dart:developer.log` 替换为 LoggerService(network/general)
- 各页面关键交互:页面跳转、设置变更(可选,INFO,ui)

---

## 7. 范围边界

### 本期做
- engine `LoggerSink`/`LlmCallSink` 接口 + Null 实现 + 导出
- engine AgentLoop / LlmProvider / migrateDatabase 埋点
- app `LoggerService` + `LlmLogger`(含 traceId)
- `AgentSession.run()` 注入 + traceId 生成
- 初始化时序(app.dart)
- 设置页 + 三个查看页(纸感)
- 路由新增
- engine/app 单元测试 + 查看 widget 测试
- `docs/logging-guidelines.md`

### 本期不做(留扩展点)
- **远程日志上报**:LoggerService 已有 reporter 回调钩子(对齐 novel_builder `_reporterCallback`),未来接 Sentry/自建后端。本期不实现。
- **崩溃收集**:已有 native crash handler 思路(novel_builder 有 crash_handler.c),本期不接。
- **日志级别运行时配置**:release 直接不写 debug,不做运行时开关。
- **app 层全量埋点**:仅埋关键路径(启动/会话/update),其余模块逐步迁移。

---

## 8. 文件清单

### engine 新增
- `packages/study_engine/lib/src/logging/logger_sink.dart`
- `packages/study_engine/lib/src/logging/llm_call_sink.dart`
- `packages/study_engine/test/logger_sink_test.dart`(接口契约 + Null)
- `packages/study_engine/test/llm_provider_logging_test.dart`(LlmProvider 埋点)

### engine 修改
- `packages/study_engine/lib/study_engine.dart`(导出 sink)
- `packages/study_engine/lib/src/agent/agent_loop.dart`(注入 LoggerSink + 埋点)
- `packages/study_engine/lib/src/llm/llm_provider_core.dart`(注入双 sink + 埋点)
- `packages/study_engine/lib/src/db/database_migrations.dart`(migrateDatabase 加 LoggerSink 参数)

### app 新增
- `study_buddy/lib/core/services/logger_service.dart`
- `study_buddy/lib/core/services/llm_logger/llm_logger.dart`
- `study_buddy/lib/core/services/llm_logger/llm_call_record.dart`
- `study_buddy/lib/features/settings/settings_page.dart`
- `study_buddy/lib/features/logs/app_log_viewer_page.dart`
- `study_buddy/lib/features/logs/llm_log_viewer_page.dart`
- `study_buddy/lib/features/logs/llm_log_detail_page.dart`
- 对应测试文件

### app 修改
- `study_buddy/lib/app.dart`(初始化 LoggerService + LlmLogger)
- `study_buddy/lib/router.dart`(4 条新路由)
- `study_buddy/lib/core/providers/agent_session_provider.dart`(注入 sink + traceId)
- `study_buddy/lib/features/home/home_page.dart`(设置入口)
- `study_buddy/lib/core/update/*.dart`(`dart:developer.log` → LoggerService)

### 文档
- `docs/logging-guidelines.md`
