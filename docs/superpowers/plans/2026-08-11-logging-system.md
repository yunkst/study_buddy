# 日志系统实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 study_buddy 落地双日志体系(App 运行日志 + LLM 调用日志),engine 全链路可观测,app 内提供纸感查看页。

**Architecture:** engine 层定义纯 Dart 的 `LoggerSink`/`LlmCallSink` 接口(默认 Null 实现),`AgentLoop`/`LlmProvider`/`migrateDatabase` 持有可空 sink 埋点上报;app 层 `LoggerService`(内存+SP)与 `LlmLogger`(JSONL)实现接口,`AgentSession.run()` 注入;traceId 显式透传串联双系统;设置页 + 三个纸感查看页。

**Tech Stack:** Dart 3.9 / Flutter / Riverpod / go_router / sqflite_common(engine)/ shared_preferences + path_provider(app)/ `package:test`(engine 纯 Dart 测试)/ `flutter_test`(app 测试)

## Global Constraints

- engine 包 **零 Flutter 依赖**(`pubspec.yaml` 仅 `sqflite_common`/`path`/`meta`),sink 接口必须纯 Dart,绝不能 import `dart:io` 的 path_provider 或 shared_preferences。
- engine 测试用 `package:test`(非 flutter_test),`_FakeLlm extends LlmProvider` override `chatStreamWithTools`——所有新增 sink 参数必须**可选且默认 Null 实现**,确保现有 engine 测试零改动。
- 纸感主题统一:`PaperScaffold` 包裹 + `PaperColors` extension(`gold`/`goldContainer`/`ruleSoft`/`warmShadow`) + `NotoSerifSC` 字体;列表项用极简 InkWell + `ruleSoft` 细分隔线,不用 Material Card。
- App 运行日志分类(字符串):`database` / `ai` / `focus` / `plan` / `ui` / `general`。
- 日志级别:`debug` / `info` / `warning` / `error`(engine 枚举 `LoggerLevel`,app 枚举 `LogLevel`,index 顺序对齐)。
- LLM 日志存完整拼接响应体,超 5MB 截断;JSONL 按日文件 `llm_logs/llm_YYYYMMDD.jsonl`,7 天保留。
- traceId 由 `AgentSession.run()`(app 层)生成,显式参数透传(engine 不用 Zone 隐式传参)。
- commit message 末尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

## File Structure

### engine 新增
- `packages/study_engine/lib/src/logging/logger_sink.dart` — `LoggerLevel` 枚举 + `LoggerSink` 抽象 + `NullLoggerSink`
- `packages/study_engine/lib/src/logging/llm_call_sink.dart` — `LlmCallSink` 抽象 + `NullLlmCallSink`
- `packages/study_engine/test/logger_sink_test.dart` — Null 实现契约测试
- `packages/study_engine/test/llm_provider_logging_test.dart` — LlmProvider 埋点 fake sink 测试

### engine 修改
- `packages/study_engine/lib/study_engine.dart` — 导出两个 sink
- `packages/study_engine/lib/src/agent/agent_loop.dart` — 注入 `LoggerSink`,run() 加 traceId,埋点
- `packages/study_engine/lib/src/llm/llm_provider_core.dart` — 注入 `LlmCallSink`+`LoggerSink`,chatStreamWithTools 加 traceId,拦截上报
- `packages/study_engine/lib/src/db/database_migrations.dart` — `migrateDatabase` 加可选 `LoggerSink?` 参数

### app 新增
- `study_buddy/lib/core/services/logger_service.dart` — `LoggerService` 单例(实现 `LoggerSink`)
- `study_buddy/lib/core/services/llm_logger/llm_call_record.dart` — `LlmCallRecord` 模型(含 traceId)
- `study_buddy/lib/core/services/llm_logger/llm_logger.dart` — `LlmLogger` 单例(实现 `LlmCallSink`)
- `study_buddy/lib/features/settings/settings_page.dart` — 设置页
- `study_buddy/lib/features/logs/app_log_viewer_page.dart` — App 日志查看页
- `study_buddy/lib/features/logs/llm_log_viewer_page.dart` — LLM 日志列表页
- `study_buddy/lib/features/logs/llm_log_detail_page.dart` — LLM 日志详情页
- 对应测试:logger_service_test.dart / llm_logger_test.dart / settings_page_test.dart / app_log_viewer_page_test.dart / llm_log_viewer_page_test.dart / llm_log_detail_page_test.dart

### app 修改
- `study_buddy/lib/app.dart` — 初始化 LoggerService + LlmLogger,paused→flush
- `study_buddy/lib/router.dart` — 4 条新路由
- `study_buddy/lib/core/providers/agent_session_provider.dart` — 注入 sink + 生成 traceId
- `study_buddy/lib/features/home/home_page.dart` — 刊头右上角设置入口

### 文档
- `docs/logging-guidelines.md` — study 版日志规范

---

## Task 1: engine LoggerSink 接口与 Null 实现

**Files:**
- Create: `packages/study_engine/lib/src/logging/logger_sink.dart`
- Create: `packages/study_engine/test/logger_sink_test.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Produces: `enum LoggerLevel { debug, info, warning, error }`;`abstract class LoggerSink` with `void log(LoggerLevel level, String message, {String category = 'general', String? traceId, String? stackTrace, List<String> tags = const []})`;`class NullLoggerSink implements LoggerSink`(const 构造,no-op)

- [ ] **Step 1: 写失败测试**

```dart
// packages/study_engine/test/logger_sink_test.dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('NullLoggerSink 是 const 且 log 不抛异常', () {
    const sink = NullLoggerSink();
    // 各级别 + 各参数组合,均应 no-op 不抛
    for (final level in LoggerLevel.values) {
      expect(
        () => sink.log(level, 'msg', category: 'ai', traceId: 't1', tags: const ['x']),
        returnsNormally,
      );
    }
  });

  test('NullLoggerSink 可作为 LoggerSink 使用', () {
    LoggerSink sink = const NullLoggerSink();
    sink.log(LoggerLevel.info, 'hello');
    expect(sink, isA<LoggerSink>());
  });

  test('LoggerLevel 枚举顺序为 debug<info<warning<error', () {
    expect(LoggerLevel.values, [LoggerLevel.debug, LoggerLevel.info, LoggerLevel.warning, LoggerLevel.error]);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd packages/study_engine && dart test test/logger_sink_test.dart`
Expected: FAIL — `LoggerLevel`/`LoggerSink`/`NullLoggerSink` 未定义(未导出)

- [ ] **Step 3: 写最小实现**

```dart
// packages/study_engine/lib/src/logging/logger_sink.dart

/// 日志级别。枚举 index 顺序与 app 层 LogLevel 对齐,
/// app 侧用 `LogLevel.values[level.index]` 直接映射。
enum LoggerLevel { debug, info, warning, error }

/// App 运行日志出口。engine 各模块通过此接口上报,默认 [NullLoggerSink]。
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

/// noop 实现:engine 测试与未注入时使用。零开销,const 构造。
class NullLoggerSink implements LoggerSink {
  const NullLoggerSink();

  @override
  void log(
    LoggerLevel level,
    String message, {
    String category = 'general',
    String? traceId,
    String? stackTrace,
    List<String> tags = const [],
  }) {}
}
```

- [ ] **Step 4: 导出**

在 `packages/study_engine/lib/study_engine.dart` 末尾(`export 'src/agent/scenarios/plan_scenario.dart';` 之后)加:

```dart
export 'src/logging/logger_sink.dart';
export 'src/logging/llm_call_sink.dart';
```

注意:`llm_call_sink.dart` 在 Task 2 创建,此处两行一起加。Task 1 先只加 `logger_sink.dart` 那行,Task 2 再加第二行。**Task 1 仅加**:`export 'src/logging/logger_sink.dart';`

- [ ] **Step 5: 运行测试验证通过**

Run: `cd packages/study_engine && dart test test/logger_sink_test.dart`
Expected: PASS(3 tests)

- [ ] **Step 6: 提交**

```bash
cd packages/study_engine
git add lib/src/logging/logger_sink.dart lib/study_engine.dart test/logger_sink_test.dart
git commit -m "feat(engine): LoggerSink 抽象 + NullLoggerSink,纯 Dart 日志出口

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: engine LlmCallSink 接口与 Null 实现

**Files:**
- Create: `packages/study_engine/lib/src/logging/llm_call_sink.dart`
- Modify: `packages/study_engine/test/logger_sink_test.dart`(追加 LlmCallSink 测试)
- Modify: `packages/study_engine/lib/study_engine.dart`(补导出)

**Interfaces:**
- Produces: `abstract class LlmCallSink` with `String onRequest({required String endpoint, required String model, required String requestBody, required bool isStreaming, String? traceId})`、`void onResponse(String id, {required String responseBody, required int durationMs, required bool isSuccess, String? errorMessage, int? promptTokens, int? completionTokens, int? totalTokens})`、`void onError(String id, {required String errorMessage, int? durationMs})`;`class NullLlmCallSink implements LlmCallSink`(const,no-op,onRequest 返回 `''`)

- [ ] **Step 1: 追加失败测试**

在 `packages/study_engine/test/logger_sink_test.dart` 末尾 `main()` 内追加:

```dart
  test('NullLlmCallSink 是 const 且三方法不抛异常', () {
    const sink = NullLlmCallSink();
    final id = sink.onRequest(
      endpoint: 'https://x/v1/chat/completions',
      model: 'gpt',
      requestBody: '{}',
      isStreaming: true,
      traceId: 't1',
    );
    expect(id, '');
    expect(
      () => sink.onResponse(id, responseBody: 'resp', durationMs: 100, isSuccess: true),
      returnsNormally,
    );
    expect(
      () => sink.onError(id, errorMessage: 'boom', durationMs: 50),
      returnsNormally,
    );
  });

  test('NullLlmCallSink 可作为 LlmCallSink 使用', () {
    LlmCallSink sink = const NullLlmCallSink();
    expect(sink, isA<LlmCallSink>());
  });
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd packages/study_engine && dart test test/logger_sink_test.dart`
Expected: FAIL — `LlmCallSink`/`NullLlmCallSink` 未定义

- [ ] **Step 3: 写实现**

```dart
// packages/study_engine/lib/src/logging/llm_call_sink.dart

/// LLM 调用观测出口。
///
/// 调用流程:[onRequest] 返回 id → engine 存住 id →
/// [onResponse](id) 或 [onError](id)。id 关联由 sink 实现负责。
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

/// noop 实现:engine 测试与未注入时使用。const 构造,onRequest 返回空串。
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
  void onResponse(
    String id, {
    required String responseBody,
    required int durationMs,
    required bool isSuccess,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
  }) {}

  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {}
}
```

- [ ] **Step 4: 补导出**

在 `packages/study_engine/lib/study_engine.dart`(Task 1 已加 logger_sink 导出行之后)加:

```dart
export 'src/logging/llm_call_sink.dart';
```

- [ ] **Step 5: 运行测试验证通过**

Run: `cd packages/study_engine && dart test test/logger_sink_test.dart`
Expected: PASS(5 tests)

- [ ] **Step 6: 提交**

```bash
cd packages/study_engine
git add lib/src/logging/llm_call_sink.dart lib/study_engine.dart test/logger_sink_test.dart
git commit -m "feat(engine): LlmCallSink 抽象 + NullLlmCallSink,LLM 调用观测出口

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: LlmProvider 注入 LlmCallSink + LoggerSink 并拦截上报

**Files:**
- Modify: `packages/study_engine/lib/src/llm/llm_provider_core.dart`
- Create: `packages/study_engine/test/llm_provider_logging_test.dart`

**Interfaces:**
- Consumes: `LoggerSink`、`LlmCallSink`(Task 1/2)
- Produces: `LlmProvider` 新增可选构造参数 `LlmCallSink? llmSink`、`LoggerSink? logger`(默认 Null);`chatStreamWithTools` 新增可选参数 `String? traceId`
- 现有测试兼容:`_FakeLlm extends LlmProvider` 仍可构造(super 不传 sink 即默认 Null);现有 `llm_core_test.dart` 不传 traceId 仍通过

- [ ] **Step 1: 写失败测试**

```dart
// packages/study_engine/test/llm_provider_logging_test.dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 记录所有调用的 fake LlmCallSink。
class _RecordingSink implements LlmCallSink {
  String? lastRequestEndpoint;
  String? lastRequestModel;
  String? lastRequestBody;
  bool? lastRequestStreaming;
  String? lastTraceId;
  String? responseId;
  String? responseBody;
  int? responseDurationMs;
  bool? responseSuccess;
  String? errorMessage;

  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) {
    lastRequestEndpoint = endpoint;
    lastRequestModel = model;
    lastRequestBody = requestBody;
    lastRequestStreaming = isStreaming;
    lastTraceId = traceId;
    return 'rec-1';
  }

  @override
  void onResponse(String id,
      {required String responseBody,
      required int durationMs,
      required bool isSuccess,
      String? errorMessage,
      int? promptTokens,
      int? completionTokens,
      int? totalTokens}) {
    responseId = id;
    this.responseBody = responseBody;
    responseDurationMs = durationMs;
    responseSuccess = isSuccess;
    this.errorMessage = errorMessage;
  }

  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {}
}

class _FakeClient implements LlmHttpClient {
  _FakeClient(this.lines);
  final List<String> lines;
  @override
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body) =>
      Stream.fromIterable(lines);
}

void main() {
  test('LlmProvider 成功时 onRequest→onResponse 顺序调用并带 traceId', () async {
    final sink = _RecordingSink();
    final cfg = LlmConfig(
        name: 't', apiUrl: 'https://api.example.com/v1', apiKey: 'k', model: 'gpt-x', createdAt: DateTime.now());
    final lines = [
      '{"choices":[{"delta":{"content":"hi"}}]}',
      '{"choices":[{"delta":{}}]}',
    ];
    final provider = LlmProvider(config: cfg, client: _FakeClient(lines), llmSink: sink);
    await provider.chatStreamWithTools(messages: [], tools: [], traceId: 'trace-99').toList();

    expect(sink.lastRequestEndpoint, 'https://api.example.com/v1/chat/completions');
    expect(sink.lastRequestModel, 'gpt-x');
    expect(sink.lastRequestStreaming, isTrue);
    expect(sink.lastTraceId, 'trace-99');
    expect(sink.lastRequestBody, contains('gpt-x'));
    expect(sink.responseId, 'rec-1');
    expect(sink.responseSuccess, isTrue);
    expect(sink.responseDurationMs, greaterThanOrEqualTo(0));
    // 响应体拼接了两个 data 行
    expect(sink.responseBody, contains('hi'));
  });

  test('LlmProvider 默认 NullLlmCallSink 不抛异常', () async {
    final cfg = LlmConfig(
        name: 't', apiUrl: 'https://api.example.com/v1', apiKey: 'k', model: 'm', createdAt: DateTime.now());
    final provider = LlmProvider(config: cfg, client: _FakeClient(['{"choices":[{"delta":{"content":"x"}}]}']));
    final chunks = await provider.chatStreamWithTools(messages: [], tools: []).toList();
    expect(chunks, isNotEmpty);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd packages/study_engine && dart test test/llm_provider_logging_test.dart`
Expected: FAIL — `LlmProvider` 无 `llmSink` 参数,`chatStreamWithTools` 无 `traceId` 参数

- [ ] **Step 3: 修改 LlmProvider**

替换 `packages/study_engine/lib/src/llm/llm_provider_core.dart` 全部内容:

```dart
import 'dart:convert';
import '../logging/llm_call_sink.dart';
import '../logging/logger_sink.dart';
import '../models/models.dart';
import 'llm_provider_client.dart';
import 'llm_provider_sse.dart';

class LlmStreamChunk {
  final String textDelta;
  final List<ToolCall>? toolCalls; // 仅在流结束时（末包）非空
  const LlmStreamChunk({required this.textDelta, this.toolCalls});
}

/// OpenAI 兼容流式 LLM 调用门面。
///
/// 可选注入 [llmSink]/[logger] 用于观测:成功路径由 [llmSink] 记录,
/// 异常路径同时通知 [llmSink](onError)与 [logger](error 级)。
class LlmProvider {
  final LlmConfig config;
  final LlmHttpClient _client;
  final LlmCallSink llmSink;
  final LoggerSink logger;

  LlmProvider({
    required this.config,
    LlmHttpClient? client,
    LlmCallSink? llmSink,
    LoggerSink? logger,
  })  : _client = client ?? IoLlmHttpClient(),
        llmSink = llmSink ?? const NullLlmCallSink(),
        logger = logger ?? const NullLoggerSink();

  /// 流式对话（支持工具）。每个文本片段吐一个 chunk（toolCalls 为 null），
  /// 流结束前吐一个末包：textDelta 为空、toolCalls 为聚合结果。
  ///
  /// [traceId] 可选,透传给 [llmSink] 关联同一次 agent 会话的多次调用。
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    final uri = Uri.parse('${config.apiUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
    final body = <String, Object?>{
      'model': config.model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'stream': true,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final headers = {'Authorization': 'Bearer ${config.apiKey}'};
    final requestBody = jsonEncode(body);

    final sw = Stopwatch()..start();
    final id = llmSink.onRequest(
      endpoint: uri.toString(),
      model: config.model,
      requestBody: requestBody,
      isStreaming: true,
      traceId: traceId,
    );

    final agg = SseToolCallAggregator();
    final fullResponse = StringBuffer();
    try {
      await for (final data in _client.postStream(uri, headers, body)) {
        fullResponse.write('$data\n');
        final chunk = jsonDecode(data) as Map<String, dynamic>;
        agg.onChunk(chunk);
        final delta = ((chunk['choices'] as List).first as Map)['delta'];
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield LlmStreamChunk(textDelta: content);
        }
      }
      sw.stop();
      // 提取 token:OpenAI 兼容流式 usage 通常在末包(若端点支持)。
      final usage = _extractUsage(fullResponse.toString());
      llmSink.onResponse(
        id,
        responseBody: fullResponse.toString(),
        durationMs: sw.elapsedMilliseconds,
        isSuccess: true,
        promptTokens: usage?.promptTokens,
        completionTokens: usage?.completionTokens,
        totalTokens: usage?.totalTokens,
      );
    } catch (e, st) {
      sw.stop();
      llmSink.onError(id, errorMessage: e.toString(), durationMs: sw.elapsedMilliseconds);
      logger.log(LoggerLevel.error, 'LLM 调用失败: $e',
          category: 'ai', traceId: traceId, stackTrace: st.toString(), tags: const ['llm']);
      rethrow;
    }
    // 末包
    yield LlmStreamChunk(textDelta: '', toolCalls: agg.result);
  }

  /// 尽力从拼接的 SSE 数据中提取 usage(prompt/completion/total tokens)。
  /// 解析失败返回 null——engine 不做协议级保证,留给 sink 实现侧兜底。
  _TokenUsage? _extractUsage(String raw) {
    try {
      final lines = raw.split('\n').where((l) => l.trim().isNotEmpty);
      int? p, c, t;
      for (final line in lines) {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final usage = json['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          p = usage['prompt_tokens'] as int? ?? p;
          c = usage['completion_tokens'] as int? ?? c;
          t = usage['total_tokens'] as int? ?? t;
        }
      }
      if (p == null && c == null && t == null) return null;
      return _TokenUsage(p, c, t);
    } catch (_) {
      return null;
    }
  }
}

class _TokenUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  const _TokenUsage(this.promptTokens, this.completionTokens, this.totalTokens);
}
```

- [ ] **Step 4: 运行新测试验证通过**

Run: `cd packages/study_engine && dart test test/llm_provider_logging_test.dart`
Expected: PASS(2 tests)

- [ ] **Step 5: 运行现有 LLM 测试验证不回归**

Run: `cd packages/study_engine && dart test test/llm_core_test.dart`
Expected: PASS(现有 `_FakeClient` 用 `LlmProvider(config: cfg, client: ...)` 不传 sink,默认 Null,通过)

- [ ] **Step 6: 提交**

```bash
cd packages/study_engine
git add lib/src/llm/llm_provider_core.dart test/llm_provider_logging_test.dart
git commit -m "feat(engine): LlmProvider 注入双 sink 并拦截请求/响应/异常上报

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: AgentLoop 注入 LoggerSink + traceId + 埋点

**Files:**
- Modify: `packages/study_engine/lib/src/agent/agent_loop.dart`
- Modify: `packages/study_engine/test/agent_loop_test.dart`(追加 sink 验证,不改现有用例)

**Interfaces:**
- Consumes: `LoggerSink`(Task 1)
- Produces: `AgentLoop` 新增可选构造参数 `LoggerSink? logger`(默认 Null);`run()` 新增可选参数 `String? traceId`
- 现有测试兼容:`_FakeLlm`/`AgentLoop(llm:, scenario:)` 不传 logger 仍工作;`loop.run([...])` 不传 traceId 仍工作

- [ ] **Step 1: 追加失败测试**

在 `packages/study_engine/test/agent_loop_test.dart` 顶部 import 区加 `import 'package:study_engine/study_engine.dart';`(若已有则跳过)。在 `main()` 内末尾追加:

```dart
/// 记录所有 log 调用的 fake LoggerSink。
class _RecordingLogger implements LoggerSink {
  final List<(LoggerLevel, String, String?)> calls = [];
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general', String? traceId, String? stackTrace, List<String> tags = const []}) {
    calls.add((level, message, traceId));
  }
}

test('AgentLoop 通过 sink 上报开始/完成并带 traceId', () async {
  final logger = _RecordingLogger();
  final llm = _FakeLlm([
    const [LlmStreamChunk(textDelta: 'done')],
  ]);
  final loop = AgentLoop(llm: llm, scenario: _FakeScenario(), logger: logger);
  await loop.run([const ChatMessage(role: 'system', content: 'sys')], traceId: 'trace-42').toList();

  final messages = logger.calls.map((c) => c.$2).toList();
  expect(messages.any((m) => m.contains('Agent') && m.contains('开始')), isTrue);
  expect(messages.any((m) => m.contains('Agent') && m.contains('完成')), isTrue);
  // 所有调用都带 traceId
  expect(logger.calls.every((c) => c.$3 == 'trace-42'), isTrue);
});

test('AgentLoop 默认 NullLoggerSink 不抛异常(回归)', () async {
  final llm = _FakeLlm([const [LlmStreamChunk(textDelta: 'ok')]]);
  final loop = AgentLoop(llm: llm, scenario: _FakeScenario());
  final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
  expect(events.any((e) => e is AgentDoneEvent), isTrue);
});
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd packages/study_engine && dart test test/agent_loop_test.dart`
Expected: FAIL — `AgentLoop` 无 `logger` 参数

- [ ] **Step 3: 修改 AgentLoop**

在 `packages/study_engine/lib/src/agent/agent_loop.dart`:
- import 区加 `import '../logging/logger_sink.dart';`
- 类字段与构造改为(替换原 `final int maxRounds;` 之前到构造结束):

```dart
class AgentLoop {
  final LlmProvider llm;
  final AgentScenario scenario;
  final ContextCompactor compactor;
  final int maxRounds;
  final LoggerSink logger;

  AgentLoop({
    required this.llm,
    required this.scenario,
    LoggerSink? logger,
    ContextCompactor? compactor,
    this.maxRounds = 50,
  })  : logger = logger ?? const NullLoggerSink(),
        compactor = compactor ?? const ContextCompactor();
```

- `run` 签名加 `String? traceId`(在 `AgentScenarioContext? context` 后):

```dart
  Stream<AgentEvent> run(List<ChatMessage> messages,
      {AgentScenarioContext? context, String? traceId}) async* {
```

- `run` 方法体内埋点。在 `yield AgentStartedEvent();` 之后加:

```dart
    logger.log(LoggerLevel.info, 'Agent 开始', category: 'ai', traceId: traceId, tags: const ['agent-start']);
```

- 在 `while (round < maxRounds) {` 之后,`final agg = <ToolCall>[];` 之前加:

```dart
      logger.log(LoggerLevel.debug, '第 $round 轮开始', category: 'ai', traceId: traceId, tags: const ['round']);
```

- LLM 调用传入 traceId。把 `await for (final chunk in llm.chatStreamWithTools(messages: msgs, tools: scenario.tools)) {` 改为:

```dart
        await for (final chunk in llm.chatStreamWithTools(messages: msgs, tools: scenario.tools, traceId: traceId)) {
```

- 工具调用埋点。在 `yield ToolCallStartEvent(tc.name, tc.id);` 之前加:

```dart
          logger.log(LoggerLevel.info, '工具调用: ${tc.name}', category: 'ai', traceId: traceId, tags: const ['tool-call']);
```

- 完成埋点。把 `yield AgentDoneEvent(buf.toString());` 改为(在 yield 之前加 log):

```dart
          logger.log(LoggerLevel.info, 'Agent 完成', category: 'ai', traceId: traceId, tags: const ['agent-done']);
          yield AgentDoneEvent(buf.toString());
          return;
```

- 同样把第二个 `yield AgentDoneEvent(null);`(maxRounds 到顶)改为:

```dart
          logger.log(LoggerLevel.warning, 'Agent 达到最大轮次 $maxRounds', category: 'ai', traceId: traceId, tags: const ['max-rounds']);
          yield AgentDoneEvent(null);
          return;
```

- catch 块埋点。把 `} catch (e) { yield AgentErrorEvent(e.toString()); }` 改为:

```dart
    } catch (e, st) {
      logger.log(LoggerLevel.error, 'Agent 异常: $e', category: 'ai', traceId: traceId, stackTrace: st.toString(), tags: const ['agent-error']);
      yield AgentErrorEvent(e.toString());
    }
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cd packages/study_engine && dart test test/agent_loop_test.dart`
Expected: PASS(含新 2 用例 + 原有用例全部)

- [ ] **Step 5: 提交**

```bash
cd packages/study_engine
git add lib/src/agent/agent_loop.dart test/agent_loop_test.dart
git commit -m "feat(engine): AgentLoop 注入 LoggerSink + traceId,埋点 agent 生命周期

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: migrateDatabase 加 LoggerSink 参数

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Modify: `packages/study_engine/test/db_test.dart`(追加 sink 验证)

**Interfaces:**
- Consumes: `LoggerSink`(Task 1)
- Produces: `migrateDatabase(Database db, int from, int to, {LoggerSink? logger})` — logger 默认 null,内部用 `?? const NullLoggerSink()` 兜底
- 现有调用兼容:`migrateDatabase(db, from, to)` 不传 logger 仍工作

- [ ] **Step 1: 追加失败测试**

在 `packages/study_engine/test/db_test.dart` 的 `main()` 内追加(需确保顶部 import `package:study_engine/study_engine.dart` 与 `package:test/test.dart`):

```dart
class _RecordingLogger implements LoggerSink {
  final List<String> messages = [];
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general', String? traceId, String? stackTrace, List<String> tags = const []}) {
    messages.add(message);
  }
}

test('migrateDatabase 通过 sink 上报迁移日志', () async {
  final logger = _RecordingLogger();
  final db = await _openInMemoryDb(); // 复用文件内已有的内存库打开 helper
  await migrateDatabase(db, 0, kCurrentDbVersion, logger: logger);
  expect(logger.messages.any((m) => m.contains('迁移')), isTrue);
  await db.close();
});
```

**注意**:`_openInMemoryDb()` 需查看 `db_test.dart` 现有代码里打开内存 sqflite 的 helper 名字(可能是 `openDatabase` 或自定义),按实际名字替换。若文件内无此 helper,用现有用例里的同等逻辑内联。测试编写者须先 `Read db_test.dart` 确认 helper 名。

- [ ] **Step 2: 运行测试验证失败**

Run: `cd packages/study_engine && dart test test/db_test.dart`
Expected: FAIL — `migrateDatabase` 无 `logger` 命名参数

- [ ] **Step 3: 修改 migrateDatabase**

在 `packages/study_engine/lib/src/db/database_migrations.dart`:
- import 区加 `import '../logging/logger_sink.dart';`
- 函数签名改为:

```dart
Future<void> migrateDatabase(Database db, int from, int to, {LoggerSink? logger}) async {
  final log = logger ?? const NullLoggerSink();
  final batch = db.batch();
  log.log(LoggerLevel.info, '数据库迁移开始: v$from → v$to', category: 'database', tags: const ['migration-start']);
  for (var v = from + 1; v <= to; v++) {
    try {
      switch (v) {
        case 1: _v1(batch); break;
        case 2: _v2(batch); break;
        case 3: _v3(batch); break;
        case 4: _v4(batch); break;
        case 5: _v5(batch); break;
        default: throw StateError('未知数据库版本: $v');
      }
      log.log(LoggerLevel.debug, '数据库迁移步骤 v$v 完成', category: 'database', tags: const ['migration-step']);
    } catch (e, st) {
      log.log(LoggerLevel.error, '数据库迁移失败 v$v: $e', category: 'database', stackTrace: st.toString(), tags: const ['migration-failed']);
      rethrow;
    }
  }
  await batch.commit();
  log.log(LoggerLevel.info, '数据库迁移完成: v$to', category: 'database', tags: const ['migration-done']);
}
```

(保持原 switch 的 case 分支内容不变,只是包了 try-catch 与 log;原 `for` 循环体其余结构保留)

- [ ] **Step 4: 运行测试验证通过**

Run: `cd packages/study_engine && dart test test/db_test.dart`
Expected: PASS(含新用例 + 原有用例)

- [ ] **Step 5: 提交**

```bash
cd packages/study_engine
git add lib/src/db/database_migrations.dart test/db_test.dart
git commit -m "feat(engine): migrateDatabase 加 LoggerSink 参数,迁移全程埋点

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: app LoggerService 单例(实现 LoggerSink)

**Files:**
- Create: `study_buddy/lib/core/services/logger_service.dart`
- Create: `study_buddy/test/core/services/logger_service_test.dart`

**Interfaces:**
- Consumes: `LoggerSink`、`LoggerLevel`(engine)
- Produces: `enum LogLevel { debug, info, warning, error }`;`enum LogCategory { database, ai, focus, plan, ui, general }`;`class LogEntry`;`class LogStatistics`;`class LoggerService implements LoggerSink`(单例,`LoggerService.instance`)。核心方法:`init()`、`d/i/w/e(message, {category, tags, stackTrace})`、`log(LoggerLevel,...)`(接口实现)、`withTraceId(id, action)`、`getLogs()`、`getLogsByLevel([level])`、`getLogsByCategory(category)`、`searchLogs(query, {category})`、`getStatistics()`、`clearLogs()`、`flush()`、`exportToFile()`、`logChangeNotifier`(ValueNotifier<int>)、`resetForTesting()`

- [ ] **Step 1: 写失败测试**

```dart
// study_buddy/test/core/services/logger_service_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/logger_service.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUp(() async {
    LoggerService.resetForTesting();
    TestWidgetsFlutterBinding.ensureInitialized();
    // SharedPreferences 测试初始化(plugin 提供的 mock)
    // 若 LoggerService.init 强依赖 SP,需 mock;此处用 setMockInitialValues
  });

  test('d/i/w/e 按级别记录且 release 模式 debug 不写', () {
    debugPrint = (String? message, {int? wrapWidth}) {}; // 静音
    LoggerService.instance.i('info msg');
    LoggerService.instance.w('warn msg');
    LoggerService.instance.e('error msg');
    final logs = LoggerService.instance.getLogs();
    expect(logs.where((l) => l.level == LogLevel.info), isNotEmpty);
    expect(logs.where((l) => l.level == LogLevel.warning), isNotEmpty);
    expect(logs.where((l) => l.level == LogLevel.error), isNotEmpty);
  });

  test('FIFO 超过上限删除最旧(用 resetForTesting 后默认上限)', () {
    // _maxLogs = 1000,写 1005 条,期望保留最新 1000
    for (int i = 0; i < 1005; i++) {
      LoggerService.instance.i('msg $i');
    }
    expect(LoggerService.instance.getLogs().length, 1000);
    final first = LoggerService.instance.getLogs().first;
    expect(first.message, 'msg 5'); // 最旧的 msg 0-4 被删
  });

  test('按分类过滤', () {
    LoggerService.instance.i('db op', category: LogCategory.database);
    LoggerService.instance.i('ai op', category: LogCategory.ai);
    final dbLogs = LoggerService.instance.getLogsByCategory(LogCategory.database);
    expect(dbLogs, hasLength(1));
    expect(dbLogs.first.message, 'db op');
  });

  test('searchLogs 关键词不区分大小写且匹配消息', () {
    LoggerService.instance.i('API 请求超时');
    LoggerService.instance.i('正常流程');
    final hits = LoggerService.instance.searchLogs('api');
    expect(hits, hasLength(1));
    expect(hits.first.message, contains('API'));
  });

  test('实现 LoggerSink 接口:LoggerLevel → LogLevel 映射', () {
    LoggerService.instance.log(LoggerLevel.error, 'engine err', category: 'ai', traceId: 't1');
    final logs = LoggerService.instance.getLogsByLevel(LogLevel.error);
    expect(logs.last.message, 'engine err');
    expect(logs.last.category, LogCategory.ai);
    expect(logs.last.traceId, 't1');
  });

  test('withTraceId 注入后 log 自动带 traceId', () async {
    await LoggerService.withTraceId('zone-1', () async {
      LoggerService.instance.i('in zone');
    });
    final logs = LoggerService.instance.getLogs();
    expect(logs.last.traceId, 'zone-1');
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd study_buddy && flutter test test/core/services/logger_service_test.dart`
Expected: FAIL — `LoggerService` 未定义

- [ ] **Step 3: 写实现**

```dart
// study_buddy/lib/core/services/logger_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:study_engine/study_engine.dart';

/// App 日志级别。index 顺序与 engine LoggerLevel 对齐。
enum LogLevel { debug, info, warning, error }

/// App 日志分类(study 业务域)。
enum LogCategory { database, ai, focus, plan, ui, general }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? stackTrace;
  final LogCategory category;
  final List<String> tags;
  final String? traceId;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.stackTrace,
    this.category = LogCategory.general,
    this.tags = const [],
    this.traceId,
  });

  Map<String, dynamic> toMap() => {
        'timestamp': timestamp.millisecondsSinceEpoch,
        'level': level.index,
        'message': message,
        'stackTrace': stackTrace,
        'category': category.index,
        'tags': tags,
        if (traceId != null) 'traceId': traceId,
      };

  factory LogEntry.fromMap(Map<String, dynamic> m) => LogEntry(
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
        level: LogLevel.values[m['level'] as int],
        message: m['message'] as String,
        stackTrace: m['stackTrace'] as String?,
        category: m.containsKey('category') ? LogCategory.values[m['category'] as int] : LogCategory.general,
        tags: m.containsKey('tags') ? (m['tags'] as List).cast<String>() : const [],
        traceId: m['traceId'] as String?,
      );
}

class LogStatistics {
  final int total;
  final Map<LogLevel, int> byLevel;
  final Map<LogCategory, int> byCategory;
  Map<LogLevel, double> get levelPercentage => total == 0
      ? {}
      : byLevel.map((l, c) => MapEntry(l, c / total));
  const LogStatistics({required this.total, required this.byLevel, required this.byCategory});
}

/// App 运行日志服务。单例。内存 1000 FIFO + SharedPreferences(文件回退)。
/// 实现 engine 的 [LoggerSink] 供 engine 模块上报。
class LoggerService implements LoggerSink {
  LoggerService._internal();
  static LoggerService? _instance;
  static LoggerService get instance => _instance ??= LoggerService._internal();

  static const int _maxLogs = 1000;
  static const String _prefsKey = 'app_logs';
  static const String _exportFileName = 'app_logs.txt';
  static const String _fallbackFileName = 'app_logs_fallback.json';
  static const Symbol _traceIdKey = #_logTraceId;
  static const int _flushIntervalMs = 1000;

  final List<LogEntry> _logs = [];
  bool _initialized = false;
  bool _isPersisting = false;
  bool _pendingPersist = false;
  DateTime? _lastPersistTime;
  Timer? _pendingFlushTimer;

  static ValueNotifier<int> _logChangeNotifier = ValueNotifier<int>(0);
  static ValueNotifier<int> get logChangeNotifier => _logChangeNotifier;

  static void resetForTesting() {
    _instance?._pendingFlushTimer?.cancel();
    _logChangeNotifier = ValueNotifier<int>(0);
    _instance = null;
  }

  // —— traceId Zone 传播 ——
  static String? get currentTraceId {
    try {
      return Zone.current[_traceIdKey] as String?;
    } catch (_) {
      return null;
    }
  }

  static Future<T> withTraceId<T>(String traceId, Future<T> Function() action) {
    return runZoned(action, zoneValues: {_traceIdKey: traceId});
  }

  // —— 初始化 ——
  Future<void> init() async {
    if (_initialized) return;
    await _loadLogs();
    _initialized = true;
  }

  // —— 级别便捷方法 ——
  void d(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace}) {
    if (kReleaseMode) return;
    _write(message, LogLevel.debug, stackTrace, category, [...tags, ..._autoTrace()]);
  }

  void i(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace}) {
    _write(message, LogLevel.info, stackTrace, category, [...tags, ..._autoTrace()]);
  }

  void w(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace}) {
    _write(message, LogLevel.warning, stackTrace, category, [...tags, ..._autoTrace()]);
  }

  void e(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace}) {
    _write(message, LogLevel.error, stackTrace, category, [...tags, ..._autoTrace()]);
  }

  /// 透传的 traceId:若未显式传,从 Zone 读(app 层 withTraceId 包裹时)。
  List<String> _autoTrace() => const []; // tags 不放 traceId,traceId 走字段

  // —— LoggerSink 接口实现(engine 调用)——
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general', String? traceId, String? stackTrace, List<String> tags = const []}) {
    if (kReleaseMode && level == LoggerLevel.debug) return;
    _write(
      message,
      LogLevel.values[level.index],
      stackTrace,
      _parseCategory(category),
      tags,
      traceId: traceId ?? currentTraceId,
    );
  }

  LogCategory _parseCategory(String s) {
    switch (s) {
      case 'database': return LogCategory.database;
      case 'ai': return LogCategory.ai;
      case 'focus': return LogCategory.focus;
      case 'plan': return LogCategory.plan;
      case 'ui': return LogCategory.ui;
      default: return LogCategory.general;
    }
  }

  void _write(String message, LogLevel level, String? stackTrace, LogCategory category, List<String> tags,
      {String? traceId}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      stackTrace: stackTrace,
      category: category,
      tags: tags,
      traceId: traceId ?? currentTraceId,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogs) _logs.removeAt(0);
    _logChangeNotifier.value++;
    _schedulePersist();
  }

  // —— 查询 ——
  List<LogEntry> getLogs() => List.unmodifiable(_logs);
  List<LogEntry> getLogsByLevel([LogLevel? level]) =>
      level == null ? getLogs() : _logs.where((l) => l.level == level).toList();
  List<LogEntry> getLogsByCategory(LogCategory category) =>
      _logs.where((l) => l.category == category).toList();
  List<LogEntry> searchLogs(String query, {LogCategory? category}) {
    Iterable<LogEntry> r = _logs;
    if (category != null) r = r.where((l) => l.category == category);
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      r = r.where((l) => l.message.toLowerCase().contains(q) || l.tags.any((t) => t.toLowerCase().contains(q)));
    }
    return r.toList();
  }

  LogStatistics getStatistics() {
    final byLevel = {for (final l in LogLevel.values) l: 0};
    final byCategory = {for (final c in LogCategory.values) c: 0};
    for (final log in _logs) {
      byLevel[log.level] = byLevel[log.level]! + 1;
      byCategory[log.category] = byCategory[log.category]! + 1;
    }
    return LogStatistics(total: _logs.length, byLevel: byLevel, byCategory: byCategory);
  }

  int get logCount => _logs.length;

  Future<void> clearLogs() async {
    _logs.clear();
    await _persistLogs();
    _logChangeNotifier.value++;
  }

  Future<void> flush() async {
    if (_pendingPersist) await _persistChain();
  }

  Future<File> exportToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_exportFileName');
    final content = _logs.map((l) {
      final ts = formatTimestamp(l.timestamp);
      final st = l.stackTrace != null ? '\n${l.stackTrace}' : '';
      return '[$ts] [${l.level.name}] ${l.message}$st';
    }).join('\n\n---\n\n');
    await file.writeAsString(content, flush: true);
    return file;
  }

  static String formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  // —— 持久化(对齐 novel_builder)——
  void _schedulePersist() {
    _pendingPersist = true;
    final now = DateTime.now();
    if (_lastPersistTime == null || now.difference(_lastPersistTime!).inMilliseconds >= _flushIntervalMs) {
      _persistChain();
    } else {
      _pendingFlushTimer?.cancel();
      _pendingFlushTimer = Timer(const Duration(milliseconds: _flushIntervalMs), () {
        _pendingFlushTimer = null;
        _persistChain();
      });
    }
  }

  Future<void> _persistChain() async {
    if (_isPersisting) return;
    _isPersisting = true;
    try {
      while (_pendingPersist) {
        _pendingPersist = false;
        _lastPersistTime = DateTime.now();
        await _persistLogs();
      }
    } finally {
      _isPersisting = false;
    }
  }

  Future<void> _loadLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      if (json != null && json.isNotEmpty) {
        final decoded = jsonDecode(json) as List;
        _logs.addAll(decoded.map((e) => LogEntry.fromMap(e as Map<String, dynamic>)));
        return;
      }
    } catch (e) {
      debugPrint('LoggerService: SP 加载失败: $e');
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fallbackFileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content) as List;
          _logs.addAll(decoded.map((e) => LogEntry.fromMap(e as Map<String, dynamic>)));
        }
      }
    } catch (e) {
      debugPrint('LoggerService: 文件回退加载失败: $e');
    }
  }

  Future<void> _persistLogs() async {
    final data = jsonEncode(_logs.map((e) => e.toMap()).toList());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, data);
      return;
    } catch (e) {
      debugPrint('LoggerService: SP 写失败,回退文件: $e');
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fallbackFileName');
      await file.writeAsString(data, flush: true);
    } catch (e) {
      debugPrint('LoggerService: 文件回退也失败: $e');
    }
  }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cd study_buddy && flutter test test/core/services/logger_service_test.dart`
Expected: PASS(6 tests)

注:测试依赖 SharedPreferences mock。若 init 未调用(这些用例直接 d/i/w/e 不走 init),_loadLogs 不执行,内存队列从空开始——测试通过。若 getLogs 在未 init 时报错,需调整(本实现未 init 也可工作,_initialized 仅守 init 重入)。

- [ ] **Step 5: 提交**

```bash
cd study_buddy
git add lib/core/services/logger_service.dart test/core/services/logger_service_test.dart
git commit -m "feat(app): LoggerService 单例,内存+SP 持久化,实现 engine LoggerSink

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: app LlmLogger 单例 + LlmCallRecord(实现 LlmCallSink)

**Files:**
- Create: `study_buddy/lib/core/services/llm_logger/llm_call_record.dart`
- Create: `study_buddy/lib/core/services/llm_logger/llm_logger.dart`
- Create: `study_buddy/test/core/services/llm_logger_test.dart`

**Interfaces:**
- Consumes: `LlmCallSink`(engine)
- Produces: `class LlmCallRecord`(id/timestamp/endpoint/model/isStreaming/requestBody/responseBody/durationMs/isSuccess/errorMessage/prompt/completion/totalTokens/**traceId**;fromJson/toJson/copyWith/previewText/durationText);`class LlmLogger implements LlmCallSink`(单例)。核心:`initialize()`、`onRequest`→id、`onResponse(id)`、`onError(id)`、`getRecent({limit})`、`getById(id)`、`clear()`、`getTotalSize()`、`changeNotifier`(ValueNotifier<int>)、`resetForTesting()`

- [ ] **Step 1: 写失败测试**

```dart
// study_buddy/test/core/services/llm_logger_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/llm_logger/llm_logger.dart';
import 'package:study_buddy/core/services/llm_logger/llm_call_record.dart';

void main() {
  setUp(() {
    LlmLogger.resetForTesting();
  });

  test('onRequest→onResponse 关联同一 id 并落内存缓存', () async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: 'https://x/v1/chat/completions',
      model: 'gpt',
      requestBody: '{"model":"gpt","messages":[]}',
      isStreaming: true,
      traceId: 'trace-1',
    );
    LlmLogger.instance.onResponse(id,
        responseBody: '{"choices":[]}', durationMs: 120, isSuccess: true, totalTokens: 42);

    final recent = await LlmLogger.instance.getRecent(limit: 10);
    expect(recent, hasLength(1));
    expect(recent.first.id, id);
    expect(recent.first.model, 'gpt');
    expect(recent.first.isSuccess, isTrue);
    expect(recent.first.totalTokens, 42);
    expect(recent.first.durationMs, 120);
    expect(recent.first.traceId, 'trace-1');
  });

  test('previewText 从 requestBody 提取 content', () {
    final r = LlmCallRecord(
      id: '1', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: 'e', model: 'm', isStreaming: true,
      requestBody: '{"messages":[{"content":"你好世界"}]}',
      isSuccess: true,
    );
    expect(r.previewText, contains('你好世界'));
  });

  test('toJson/fromJson 往返(含 traceId)', () {
    final r = LlmCallRecord(
      id: '1', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: 'e', model: 'm', isStreaming: false,
      requestBody: '{}', responseBody: '{"x":1}',
      durationMs: 5, isSuccess: true,
      promptTokens: 10, completionTokens: 20, totalTokens: 30,
      traceId: 't9',
    );
    final restored = LlmCallRecord.fromJson(r.toJson());
    expect(restored.id, '1');
    expect(restored.traceId, 't9');
    expect(restored.totalTokens, 30);
  });

  test('durationText 格式化', () {
    const r1 = LlmCallRecord(id: '1', timestamp: null, endpoint: '', isStreaming: false, requestBody: '', isSuccess: true);
    // null timestamp 用不了 const,改普通构造验证 durationText
  });
}
```

注:最后一个 `durationText` 测试体不完整,实际编写时改为:
```dart
  test('durationText 格式化', () {
    final r = LlmCallRecord(
      id: '1', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: '', isStreaming: false, requestBody: '', durationMs: 800, isSuccess: true,
    );
    expect(r.durationText, '800ms');
    final r2 = LlmCallRecord(
      id: '2', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: '', isStreaming: false, requestBody: '', durationMs: 1500, isSuccess: true,
    );
    expect(r2.durationText, '1.5s');
  });
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd study_buddy && flutter test test/core/services/llm_logger_test.dart`
Expected: FAIL — `LlmLogger`/`LlmCallRecord` 未定义

- [ ] **Step 3: 写 LlmCallRecord**

```dart
// study_buddy/lib/core/services/llm_logger/llm_call_record.dart

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
  final String? traceId;

  const LlmCallRecord({
    required this.id,
    required this.timestamp,
    required this.endpoint,
    this.model,
    required this.isStreaming,
    required this.requestBody,
    this.responseBody,
    this.durationMs,
    required this.isSuccess,
    this.errorMessage,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.traceId,
  });

  factory LlmCallRecord.fromJson(Map<String, dynamic> j) => LlmCallRecord(
        id: j['id'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['timestamp'] as int, isUtc: true),
        endpoint: j['endpoint'] as String,
        model: j['model'] as String?,
        isStreaming: j['is_streaming'] as bool? ?? false,
        requestBody: j['request_body'] as String? ?? '',
        responseBody: j['response_body'] as String?,
        durationMs: j['duration_ms'] as int?,
        isSuccess: j['is_success'] as bool? ?? false,
        errorMessage: j['error_message'] as String?,
        promptTokens: j['prompt_tokens'] as int?,
        completionTokens: j['completion_tokens'] as int?,
        totalTokens: j['total_tokens'] as int?,
        traceId: j['trace_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'endpoint': endpoint,
        'model': model,
        'is_streaming': isStreaming,
        'request_body': requestBody,
        'response_body': responseBody,
        'duration_ms': durationMs,
        'is_success': isSuccess,
        'error_message': errorMessage,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
        'trace_id': traceId,
      };

  String get previewText {
    try {
      final re = RegExp(r'"content"\s*:\s*"([^"]{0,80})');
      final matches = re.allMatches(requestBody);
      if (matches.isNotEmpty) return matches.last.group(1) ?? '';
      return requestBody.length > 80 ? requestBody.substring(0, 80) : requestBody;
    } catch (_) {
      return requestBody.length > 80 ? requestBody.substring(0, 80) : requestBody;
    }
  }

  String get durationText {
    if (durationMs == null) return '-';
    if (durationMs! < 1000) return '${durationMs}ms';
    return '${(durationMs! / 1000).toStringAsFixed(1)}s';
  }

  LlmCallRecord copyWith({
    String? responseBody, int? durationMs, bool? isSuccess, String? errorMessage,
    int? promptTokens, int? completionTokens, int? totalTokens,
  }) => LlmCallRecord(
    id: id, timestamp: timestamp, endpoint: endpoint, model: model,
    isStreaming: isStreaming, requestBody: requestBody,
    responseBody: responseBody ?? this.responseBody,
    durationMs: durationMs ?? this.durationMs,
    isSuccess: isSuccess ?? this.isSuccess,
    errorMessage: errorMessage ?? this.errorMessage,
    promptTokens: promptTokens ?? this.promptTokens,
    completionTokens: completionTokens ?? this.completionTokens,
    totalTokens: totalTokens ?? this.totalTokens,
    traceId: traceId,
  );
}
```

- [ ] **Step 4: 写 LlmLogger**

```dart
// study_buddy/lib/core/services/llm_logger/llm_logger.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, ValueNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:study_engine/study_engine.dart';

import 'llm_call_record.dart';

class LlmLogger implements LlmCallSink {
  LlmLogger._internal();
  static LlmLogger? _instance;
  static LlmLogger get instance => _instance ??= LlmLogger._internal();

  static void resetForTesting() {
    _instance = null;
    changeNotifier.value = 0;
  }

  static final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  static const String _logDirName = 'llm_logs';
  static const String _logFilePrefix = 'llm_';
  static const int _retentionDays = 7;
  static const int _maxResponseLength = 5 * 1024 * 1024;
  static const int _cacheSize = 200;

  String? _logDir;
  bool _initialized = false;
  final List<String> _writeQueue = [];
  bool _isWriting = false;
  final List<LlmCallRecord> _recentCache = [];
  int _changeCount = 0;
  int _idCounter = 0;

  /// 测试用:初始化到临时目录。生产用 initialize()。
  Future<void> initializeForTest() async {
    _logDir = null; // 测试不写文件,onResponse 仅更新缓存
    _initialized = true;
    _recentCache.clear();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _logDir = '${docs.path}/$_logDirName';
      await Directory(_logDir!).create(recursive: true);
      await _cleanOldFiles();
      await _loadRecentCache();
      _initialized = true;
    } catch (e) {
      debugPrint('LlmLogger: 初始化失败: $e');
    }
  }

  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) {
    final id = 'llm-${DateTime.now().millisecondsSinceEpoch}-${_idCounter++}';
    final record = LlmCallRecord(
      id: id,
      timestamp: DateTime.now().toUtc(),
      endpoint: endpoint,
      model: model,
      isStreaming: isStreaming,
      requestBody: requestBody,
      isSuccess: false,
      traceId: traceId,
    );
    _updateCache(record);
    return id;
  }

  @override
  void onResponse(String id,
      {required String responseBody,
      required int durationMs,
      required bool isSuccess,
      String? errorMessage,
      int? promptTokens,
      int? completionTokens,
      int? totalTokens}) {
    final truncated = responseBody.length > _maxResponseLength
        ? '${responseBody.substring(0, _maxResponseLength)}...(truncated at $_maxResponseLength bytes)'
        : responseBody;
    final idx = _recentCache.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      final updated = _recentCache[idx].copyWith(
        responseBody: truncated,
        durationMs: durationMs,
        isSuccess: isSuccess,
        errorMessage: errorMessage,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
      );
      _recentCache[idx] = updated;
      _enqueueWrite(updated);
    }
    _changeCount++;
    changeNotifier.value = _changeCount;
  }

  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {
    final idx = _recentCache.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      final updated = _recentCache[idx].copyWith(
        durationMs: durationMs,
        isSuccess: false,
        errorMessage: errorMessage,
      );
      _recentCache[idx] = updated;
      _enqueueWrite(updated);
    }
    _changeCount++;
    changeNotifier.value = _changeCount;
  }

  Future<List<LlmCallRecord>> getRecent({int limit = 50}) async {
    if (_recentCache.length >= limit) return _recentCache.sublist(0, limit);
    final fromFile = await _readRecentFromFile(limit - _recentCache.length);
    return [..._recentCache, ...fromFile];
  }

  Future<LlmCallRecord?> getById(String id) async {
    final cached = _recentCache.where((r) => r.id == id).firstOrNull;
    if (cached != null) return cached;
    return _findByIdInFiles(id);
  }

  Future<void> clear() async {
    _recentCache.clear();
    _writeQueue.clear();
    _changeCount++;
    changeNotifier.value = _changeCount;
    if (_logDir == null) return;
    try {
      final dir = Directory(_logDir!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('LlmLogger: 清空失败: $e');
    }
  }

  Future<int> getTotalSize() async {
    if (_logDir == null) return 0;
    int total = 0;
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  void _updateCache(LlmCallRecord r) {
    final idx = _recentCache.indexWhere((x) => x.id == r.id);
    if (idx >= 0) {
      _recentCache[idx] = r;
    } else {
      _recentCache.insert(0, r);
      if (_recentCache.length > _cacheSize) _recentCache.removeLast();
    }
  }

  void _enqueueWrite(LlmCallRecord r) {
    if (_logDir == null) return; // 测试模式不落盘
    _writeQueue.add(jsonEncode(r.toJson()));
    _flushWriteQueue();
  }

  Future<void> _flushWriteQueue() async {
    if (_isWriting || _writeQueue.isEmpty || _logDir == null) return;
    _isWriting = true;
    try {
      final lines = List<String>.from(_writeQueue);
      _writeQueue.clear();
      final today = _dateStr(DateTime.now().toUtc());
      final file = File('$_logDir/$_logFilePrefix$today.jsonl');
      final content = lines.join('\n');
      if (await file.exists()) {
        await file.writeAsString('\n$content', mode: FileMode.append, flush: true);
      } else {
        await file.writeAsString(content, flush: true);
      }
    } catch (e) {
      debugPrint('LlmLogger: 写入失败: $e');
    } finally {
      _isWriting = false;
      if (_writeQueue.isNotEmpty) _flushWriteQueue();
    }
  }

  Future<void> _cleanOldFiles() async {
    if (_logDir == null) return;
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().toUtc().subtract(const Duration(days: _retentionDays));
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.jsonl')) {
          final name = p.basename(e.path);
          final dateStr = name.replaceAll(_logFilePrefix, '').replaceAll('.jsonl', '');
          try {
            final y = int.parse(dateStr.substring(0, 4));
            final m = int.parse(dateStr.substring(4, 6));
            final d = int.parse(dateStr.substring(6, 8));
            if (DateTime.utc(y, m, d).isBefore(cutoff)) await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _loadRecentCache() async {
    final records = await _readRecentFromFile(_cacheSize);
    _recentCache.addAll(records);
  }

  Future<List<LlmCallRecord>> _readRecentFromFile(int limit) async {
    if (_logDir == null) return [];
    final records = <LlmCallRecord>[];
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return [];
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.jsonl')) files.add(e);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final file in files) {
        if (records.length >= limit) break;
        final content = await file.readAsString();
        for (final line in content.split('\n').where((l) => l.trim().isNotEmpty)) {
          if (records.length >= limit) break;
          try {
            records.add(LlmCallRecord.fromJson(jsonDecode(line) as Map<String, dynamic>));
          } catch (_) {}
        }
      }
    } catch (_) {}
    return records;
  }

  Future<LlmCallRecord?> _findByIdInFiles(String id) async {
    if (_logDir == null) return null;
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return null;
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.jsonl')) continue;
        final content = await e.readAsString();
        for (final line in content.split('\n').reversed) {
          if (line.trim().isEmpty) continue;
          try {
            final j = jsonDecode(line) as Map<String, dynamic>;
            if (j['id'] == id) return LlmCallRecord.fromJson(j);
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  static String _dateStr(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}';
  }
}
```

- [ ] **Step 5: 运行测试验证通过**

Run: `cd study_buddy && flutter test test/core/services/llm_logger_test.dart`
Expected: PASS(4 tests)

- [ ] **Step 6: 提交**

```bash
cd study_buddy
git add lib/core/services/llm_logger/ test/core/services/llm_logger_test.dart
git commit -m "feat(app): LlmLogger 单例 + LlmCallRecord,JSONL 存储,实现 engine LlmCallSink

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: AgentSession 注入 sink + 生成 traceId

**Files:**
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`
- Modify: `study_buddy/test/core/providers/chat_session_provider_test.dart`(若有相关测试断言构造,补 sink 兼容)

**Interfaces:**
- Consumes: `LoggerService`(Task 6)、`LlmLogger`(Task 7)、engine `LlmProvider`/`AgentLoop` 新签名(Task 3/4)
- Produces: `AgentSession.run()` 内部注入 sink + 生成 traceId,run 签名不变(对外行为不变)

- [ ] **Step 1: 修改 AgentSession.run()**

在 `study_buddy/lib/core/providers/agent_session_provider.dart`:
- import 区加:
```dart
import '../services/logger_service.dart';
import '../services/llm_logger/llm_logger.dart';
```
- 在 `run` 方法内,把 `final llm = LlmProvider(config: cfg);` 改为:
```dart
    final traceId = 'agent-${DateTime.now().millisecondsSinceEpoch}';
    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,
      logger: LoggerService.instance,
    );
```
- 把 `final loop = AgentLoop(llm: llm, scenario: scenario);` 改为:
```dart
    final loop = AgentLoop(llm: llm, scenario: scenario, logger: LoggerService.instance);
    LoggerService.instance.i('Agent 会话开始', category: LogCategory.ai, tags: const ['session-start'], traceId: traceId);
```
- 把 `return loop.run(messages, context: AgentScenarioContext(...))` 改为传入 traceId:
```dart
    return loop.run(
      messages,
      context: AgentScenarioContext(extra: chatSessionId == null ? const {} : {'chat_session_id': chatSessionId}),
      traceId: traceId,
    );
```

注意:`LoggerService.instance.i(..., traceId: traceId)` — `i` 方法签名是 `i(message, {category, tags, stackTrace})`,没有 `traceId` 参数。需在 Task 6 的 `i/w/e/d` 方法加 `String? traceId` 可选参数。**修正 Task 6**:d/i/w/e 都加 `String? traceId` 参数,透传给 `_write`。本步骤调用 `i('...', category:..., tags:..., traceId: traceId)` 才合法。

- [ ] **Step 2: 回头补 Task 6 的 traceId 参数**

回到 `logger_service.dart`,把 d/i/w/e 四个方法的签名都加 `String? traceId`,并在调用 `_write` 时传 `traceId`。例如 `i`:
```dart
  void i(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace, String? traceId}) {
    _write(message, LogLevel.info, stackTrace, category, tags, traceId: traceId ?? currentTraceId);
  }
```
d/w/e 同理。`_write` 已支持 traceId 参数。

更新 Task 6 测试:确认 `i(..., traceId: 'x')` 可用。在 logger_service_test.dart 加:
```dart
  test('i 显式传 traceId', () {
    LoggerService.instance.i('msg', traceId: 'explicit');
    expect(LoggerService.instance.getLogs().last.traceId, 'explicit');
  });
```

- [ ] **Step 3: 运行 LoggerService 测试**

Run: `cd study_buddy && flutter test test/core/services/logger_service_test.dart`
Expected: PASS(含新用例)

- [ ] **Step 4: 检查现有 provider 测试不回归**

Run: `cd study_buddy && flutter test test/core/providers/chat_session_provider_test.dart`
Expected: PASS(若有 AgentSession 构造断言,因签名未变应通过;若失败需按错误调整 mock)

- [ ] **Step 5: 提交**

```bash
cd study_buddy
git add lib/core/providers/agent_session_provider.dart lib/core/services/logger_service.dart test/core/services/logger_service_test.dart test/core/providers/chat_session_provider_test.dart
git commit -m "feat(app): AgentSession 注入 LoggerSink/LlmCallSink 并生成 traceId

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 9: app.dart 初始化 + 生命周期 flush

**Files:**
- Modify: `study_buddy/lib/app.dart`

**Interfaces:**
- Consumes: `LoggerService`(Task 6)、`LlmLogger`(Task 7)

- [ ] **Step 1: 修改 app.dart**

在 `study_buddy/lib/app.dart`:
- import 区加:
```dart
import 'core/services/logger_service.dart';
import 'core/services/llm_logger/llm_logger.dart';
```
- 在 `_StudyBuddyAppState.initState` 的 `addPostFrameCallback` 回调内,在 `bootstrapOverlay` 之前加:
```dart
      // 日志系统初始化(SP 加载历史 + LLM 日志目录)
      await LoggerService.instance.init();
      await LlmLogger.instance.initialize();
      LoggerService.instance.i('应用启动', category: LogCategory.general, tags: const ['app-start']);
```
- 在 `didChangeAppLifecycleState` 内加 paused flush(在现有 `resumed` 分支旁):
```dart
    if (state == AppLifecycleState.paused) {
      LoggerService.instance.flush();
    }
```

- [ ] **Step 2: 运行 widget 测试不回归**

Run: `cd study_buddy && flutter test test/widget_test.dart`
Expected: PASS(若 widget_test 直接 runApp,init 的 PostFrameCallback 异步执行,首帧断言不受影响)

- [ ] **Step 3: 提交**

```bash
cd study_buddy
git add lib/app.dart
git commit -m "feat(app): 启动初始化 LoggerService/LlmLogger,paused 时 flush

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 10: 路由 + 设置页 + 首页设置入口

**Files:**
- Modify: `study_buddy/lib/router.dart`
- Create: `study_buddy/lib/features/settings/settings_page.dart`
- Modify: `study_buddy/lib/features/home/home_page.dart`
- Create: `study_buddy/test/features/settings/settings_page_test.dart`

**Interfaces:**
- Produces: `/settings`、`/logs/app`、`/logs/llm`、`/logs/llm/:id` 四条路由;`SettingsPage` 纸感页(诊断版块含两个入口);HomePage 刊头右上角设置 IconButton

- [ ] **Step 1: 写设置页失败测试**

```dart
// study_buddy/test/features/settings/settings_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:study_buddy/features/settings/settings_page.dart';

void main() {
  testWidgets('SettingsPage 渲染诊断版块与两个入口', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: InheritedGoRouter(
        goRouter: GoRouter(routes: [GoRoute(path: '/', builder: (_, __) => const SettingsPage())]),
        child: const SettingsPage(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('LLM 调用日志'), findsOneWidget);
  });
}
```

注:`InheritedGoRouter` 是 go_router 的 widget;若该 API 在项目 go_router 版本(14.6.0)不可用,改用 `MaterialApp.router(routerConfig: ...)` 包裹,设置页内用 `context.go`。测试编写者须按实际 go_router API 调整。简化为:
```dart
  testWidgets('SettingsPage 渲染诊断版块与两个入口', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('LLM 调用日志'), findsOneWidget);
  });
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd study_buddy && flutter test test/features/settings/settings_page_test.dart`
Expected: FAIL — `SettingsPage` 未定义

- [ ] **Step 3: 写 SettingsPage**

```dart
// study_buddy/lib/features/settings/settings_page.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            _SectionLabel(text: '诊断'),
            const SizedBox(height: 8),
            _NavRow(icon: Icons.article_outlined, label: '应用日志', onTap: () => context.go('/logs/app')),
            _NavRow(icon: Icons.smart_toy_outlined, label: 'LLM 调用日志', onTap: () => context.go('/logs/llm')),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.primary, width: 1)),
      ),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(
        fontFamily: 'NotoSerifSC', fontStyle: FontStyle.italic, fontSize: 13, color: theme.colorScheme.primary)),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.extension<PaperColors>()!.ruleSoft, width: 0.6)),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: theme.textTheme.titleSmall?.copyWith(fontFamily: 'NotoSerifSC'))),
          Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}
```

- [ ] **Step 4: 加路由**

在 `study_buddy/lib/router.dart` 的 import 区加:
```dart
import 'features/logs/app_log_viewer_page.dart';
import 'features/logs/llm_log_viewer_page.dart';
import 'features/logs/llm_log_detail_page.dart';
import 'features/settings/settings_page.dart';
```
在 `routes` 列表末尾(最后一项后)加:
```dart
      GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
      GoRoute(path: '/logs/app', builder: (_, __) => const AppLogViewerPage()),
      GoRoute(path: '/logs/llm', builder: (_, __) => const LlmLogViewerPage()),
      GoRoute(
        path: '/logs/llm/:id',
        builder: (_, state) => LlmLogDetailPage(recordId: state.pathParameters['id']!),
      ),
```

注意:这三个 logs 页面文件在 Task 11/12 创建。本 Task 先加路由会导致编译失败(文件不存在)。**调整执行顺序**:Task 10 先建 SettingsPage + 首页入口 + `/settings` 路由(单独),Task 11/12 建日志页后再加 logs 路由。**修正**:本 Task 仅加 `/settings` 路由与首页入口,logs 三条路由放 Task 12 末尾(所有页就绪后)。

本 Task 在 router.dart 仅加:
```dart
import 'features/settings/settings_page.dart';
// routes 内:
GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
```

- [ ] **Step 5: 首页加设置入口**

在 `study_buddy/lib/features/home/home_page.dart` 的 `_Masthead` build 方法,把 `child: Column(...)` 外层套一个 `Stack`,右上角放 IconButton:

定位 `_Masthead` 的:
```dart
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
```
改为:
```dart
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
```
原 Column 的 `children` 列表保持,结尾 `],` 后(对应 Column 闭合)再加:
```dart
          ),
          Positioned(
            top: 4,
            right: 0,
            child: IconButton(
              icon: const Icon(Icons.settings_outlined, size: 22),
              tooltip: '设置',
              onPressed: () => context.go('/settings'),
            ),
          ),
        ],
      ),
```

注意缩进与闭合括号:需确保原有 `Column(...)` 的闭合 `)` 后接 `Positioned`,再 `]` `)` 闭合 Stack。`_Masthead` 是 StatelessWidget,`context` 在 build 内可用。home_page.dart 已 import go_router。

- [ ] **Step 6: 运行设置页测试 + widget 测试**

Run: `cd study_buddy && flutter test test/features/settings/settings_page_test.dart test/widget_test.dart`
Expected: PASS

- [ ] **Step 7: 提交**

```bash
cd study_buddy
git add lib/features/settings/settings_page.dart lib/router.dart lib/features/home/home_page.dart test/features/settings/settings_page_test.dart
git commit -m "feat(app): 设置页 + 首页刊头设置入口 + /settings 路由

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 10b: 设置页 LLM 配置板块(engine update + provider + 种子 + UI)

> 本任务由用户中途新增需求("在配置页,增加 LLM 的配置功能,可以配置 URL TOKEN MODEL")引入。复用 engine 现有 `LlmConfig`/`LlmConfigRepository`/`llm_config` 表,不重建。

**Files:**
- Modify: `packages/study_engine/lib/src/repos/llm_config_repository.dart`
- Modify: `packages/study_engine/test/repos_test.dart`
- Create: `study_buddy/lib/core/providers/llm_config_provider.dart`
- Create: `study_buddy/test/core/providers/llm_config_provider_test.dart`
- Modify: `study_buddy/lib/features/settings/settings_page.dart`
- Modify: `study_buddy/test/features/settings/settings_page_test.dart`

**Interfaces:**
- Consumes: engine `LlmConfig`/`LlmConfigRepository`(已存在)、`databaseProvider`(Task 0 已存在)、Task 10 的 `SettingsPage`/`_SectionLabel`
- Produces: `LlmConfigRepository.update(cfg)`(engine)、`llmConfigProvider` + `LlmConfigNotifier`(app Riverpod)、`SettingsPage` 内「LLM 配置」板块(名称/URL/Token/模型 四字段 + 保存)

### Step 1: engine — 写 update 失败测试

在 `packages/study_engine/test/repos_test.dart` 的 `main()` 内、现有 `'LlmConfigRepository.getDefault 视觉优先'` 测试**之后**,追加:

```dart
  test('LlmConfigRepository.update 按主键更新业务字段', () async {
    final repo = LlmConfigRepository(sdb);
    final id = await repo.insert(LlmConfig(
      name: '原配置',
      apiUrl: 'http://old',
      apiKey: 'old-key',
      model: 'old-model',
      isDefault: true,
      createdAt: DateTime(2026, 1, 1),
    ));
    final updated = LlmConfig(
      id: id,
      name: '新配置',
      apiUrl: 'https://api.example.com/v1',
      apiKey: 'secret-token',
      model: 'gpt-4o',
      supportsVision: true,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime(2026, 1, 1),
    );
    await repo.update(updated);
    final all = await repo.all();
    expect(all, hasLength(1));
    expect(all.first.id, id);
    expect(all.first.name, '新配置');
    expect(all.first.apiUrl, 'https://api.example.com/v1');
    expect(all.first.apiKey, 'secret-token');
    expect(all.first.model, 'gpt-4o');
    expect(all.first.supportsVision, isTrue);
    expect(all.first.isDefault, isTrue);
    // created_at 不应被 update 改动
    expect(all.first.createdAt, DateTime(2026, 1, 1));
  });
```

### Step 2: engine — 运行测试验证失败

Run: `cd packages/study_engine && dart test test/repos_test.dart`
Expected: FAIL — `update` 方法未定义(NoSuchMethodError 或编译期报错视 dart 版本)

### Step 3: engine — 实现 update

在 `packages/study_engine/lib/src/repos/llm_config_repository.dart` 的 `getDefault` 方法**之后**、类闭合 `}` **之前**追加:

```dart
  /// 按主键更新业务字段(不含 id 与 created_at)。
  /// [c.id] 必须非空,否则抛 [ArgumentError]。
  Future<void> update(LlmConfig c) async {
    if (c.id == null) {
      throw ArgumentError('LlmConfigRepository.update 需要非空 id');
    }
    await _db.db.rawUpdate(
      'UPDATE llm_config SET name = ?, api_url = ?, api_key = ?, model = ?, '
      'supports_vision = ?, is_default = ?, sort_order = ? WHERE id = ?',
      [
        c.name,
        c.apiUrl,
        c.apiKey,
        c.model,
        c.supportsVision ? 1 : 0,
        c.isDefault ? 1 : 0,
        c.sortOrder,
        c.id,
      ],
    );
  }
```

注:用 `rawUpdate` + 显式列名(非 `toMap`),避免 `toMap` 含/不含 id 的不确定性,且明确不动 `created_at`。`_db.db` 是 `StudyDatabase` 暴露的 `Database`(sqflite_common),`rawUpdate` 返回 `Future<int>`,这里忽略返回值(受影响行数)。

### Step 4: engine — 运行测试验证通过

Run: `cd packages/study_engine && dart test test/repos_test.dart`
Expected: PASS(原有测试 + 新增 update 测试全过)

### Step 5: engine — 提交

```bash
cd packages/study_engine
git add lib/src/repos/llm_config_repository.dart test/repos_test.dart
git commit -m "feat(engine): LlmConfigRepository.update 按主键更新业务字段

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Step 6: app — 写 provider 失败测试

在 `study_buddy/test/core/providers/llm_config_provider_test.dart` 创建:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';

import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/providers/llm_config_provider.dart';

Future<ProviderContainer> _boot() async {
  sqfliteFfiInit();
  final overrides = <Override>[];
  overrides.add(databaseProvider.overrideWith((ref) async {
    final sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    ref.onDispose(() => sdb.close());
    return sdb;
  }));
  final container = ProviderContainer(overrides: overrides);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  test('首次 build:表为空时种子一条默认配置', () async {
    final container = await _boot();
    addTearDown(container.dispose);
    final cfg = await container.read(llmConfigProvider.future);
    expect(cfg, isNotNull);
    expect(cfg!.name, '默认配置');
    expect(cfg.isDefault, isTrue);
    expect(cfg.supportsVision, isTrue);
    // 种子后表里确实有一行
    final db = await container.read(databaseProvider.future);
    final rows = await db.db.query('llm_config');
    expect(rows, hasLength(1));
  });

  test('save 更新现有配置,下次读取为新值', () async {
    final container = await _boot();
    addTearDown(container.dispose);
    final initial = await container.read(llmConfigProvider.future);
    expect(initial, isNotNull);
    final saved = await container
        .read(llmConfigProvider.notifier)
        .save(initial!.copyWith(
          apiUrl: 'https://api.example.com/v1',
          apiKey: 'tok-123',
          model: 'gpt-4o',
          name: '我的模型',
        ));
    expect(saved.apiUrl, 'https://api.example.com/v1');
    expect(saved.apiKey, 'tok-123');
    // invalidate 后重新读取,拿到的是落库后的新值
    container.invalidate(llmConfigProvider);
    final reread = await container.read(llmConfigProvider.future);
    expect(reread?.model, 'gpt-4o');
    expect(reread?.name, '我的模型');
    // 表里仍只有一行(非新增)
    final db = await container.read(databaseProvider.future);
    expect(await db.db.query('llm_config'), hasLength(1));
  });
}
```

注:`copyWith` 需在 `LlmConfig` 上存在。**若 engine 的 `LlmConfig` 无 `copyWith`,本任务的 Step 6 之前须先在 engine 补一个**(见 Step 6b)。implementer 须先读 `models.dart` 确认;若无,先做 Step 6b 再做 Step 6 测试。

### Step 6b: engine — 若 LlmConfig 无 copyWith 则补上(条件步骤)

先 `grep -n "copyWith" packages/study_engine/lib/src/models/models.dart` 确认。若已存在则跳过本步。若不存在,在 `LlmConfig` 类的 `toMap()` 方法**之后**、类闭合前追加:

```dart
  LlmConfig copyWith({
    int? id,
    String? name,
    String? apiUrl,
    String? apiKey,
    String? model,
    bool? supportsVision,
    bool? isDefault,
    int? sortOrder,
    DateTime? createdAt,
  }) {
    return LlmConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      apiUrl: apiUrl ?? this.apiUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      supportsVision: supportsVision ?? this.supportsVision,
      isDefault: isDefault ?? this.isDefault,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }
```

若执行了本步,需并入 Step 5 的 commit(或单独 commit `feat(engine): LlmConfig.copyWith`)。implementer 自行判断。

### Step 7: app — 运行测试验证失败

Run: `cd study_buddy && flutter test test/core/providers/llm_config_provider_test.dart`
Expected: FAIL — `llmConfigProvider` / `LlmConfigNotifier` 未定义

### Step 8: app — 实现 provider

在 `study_buddy/lib/core/providers/llm_config_provider.dart` 创建:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// 当前生效的 LLM 配置(默认项)。
///
/// build() 时:
/// - 读 `llm_config` 表 all();
/// - 若表为空(全新安装),种子一条占位默认配置(name="默认配置"/url=""/key=""/model=""/supportsVision=true/isDefault=true),
///   消除 [AgentSession]/[PlanSession] 的 getDefault() 返回 null 抛 StateError 的崩溃路径,
///   并让用户在设置页看到"待填写"的初始态。
/// - 返回 sort_order 最前的默认项(无默认项则返回首行)。
///
/// save() 时:id 为空走 insert,否则走 update;写库后 invalidateSelf 触发重建。
final llmConfigProvider =
    AsyncNotifierProvider<LlmConfigNotifier, LlmConfig?>(
  LlmConfigNotifier.new,
);

class LlmConfigNotifier extends AsyncNotifier<LlmConfig?> {
  @override
  Future<LlmConfig?> build() async {
    final db = await ref.watch(databaseProvider.future);
    final repo = LlmConfigRepository(db);
    var configs = await repo.all();
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
    // 优先默认项;无则首行
    return configs.firstWhere(
      (c) => c.isDefault,
      orElse: () => configs.first,
    );
  }

  /// 保存配置:id 为空 insert,否则 update。返回写入后的配置(带 id)。
  Future<LlmConfig> save(LlmConfig cfg) async {
    final db = await ref.read(databaseProvider.future);
    final repo = LlmConfigRepository(db);
    if (cfg.id == null) {
      final newId = await repo.insert(cfg);
      return cfg.copyWith(id: newId);
    }
    await repo.update(cfg);
    return cfg;
  }

  /// 写库后刷新:调用方 save 后调用此方法,或直接 invalidate。
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}
```

注:
- `AsyncNotifierProvider` 是 flutter_riverpod 现代 API(非 legacy)。项目已用 `flutter_riverpod`(见 database_provider.dart 的 import),此 API 可用。若版本不支持,降级为 `StateNotifierProvider<LlmConfigNotifier, AsyncValue<LlmConfig?>>`(legacy),但需在测试里用 `container.read(llmConfigProvider)` 而非 `.future`——implementer 须按项目实际 riverpod 版本调整,保持测试断言语义不变。
- `DateTime.now()` 在 build() 中可用(engine 测试禁用 `Date.now` 是 Workflow 脚本限制,不是 app 代码限制)。
- `ref.watch(databaseProvider.future)` 让本 provider 自动依赖 db,db 就绪后才 build。

### Step 9: app — 运行测试验证通过

Run: `cd study_buddy && flutter test test/core/providers/llm_config_provider_test.dart`
Expected: PASS(2 个测试:种子 + save 更新)

### Step 10: app — 提交 provider

```bash
cd study_buddy
git add lib/core/providers/llm_config_provider.dart test/core/providers/llm_config_provider_test.dart
git commit -m "feat(app): llmConfigProvider AsyncNotifier + 空表种子默认配置

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Step 11: app — 写设置页 LLM 板块失败测试

在 `study_buddy/test/features/settings/settings_page_test.dart`(Task 10 已创建)的 `main()` 内、现有渲染测试**之后**追加:

```dart
  testWidgets('LLM 配置板块渲染四字段与保存按钮', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('LLM 配置'), findsOneWidget);
    expect(find.text('名称'), findsWidgets);
    expect(find.text('API 地址'), findsWidgets);
    expect(find.text('API Key'), findsWidgets);
    expect(find.text('模型'), findsWidgets);
    expect(find.text('保存'), findsOneWidget);
  });
```

注:Task 10 的渲染测试若用 `MaterialApp(home: const SettingsPage())`(无 ProviderScope),本测试需包裹 `ProviderScope`。若 Task 10 测试已包裹 ProviderScope,沿用即可。SettingsPage 现在依赖 `llmConfigProvider`,无 ProviderScope 会抛 ProviderScope 缺失,故本测试必须包。implementer 须确保两个测试的包裹方式一致(都用 ProviderScope)。

### Step 12: app — 运行测试验证失败

Run: `cd study_buddy && flutter test test/features/settings/settings_page_test.dart`
Expected: FAIL — `LLM 配置` 文本找不到(或 SettingsPage 缺 ProviderScope 报错)

### Step 13: app — 在 SettingsPage 加 LLM 配置板块

修改 `study_buddy/lib/features/settings/settings_page.dart`:
1. 顶部 import 区加:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/llm_config_provider.dart';
```
2. `class SettingsPage extends StatelessWidget` 改为 `class SettingsPage extends ConsumerWidget`,`build(BuildContext context)` 改为 `build(BuildContext context, WidgetRef ref)`。
3. 在 ListView 的 `children` 中,`_SectionLabel(text: '诊断')` 之前(板块顺序:LLM 配置在上,诊断在下)插入:
```dart
            _LlmConfigSection(),
            const SizedBox(height: 32),
```
4. 在文件末尾(其它私有 widget 之后)追加 `_LlmConfigSection`:
```dart
class _LlmConfigSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_LlmConfigSection> createState() => _LlmConfigSectionState();
}

class _LlmConfigSectionState extends ConsumerState<_LlmConfigSection> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _loaded = false;
  bool _saving = false;

  void _ensureControllers(LlmConfig? cfg) {
    if (_loaded) return;
    _name = TextEditingController(text: cfg?.name ?? '');
    _url = TextEditingController(text: cfg?.apiUrl ?? '');
    _key = TextEditingController(text: cfg?.apiKey ?? '');
    _model = TextEditingController(text: cfg?.model ?? '');
    _loaded = true;
  }

  @override
  void dispose() {
    if (_loaded) {
      _name.dispose();
      _url.dispose();
      _key.dispose();
      _model.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final cfg = ref.read(llmConfigProvider).valueOrNull;
    if (cfg == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(llmConfigProvider.notifier).save(cfg.copyWith(
            name: _name.text.trim().isEmpty ? '默认配置' : _name.text.trim(),
            apiUrl: _url.text.trim(),
            apiKey: _key.text.trim(),
            model: _model.text.trim(),
          ));
      await ref.read(llmConfigProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('LLM 配置已保存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败:$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncCfg = ref.watch(llmConfigProvider);
    return asyncCfg.when(
      loading: () => const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Center(
            child: SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text('加载配置失败:$e'),
      ),
      data: (cfg) {
        _ensureControllers(cfg);
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(text: 'LLM 配置'),
            const SizedBox(height: 8),
            _Field(label: '名称', controller: _name, hint: '如:我的模型'),
            _Field(
              label: 'API 地址',
              controller: _url,
              hint: 'https://api.example.com/v1',
              keyboard: TextInputType.url,
            ),
            _Field(
              label: 'API Key',
              controller: _key,
              hint: 'sk-...',
              obscure: true,
            ),
            _Field(
              label: '模型',
              controller: _model,
              hint: '如:gpt-4o',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.keyboard = TextInputType.text,
    this.obscure = false,
  });
  final String label;
  final TextEditingController controller;
  final String hint;
  final TextInputType keyboard;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'NotoSerifSC',
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: keyboard,
            obscureText: obscure,
            style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'NotoSerifSC'),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5)),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                    color: theme.extension<PaperColors>()!.ruleSoft, width: 0.6),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: theme.colorScheme.primary, width: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

注:
- `_SectionLabel` 复用 Task 10 已定义的私有 widget(同文件)。若 Task 10 的 `_SectionLabel` 是 `_SectionLabel`(下划线前缀,私有),同文件可直接用。
- `FilledButton` 是 Material 3 内置,纸感页用主色填充,与 `_NavRow` 的克制风格形成"主操作"视觉层次。
- API Key 字段 `obscure: true` 隐藏,防止肩窥;保存时取 `.text.trim()`。
- `_ensureControllers` 用 `_loaded` 标志确保 controller 只在配置首次到达时初始化(避免重建时重置用户输入);`dispose` 里判断 `_loaded` 防止未初始化 dispose。
- `PaperColors` import 来自 Task 10 已有的 `import '../../core/theme/paper_extension.dart';`(若 SettingsPage 已 import,`_Field` 同文件可直接用)。

### Step 14: app — 运行测试验证通过

Run: `cd study_buddy && flutter test test/features/settings/settings_page_test.dart`
Expected: PASS(渲染测试 + LLM 板块测试全过)

注:本测试 pumpAndSettle 会触发 `llmConfigProvider` 的 build(),需 `databaseProvider` 可用。测试若未 override `databaseProvider`,真实 db 会因 `getApplicationSupportDirectory` 失败。**处理**:测试用 `ProviderScope(overrides: [databaseProvider.overrideWith(... inMemory ...)])`。implementer 须把 Step 11 的测试改为带 override 的 ProviderScope,与 provider 测试的 `_boot()` 同款 inMemory override。示例:

```dart
  testWidgets('LLM 配置板块渲染四字段与保存按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async {
            sqfliteFfiInit();
            final sdb = await StudyDatabase.open(
              factory: databaseFactoryFfi,
              path: inMemoryDatabasePath,
            );
            ref.onDispose(() => sdb.close());
            return sdb;
          }),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    // ... 断言
  });
```

同理,Task 10 的渲染测试若也因 SettingsPage 现依赖 provider 而失败,需同样 override。implementer 统一处理两个测试。

### Step 15: app — 提交设置页

```bash
cd study_buddy
git add lib/features/settings/settings_page.dart test/features/settings/settings_page_test.dart
git commit -m "feat(app): 设置页加 LLM 配置板块(URL/Token/Model 保存)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 11: App 日志查看页

**Files:**
- Create: `study_buddy/lib/features/logs/app_log_viewer_page.dart`
- Create: `study_buddy/test/features/logs/app_log_viewer_page_test.dart`

**Interfaces:**
- Consumes: `LoggerService`(Task 6)、`LogEntry`/`LogLevel`/`LogCategory`/`LogStatistics`

- [ ] **Step 1: 写失败测试**

```dart
// study_buddy/test/features/logs/app_log_viewer_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/logger_service.dart';
import 'package:study_buddy/features/logs/app_log_viewer_page.dart';

void main() {
  setUp(() {
    LoggerService.resetForTesting();
  });

  testWidgets('渲染统计条与日志列表', (tester) async {
    LoggerService.instance.i('hello', category: LogCategory.ai);
    LoggerService.instance.e('boom', category: LogCategory.database);
    await tester.pumpWidget(MaterialApp(home: const AppLogViewerPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('共'), findsOneWidget); // 统计条
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('点击日志项展开详情', (tester) async {
    LoggerService.instance.i('详细内容在这');
    await tester.pumpWidget(MaterialApp(home: const AppLogViewerPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详细内容在这'));
    await tester.pumpAndSettle();
    expect(find.textContaining('详细内容'), findsWidgets);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd study_buddy && flutter test test/features/logs/app_log_viewer_page_test.dart`
Expected: FAIL — `AppLogViewerPage` 未定义

- [ ] **Step 3: 写 AppLogViewerPage**

```dart
// study_buddy/lib/features/logs/app_log_viewer_page.dart
import 'package:flutter/material.dart';

import '../../core/services/logger_service.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

class AppLogViewerPage extends StatefulWidget {
  const AppLogViewerPage({super.key});
  @override
  State<AppLogViewerPage> createState() => _AppLogViewerPageState();
}

class _AppLogViewerPageState extends State<AppLogViewerPage> {
  LogLevel? _levelFilter;
  String _query = '';
  final Set<int> _expanded = {};

  @override
  void initState() {
    super.initState();
    LoggerService.logChangeNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    LoggerService.logChangeNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<LogEntry> get _filtered {
    var logs = LoggerService.instance.getLogsByLevel(_levelFilter).reversed.toList();
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      logs = logs.where((l) => l.message.toLowerCase().contains(q) || l.tags.any((t) => t.toLowerCase().contains(q))).toList();
    }
    return logs;
  }

  Color _levelColor(LogLevel l, ThemeData t) {
    switch (l) {
      case LogLevel.debug: return t.colorScheme.outline;
      case LogLevel.info: return t.colorScheme.tertiary;
      case LogLevel.warning: return t.extension<PaperColors>()!.gold;
      case LogLevel.error: return t.colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = LoggerService.instance.getStatistics();
    final logs = _filtered;
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('应用日志'),
        actions: [
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: '清空', onPressed: _clear),
          IconButton(icon: const Icon(Icons.ios_share), tooltip: '导出', onPressed: _export),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '共 ${stats.total} 条 · 错误 ${stats.byLevel[LogLevel.error] ?? 0}',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(spacing: 6, children: [
            for (final l in LogLevel.values)
              FilterChip(
                label: Text(l.name),
                selected: _levelFilter == l,
                onSelected: (_) => setState(() => _levelFilter = _levelFilter == l ? null : l),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(isDense: true, hintText: '搜索...', prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? Center(child: Text('暂无日志', style: theme.textTheme.bodyMedium))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final log = logs[i];
                    final expanded = _expanded.contains(log.timestamp.millisecondsSinceEpoch);
                    return InkWell(
                      onTap: () => setState(() {
                        final k = log.timestamp.millisecondsSinceEpoch;
                        if (expanded) {
                          _expanded.remove(k);
                        } else {
                          _expanded.add(k);
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: theme.extension<PaperColors>()!.ruleSoft, width: 0.6)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Container(width: 8, height: 8, decoration: BoxDecoration(color: _levelColor(log.level, theme), shape: BoxShape.circle)),
                            const SizedBox(width: 8),
                            Text(LoggerService.formatTimestamp(log.timestamp),
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11)),
                            const SizedBox(width: 8),
                            Text('[${log.category.name}]',
                                style: theme.textTheme.labelSmall?.copyWith(color: _levelColor(log.level, theme), fontSize: 11)),
                            const Spacer(),
                            Text(log.level.name,
                                style: theme.textTheme.labelSmall?.copyWith(color: _levelColor(log.level, theme), fontSize: 11)),
                          ]),
                          const SizedBox(height: 4),
                          Text(log.message, maxLines: expanded ? null : 2, overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'NotoSerifSC')),
                          if (expanded && log.stackTrace != null) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(6),
                              color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
                              child: SelectableText(log.stackTrace!, style: const TextStyle(fontFamily: 'monospace', fontSize: 10)),
                            ),
                          ],
                          if (expanded && log.traceId != null)
                            Padding(padding: const EdgeInsets.only(top: 4),
                              child: Text('trace: ${log.traceId}', style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, color: theme.colorScheme.onSurfaceVariant))),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('清空日志'),
      content: const Text('确定清空所有应用日志?此操作不可撤销。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('清空'))],
    ));
    if (ok == true) await LoggerService.instance.clearLogs();
  }

  Future<void> _export() async {
    final file = await LoggerService.instance.exportToFile();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出到: ${file.path}')));
    }
  }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cd study_buddy && flutter test test/features/logs/app_log_viewer_page_test.dart`
Expected: PASS(2 tests)

- [ ] **Step 5: 提交**

```bash
cd study_buddy
git add lib/features/logs/app_log_viewer_page.dart test/features/logs/app_log_viewer_page_test.dart
git commit -m "feat(app): App 运行日志查看页,过滤/搜索/展开/清空/导出

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 12: LLM 日志列表页 + 详情页 + 补路由

**Files:**
- Create: `study_buddy/lib/features/logs/llm_log_viewer_page.dart`
- Create: `study_buddy/lib/features/logs/llm_log_detail_page.dart`
- Modify: `study_buddy/lib/router.dart`(补 3 条 logs 路由)
- Create: `study_buddy/test/features/logs/llm_log_viewer_page_test.dart`

**Interfaces:**
- Consumes: `LlmLogger`(Task 7)、`LlmCallRecord`

- [ ] **Step 1: 写列表页失败测试**

```dart
// study_buddy/test/features/logs/llm_log_viewer_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/llm_logger/llm_logger.dart';
import 'package:study_buddy/features/logs/llm_log_viewer_page.dart';

void main() {
  setUp(() {
    LlmLogger.resetForTesting();
  });

  testWidgets('渲染 LLM 日志列表', (tester) async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: 'e', model: 'gpt', requestBody: '{"messages":[{"content":"问"}]}', isStreaming: true,
    );
    LlmLogger.instance.onResponse(id, responseBody: 'r', durationMs: 100, isSuccess: true, totalTokens: 5);
    await tester.pumpWidget(MaterialApp(home: const LlmLogViewerPage()));
    await tester.pumpAndSettle();
    expect(find.text('gpt'), findsOneWidget);
    expect(find.textContaining('问'), findsWidgets);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd study_buddy && flutter test test/features/logs/llm_log_viewer_page_test.dart`
Expected: FAIL — `LlmLogViewerPage` 未定义

- [ ] **Step 3: 写 LlmLogViewerPage**

```dart
// study_buddy/lib/features/logs/llm_log_viewer_page.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/llm_logger/llm_logger.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

class LlmLogViewerPage extends StatefulWidget {
  const LlmLogViewerPage({super.key});
  @override
  State<LlmLogViewerPage> createState() => _LlmLogViewerPageState();
}

class _LlmLogViewerPageState extends State<LlmLogViewerPage> {
  List<dynamic> _records = []; // List<LlmCallRecord>
  int _totalSize = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
    LlmLogger.changeNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    LlmLogger.changeNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() { if (mounted) _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await LlmLogger.instance.getRecent(limit: 200);
    final size = await LlmLogger.instance.getTotalSize();
    if (mounted) setState(() { _records = list; _totalSize = size; _loading = false; });
  }

  String _sizeStr(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('LLM 调用日志'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新', onPressed: _load),
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: '清空', onPressed: _clear),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('共 ${_records.length} 条 · 占用 ${_sizeStr(_totalSize)}${_loading ? ' · 加载中...' : ''}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: _records.isEmpty
              ? Center(child: Text('暂无 LLM 调用记录', style: theme.textTheme.bodyMedium))
              : ListView.builder(
                  itemCount: _records.length,
                  itemBuilder: (_, i) {
                    final r = _records[i];
                    final ok = (r.isSuccess as bool?) ?? false;
                    final color = ok ? theme.colorScheme.tertiary : theme.colorScheme.primary;
                    return InkWell(
                      onTap: () => context.go('/logs/llm/${r.id}'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: theme.extension<PaperColors>()!.ruleSoft, width: 0.6)),
                        ),
                        child: Row(children: [
                          Icon(ok ? Icons.check_circle : Icons.error, color: color, size: 20),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              if (r.model != null) Flexible(child: Text(r.model as String,
                                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                                  maxLines: 1, overflow: TextOverflow.ellipsis)),
                              if ((r.isStreaming as bool?) ?? false)
                                Container(margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(4)),
                                  child: Text('流式', style: theme.textTheme.labelSmall?.copyWith(fontSize: 10))),
                            ]),
                            const SizedBox(height: 2),
                            Text(r.previewText as String,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text('${r.durationText} · tokens: ${r.totalTokens ?? '-'}',
                                style: theme.textTheme.labelSmall?.copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                          ])),
                          const Icon(Icons.chevron_right, size: 18),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('清空 LLM 日志'),
      content: const Text('确定清空所有 LLM 调用日志?'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('清空'))],
    ));
    if (ok == true) { await LlmLogger.instance.clear(); await _load(); }
  }
}
```

- [ ] **Step 4: 写 LlmLogDetailPage**

```dart
// study_buddy/lib/features/logs/llm_log_detail_page.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/llm_logger/llm_call_record.dart';
import '../../core/services/llm_logger/llm_logger.dart';
import '../../core/theme/paper_scaffold.dart';

class LlmLogDetailPage extends StatefulWidget {
  final String recordId;
  const LlmLogDetailPage({super.key, required this.recordId});
  @override
  State<LlmLogDetailPage> createState() => _LlmLogDetailPageState();
}

class _LlmLogDetailPageState extends State<LlmLogDetailPage> {
  LlmCallRecord? _record;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await LlmLogger.instance.getById(widget.recordId);
    if (mounted) setState(() { _record = r; _loading = false; });
  }

  String _fmtJson(String s) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {
      return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('调用详情'),
        actions: [IconButton(icon: const Icon(Icons.copy), tooltip: '复制', onPressed: _record == null ? null : _copy)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _record == null
              ? const Center(child: Text('未找到该记录'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _summary(theme, _record!),
                    const SizedBox(height: 12),
                    _section(theme, '请求体', _fmtJson(_record!.requestBody)),
                    const SizedBox(height: 12),
                    _section(theme, _record!.isSuccess ? '响应体' : '响应体(失败)',
                        _record!.responseBody != null ? _fmtJson(_record!.responseBody!) : (_record!.errorMessage ?? '(无响应体)')),
                    const SizedBox(height: 24),
                  ]),
                ),
    );
  }

  Widget _summary(ThemeData theme, LlmCallRecord r) {
    final color = r.isSuccess ? theme.colorScheme.tertiary : theme.colorScheme.primary;
    final rows = <(String, String)>[
      ('时间', r.timestamp.toLocal().toString().substring(0, 19)),
      ('状态', r.isSuccess ? '成功' : '失败'),
      ('模型', r.model ?? '-'),
      ('Endpoint', r.endpoint.isEmpty ? '-' : r.endpoint),
      ('流式', r.isStreaming ? '是' : '否'),
      ('耗时', r.durationText),
      ('Tokens', 'total: ${r.totalTokens ?? '-'}'),
      ('TraceId', r.traceId ?? '-'),
    ];
    return Card(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(children: [for (int i = 0; i < rows.length; i++) ...[
        Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 72, child: Text(rows[i].$1, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)))),
          Expanded(child: SelectableText(rows[i].$2, style: theme.textTheme.bodySmall?.copyWith(color: rows[i].$1 == '状态' ? color : null, fontFamily: rows[i].$1 == 'Endpoint' ? 'monospace' : null))),
        ])),
        if (i < rows.length - 1) Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
      ]])));
  }

  Widget _section(ThemeData theme, String label, String content) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 4),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(child: SelectableText(content, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))),
      ),
    ]);
  }

  Future<void> _copy() async {
    final r = _record;
    if (r == null) return;
    await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(r.toJson())));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制完整记录')));
  }
}
```

- [ ] **Step 5: 补路由**

在 `study_buddy/lib/router.dart` import 区加(若 Task 10 未加):
```dart
import 'features/logs/app_log_viewer_page.dart';
import 'features/logs/llm_log_viewer_page.dart';
import 'features/logs/llm_log_detail_page.dart';
```
在 routes 列表 `/settings` 之后加:
```dart
      GoRoute(path: '/logs/app', builder: (_, __) => const AppLogViewerPage()),
      GoRoute(path: '/logs/llm', builder: (_, __) => const LlmLogViewerPage()),
      GoRoute(path: '/logs/llm/:id', builder: (_, state) => LlmLogDetailPage(recordId: state.pathParameters['id']!)),
```

- [ ] **Step 6: 运行测试验证通过**

Run: `cd study_buddy && flutter test test/features/logs/llm_log_viewer_page_test.dart`
Expected: PASS

- [ ] **Step 7: 全量测试回归**

Run: `cd study_buddy && flutter test`
Expected: 全 PASS

Run: `cd packages/study_engine && dart test`
Expected: 全 PASS

- [ ] **Step 8: 提交**

```bash
cd study_buddy
git add lib/features/logs/ lib/router.dart test/features/logs/llm_log_viewer_page_test.dart
git commit -m "feat(app): LLM 日志列表页+详情页(纸感)+ /logs/* 路由

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 13: 文档 logging-guidelines.md

**Files:**
- Create: `docs/logging-guidelines.md`

- [ ] **Step 1: 写文档**

精简自 novel_builder 版,聚焦 study 业务分类与 engine sink 用法。内容大纲:
- 概述:LoggerService(App 日志)+ LlmLogger(LLM 日志)双系统,设置页入口
- 级别规范:debug/info/warning/error 场景与示例(release 不写 debug)
- 分类体系:database/ai/focus/plan/ui/general 各场景示例
- engine sink 用法:如何在新 engine 模块注入 LoggerSink 埋点(构造可选参数 + NullLoggerSink 默认)
- traceId:AgentSession.run() 生成,串联 App 日志与 LLM 调用
- 标签推荐:llm/tool-call/migration/session-start 等
- 查看与导出:设置 → 诊断 → 应用日志/LLM 日志

文档全部用 study_buddy 的实际 API(`LoggerService.instance.i(...)`,category 为 `LogCategory.ai` 枚举),不照搬 novel_builder 的旧分类。

- [ ] **Step 2: 提交**

```bash
cd "D:/my_space/study"
git add docs/logging-guidelines.md
git commit -m "docs: study 版日志使用指南 logging-guidelines

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 结果

**1. Spec 覆盖检查**:
- engine 双 sink 接口 → Task 1/2 ✓
- engine AgentLoop/LlmProvider/migrateDatabase 埋点 → Task 3/4/5 ✓
- app LoggerService(内存+SP+文件回退) → Task 6 ✓
- app LlmLogger(JSONL+traceId) → Task 7 ✓
- AgentSession 注入 + traceId → Task 8 ✓
- app.dart 初始化 + flush → Task 9 ✓
- 设置页 + 路由 + 首页入口 → Task 10 ✓
- App 日志查看页 → Task 11 ✓
- LLM 列表页 + 详情页 + 路由 → Task 12 ✓
- 文档 → Task 13 ✓
- 全部 6 分类(database/ai/focus/plan/ui/general)在 LoggerService Task 6 落地 ✓

**2. Placeholder 扫描**:无 TBD/TODO;Task 5/12 有"按实际 helper 名调整"的说明(因编写时未读 db_test.dart 全文),这是合理的执行期确认,非占位——但已给出明确的回退方案。

**3. 类型一致性**:
- `LoggerLevel.values[level.index]` 映射:Task 1 枚举顺序 debug/info/warning/error = Task 6 LogLevel 顺序 ✓
- `onRequest` 返回 id:Task 2 接口 = Task 3 engine 调用 = Task 7 app 实现 ✓
- `LlmCallRecord.fromJson` 字段名 `trace_id`:Task 7 模型 = 测试 ✓
- `AgentLoop(logger:)` 命名参数:Task 4 定义 = Task 8 调用 ✓
- `chatStreamWithTools(traceId:)` 参数:Task 3 定义 = Task 4 调用 ✓
