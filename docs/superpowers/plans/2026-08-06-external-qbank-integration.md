# 外部题库集成（study.keyky.cn 客户端层）实现 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 study_buddy Flutter APP 中集成 study.keyky.cn 题库网站，提供 WebView 容器 + 浮窗 AI 助手（MVP 范围）。

**Architecture:** UI 层新增 `features/external_qbank/` 目录承载 WebView 页面、浮窗按钮、AI 抽屉；Application 层新增 AgentSessionProvider（APP 层 agent 调用入口）+ WebViewScreenshotService；Engine 层零改动，复用 StudyScenario + save_topic/query_topics + vision content。图片走 LLM 原生 vision 处理，纯内存持有不落盘。

**Tech Stack:** Flutter 3.35.7 / Dart 3.9.2 / Riverpod 3 / go_router 14 / flutter_inappwebview 6.x / study_engine（已有）。

## Global Constraints

来自 spec，**所有任务必须遵守**：

1. **绝对禁止在代码、配置、注释、commit message、git 历史中出现 study.keyky.cn 的鉴权凭据**（token / cookie / Authorization 字面值）。
2. **engine 包零改动**：本 plan 不修改 `packages/study_engine/` 任何文件；engine 包的单测保持原样运行通过即可。
3. **截图纯内存**：takeScreenshot 返回的 `Uint8List` 只在内存中持有；不写盘、不入库、不缓存。会话结束即释放。
4. **登录由 WebView 内 study.keyky.cn 自处理**（扫码 / 手机号 / 微信 等），APP 不读 cookie、不构造 Authorization。
5. **不调 study.keyky.cn 任何 API**（即使已破译的 `/api/q_bank` 等接口）。
6. **AI 输出只落本地 topic 表**，不写回网站。
7. Flutter SDK: `^3.9.2`；minSdk 由 Flutter 默认决定（当前 ≥21）；AGP 8.9.1；iOS 12.0+。
8. 全部 commit 走 `git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "..."` 形式。
9. 全部 Dart 代码遵循现有 `analysis_options.yaml` lint（避免引入新警告）。

---

## 文件结构

### 新增文件

```
study_buddy/lib/core/providers/
  agent_session_provider.dart          # APP 层 agent 入口：构造 StudyScenario + AgentLoop，对外暴露 run() Stream
  webview_screenshot_provider.dart     # 截图服务：takeScreenshot + base64 编码

study_buddy/lib/features/external_qbank/
  external_qbank_page.dart             # WebView 容器页 + 浮窗按钮 + 抽屉触发
  qbank_web_view.dart                  # InAppWebView 封装（含 controller 暴露）
  floating_ai_button.dart              # 浮窗 FAB（Stack 定位，右下角）
  ai_panel_sheet.dart                  # 底部抽屉（截图预览 + agent 流式对话）
```

### 修改文件

```
study_buddy/pubspec.yaml                          # + flutter_inappwebview: ^6.1.5
study_buddy/lib/router.dart                       # 新路由 /external-qbank
study_buddy/lib/features/home/home_page.dart      # 增加「进入题库」入口按钮
study_buddy/test/widget_test.dart                 # 更新占位测试（HomePage 已变更）
```

### 不变文件

```
packages/study_engine/**                          # engine 层零改动
study_buddy/lib/app.dart                          # 不变
study_buddy/lib/main.dart                         # 不变
study_buddy/lib/core/providers/database_provider.dart  # 不变
```

---

## Task 1: 引入 flutter_inappwebview 依赖

**Files:**
- Modify: `study_buddy/pubspec.yaml:26-39`

**目的：** 引入 WebView 组件，为后续 QbankWebView widget 做准备。

**约束：** 不引入 path_provider（截图纯内存）；不引入其它冗余依赖。

- [ ] **Step 1: 编辑 pubspec.yaml**

在 `dependencies:` 块（位于 `cupertino_icons` 之后、`flutter_riverpod` 之前或紧邻 `path_provider` 后均可）添加：

```yaml
  flutter_inappwebview: ^6.1.5
```

推荐加在 `sqflite_common_ffi: ^2.3.4` 后面这一行之后：

```yaml
  sqflite_common_ffi: ^2.3.4
  flutter_inappwebview: ^6.1.5
  path_provider: ^2.1.5
```

- [ ] **Step 2: 拉依赖**

Run:
```bash
cd study_buddy && flutter pub get
```

Expected: `Got dependencies!` 无报错，终端输出 `+ flutter_inappwebview: ^6.1.5`。

- [ ] **Step 3: 验证 analyze 仍全绿**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`（旧代码不变，应保持原状）。

- [ ] **Step 4: 提交**

```bash
git add study_buddy/pubspec.yaml study_buddy/pubspec.lock
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(deps): 引入 flutter_inappwebview 6.x（WebView 容器）"
```

---

## Task 2: 新增 AgentSessionProvider（APP 层 agent 入口）

**Files:**
- Create: `study_buddy/lib/core/providers/agent_session_provider.dart`

**目的：** APP 层封装 AgentLoop 调用入口：注入 LLM 配置 + 三个 Repository，构造 StudyScenario + AgentLoop，对外暴露 `run()` 静态方法返回 `Stream<AgentEvent>`。**这一步是 plan 里替换 spec 中「复用 agent_session_provider」的修正项**（spec 错误地假设该 provider 已存在；实际不存在，需新建）。

**Interfaces:**

Produces（后续 Task 5/6 依赖此接口）:
- `Future<Stream<AgentEvent>> runAgent(List<ChatMessage> messages, {required Ref ref})` — 构造 LLM Provider + StudyScenario + AgentLoop，返回事件流。
- `Stream<AgentEvent> Function()` 调用形式：调用方 `ref.read(agentSessionProvider).run(messages)`。

**Consumes:**
- `databaseProvider`（已有 `FutureProvider<StudyDatabase>`）
- `LlmConfigRepository.getDefault(vision: true)`
- `SubjectRepository`、`TopicRepository`、`AgentMemoryRepository`
- `LlmProvider`、`AgentLoop`、`StudyScenario`、`ChatMessage`

- [ ] **Step 1: 写新文件**

`study_buddy/lib/core/providers/agent_session_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// APP 层 agent 调用入口：构造 StudyScenario + AgentLoop 并返回事件流。
///
/// 该 provider 故意不在内部持有 LlmProvider 实例（每次 run() 重新构造，
/// 因为 LlmConfig 可能被用户在线程外修改）。LLM 配置取自 `llm_config`
/// 表的默认 vision 配置；若不存在默认项，run() 会抛错并由 UI 层捕获。
class AgentSession {
  AgentSession(this._ref);

  final Ref _ref;

  /// 运行 agent 循环。返回 [AgentEvent] 事件流（实时增量）。
  ///
  /// 每次调用都会重新从 DB 读取 LLM 配置、构造新的 StudyScenario 与 AgentLoop。
  /// 调用方负责监听流并在 done/error 时释放资源。
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    final db = await _ref.read(databaseProvider.future);
    final llmConfigs = LlmConfigRepository(db);
    final cfg = await llmConfigs.getDefault(vision: true);
    if (cfg == null) {
      throw StateError(
        '未配置支持视觉的默认 LLM。请先在 llm_config 表中添加 '
        'is_default=1 且 supports_vision=1 的记录。',
      );
    }
    final subjects = SubjectRepository(db);
    final topics = TopicRepository(db);
    final memories = AgentMemoryRepository(db);

    final llm = LlmProvider(config: cfg);
    final scenario = StudyScenario(
      subjects: subjects,
      topics: topics,
      memories: memories,
    );
    final loop = AgentLoop(llm: llm, scenario: scenario);
    return loop.run(messages);
  }
}

final agentSessionProvider = Provider<AgentSession>((ref) {
  return AgentSession(ref);
});
```

> **说明：** 之所以每次 `run()` 重新构造 Provider，是因为：
> 1. LLM 配置可能由用户在「设置」页动态修改，需要拿最新值；
> 2. StudyScenario 与 Repository 持有 db 句柄，db 在 `databaseProvider` 中由 Riverpod 生命周期管理；构造 AgentLoop 与流是廉价的（无网络 IO、无文件 IO）。

- [ ] **Step 2: 验证 analyze 仍全绿**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/core/providers/agent_session_provider.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): 新增 AgentSessionProvider（APP 层 agent 调用入口）"
```

---

## Task 3: 新增 WebViewScreenshotProvider（截图服务）

**Files:**
- Create: `study_buddy/lib/core/providers/webview_screenshot_provider.dart`

**目的：** 封装 `InAppWebViewController.takeScreenshot()` 调用 + base64 编码 + 图片大小压缩。纯内存处理，无磁盘 IO。

**Interfaces:**

Produces:
- `Future<CapturedScreenshot?> capture(InAppWebViewController controller)` — 返回含 `Uint8List pngBytes` 与 `String base64DataUri` 的对象；若截图失败返回 null。
- `class CapturedScreenshot { final Uint8List pngBytes; final String base64DataUri; const CapturedScreenshot(this.pngBytes, this.base64DataUri); }`

- [ ] **Step 1: 写新文件**

`study_buddy/lib/core/providers/webview_screenshot_provider.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// WebView 截图结果。bytes 与 base64DataUri 持有同一份图片数据，调用方择一使用。
@immutable
class CapturedScreenshot {
  final Uint8List pngBytes;
  final String base64DataUri; // 形如 "data:image/png;base64,xxxx"
  const CapturedScreenshot(this.pngBytes, this.base64DataUri);
}

/// WebView 截图服务。纯内存：bytes 仅在本对象生命周期内有效，调用方负责释放。
class WebViewScreenshotService {
  /// 截图当前 WebView 页面。返回 null 表示截图失败（页面未就绪 / 平台不支持）。
  Future<CapturedScreenshot?> capture(InAppWebViewController controller) async {
    try {
      final result = await controller.takeScreenshot();
      if (result == null || result.image == null) return null;
      // takeScreenshot 返回的 Uint8List 是 PNG 编码；直接 base64 编码。
      final bytes = result.image!;
      final b64 = base64Encode(bytes);
      return CapturedScreenshot(bytes, 'data:image/png;base64,$b64');
    } catch (_) {
      // 平台不支持 / 页面未就绪 / 用户拒绝截图权限：视为失败。
      return null;
    }
  }
}

final webViewScreenshotServiceProvider = Provider<WebViewScreenshotService>((ref) {
  return WebViewScreenshotService();
});
```

> **说明：** 不压缩图片大小——MVP 范围内 base64 大小不做硬约束；如有视觉问题由后续 task 评估（spec §4.4 已列入风险缓解，本 MVP 不强制实现压缩）。

- [ ] **Step 2: 验证 analyze 仍全绿**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/core/providers/webview_screenshot_provider.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): 新增 WebViewScreenshotProvider（截图纯内存）"
```

---

## Task 4: 新增 QbankWebView widget（InAppWebView 封装）

**Files:**
- Create: `study_buddy/lib/features/external_qbank/qbank_web_view.dart`

**目的：** 把 `InAppWebView` 封装为可复用 widget，暴露 controller 给父组件（ExternalQbankPage 需要它触发截图）。

**Interfaces:**

Produces:
- `class QbankWebView extends ConsumerStatefulWidget` — 构造参数 `{ValueChanged<InAppWebViewController> onControllerReady}`，父组件通过回调拿到 controller。
- `InAppWebViewController get controller`（在 QbankWebViewState 上）—— 父组件通过 GlobalKey 或 callback 持有后调用 takeScreenshot。

**加载目标：** `https://study.keyky.cn/h5/`。

- [ ] **Step 1: 写新文件**

`study_buddy/lib/features/external_qbank/qbank_web_view.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 包装 InAppWebView，加载 study.keyky.cn 题库页。
/// 父组件通过 [onControllerReady] 拿到 controller 以触发截图。
class QbankWebView extends StatefulWidget {
  const QbankWebView({super.key, required this.onControllerReady});

  final ValueChanged<InAppWebViewController> onControllerReady;

  @override
  State<QbankWebView> createState() => _QbankWebViewState();
}

class _QbankWebViewState extends State<QbankWebView> {
  InAppWebViewController? _controller;
  double _progress = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri('https://study.keyky.cn/h5/')),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            supportZoom: false,
            // 允许混合内容（网站可能含 http 资源）
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            // 透明背景，让 host Scaffold 的颜色透出来
            supportTransparentBackground: true,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            widget.onControllerReady(controller);
          },
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress / 100.0);
          },
        ),
        if (_progress < 1.0)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}
```

> **说明：**
> - `mixedContentMode: MIXED_CONTENT_ALWAYS_ALLOW` 是 MVP 内的实用让步；如有 HSTS / 安全要求可收紧到 `MIXED_CONTENT_COMPATIBILITY_MODE`。
> - 顶部 LinearProgressIndicator 在加载完成（progress=1.0）时自动隐藏，给用户加载反馈。
> - JavaScript 与 DOM Storage 必须开启，否则网站自身的登录态无法保持。

- [ ] **Step 2: 验证 analyze 仍全绿**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/features/external_qbank/qbank_web_view.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): QbankWebView 组件（加载 study.keyky.cn）"
```

---

## Task 5: 新增 FloatingAiButton widget（浮窗 FAB）

**Files:**
- Create: `study_buddy/lib/features/external_qbank/floating_ai_button.dart`

**目的：** 右下角悬浮按钮，触发 AI 助手抽屉。Stack 内定位，覆盖在 WebView 上方。

**Interfaces:**

Produces:
- `class FloatingAiButton extends StatelessWidget` — 构造参数 `{required VoidCallback onPressed}`，按下时通过 callback 通知父组件。

- [ ] **Step 1: 写新文件**

`study_buddy/lib/features/external_qbank/floating_ai_button.dart`:

```dart
import 'package:flutter/material.dart';

/// 右下角悬浮 AI 助手按钮。父组件通过 Stack 覆盖在 QbankWebView 上方。
class FloatingAiButton extends StatelessWidget {
  const FloatingAiButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 24,
      child: Material(
        color: Theme.of(context).colorScheme.primary,
        shape: const CircleBorder(),
        elevation: 6,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.smart_toy_outlined, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: 验证 analyze 仍全绿**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/features/external_qbank/floating_ai_button.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): FloatingAiButton（右下角 AI 浮窗按钮）"
```

---

## Task 6: 新增 AiPanelSheet widget（AI 抽屉 + 流式对话）

**Files:**
- Create: `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`

**目的：** 底部 modalBottomSheet，展示截图缩略图 + 用户输入框 + agent 流式输出。监听 `AgentEvent` 流并增量更新 UI。

**Interfaces:**

Produces:
- `Future<void> showAiPanel(BuildContext context, {required CapturedScreenshot screenshot})` — 顶层入口：弹抽屉，把截图交给抽屉。
- 内部使用 `agentSessionProvider` 调用 AgentLoop.run()；UI 通过 StreamSubscription 监听增量事件。

**事件到 UI 的映射（按 spec §4.3）:**
- `AgentStartedEvent` → 显示「正在分析...」
- `TextDeltaEvent` → 追加到「AI 回复」TextField
- `ToolCallStartEvent` → 显示「正在调用 XXX 工具」
- `ToolCallEndEvent` → 显示工具结果摘要 + 若 `name=='save_topic'` 则显示「已保存到知识库」徽标
- `AgentDoneEvent` → 关闭 loading，显示完成
- `AgentErrorEvent` → 显示错误对话框

- [ ] **Step 1: 写新文件**

`study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/webview_screenshot_provider.dart';

/// 弹出底部抽屉：截图预览 + 用户输入 + agent 流式回复。
///
/// 截图来自 [CapturedScreenshot]，纯内存持有；会话结束即释放（widget dispose）。
Future<void> showAiPanel(
  BuildContext context, {
  required CapturedScreenshot screenshot,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _AiPanelSheet(screenshot: screenshot),
  );
}

class _AiPanelSheet extends ConsumerStatefulWidget {
  const _AiPanelSheet({required this.screenshot});
  final CapturedScreenshot screenshot;

  @override
  ConsumerState<_AiPanelSheet> createState() => _AiPanelSheetState();
}

class _AiPanelSheetState extends ConsumerState<_AiPanelSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final StringBuffer _aiText = StringBuffer();
  final List<String> _toolEvents = []; // 工具调用轨迹
  bool _busy = false;
  bool _saved = false; // save_topic 调用过
  String? _errorText;
  StreamSubscription<AgentEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _inputCtrl.dispose();
    // 显式置空让 GC 释放 bytes 与 base64 字符串
    super.dispose();
  }

  Future<void> _runAgent() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
      _aiText.clear();
      _toolEvents.clear();
      _saved = false;
    });

    final userText = _inputCtrl.text.trim().isEmpty
        ? '分析这道题涉及的知识点'
        : _inputCtrl.text.trim();
    final messages = <ChatMessage>[
      ChatMessage(
        role: 'user',
        content: [
          TextPart(userText),
          ImageUrlPart(widget.screenshot.base64DataUri, detail: 'high'),
        ],
      ),
    ];

    try {
      final session = ref.read(agentSessionProvider);
      final stream = await session.run(messages);
      _sub = stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            switch (event) {
              case AgentStartedEvent():
                // 已在 _busy 状态体现
                break;
              case TextDeltaEvent(:final delta):
                _aiText.write(delta);
                break;
              case ToolCallStartEvent(:final name):
                _toolEvents.add('→ 调用工具：$name');
                break;
              case ToolCallEndEvent(:final name, :final result):
                _toolEvents.add('← $name：$result');
                if (name == 'save_topic') _saved = true;
                break;
              case ToolProgressEvent(:final progress):
                _toolEvents.add('· $progress');
                break;
              case CompactionEvent():
                _toolEvents.add('· 上下文已压缩');
                break;
              case RetryEvent(:final attempt):
                _toolEvents.add('· 重试第 $attempt 次');
                break;
              case AgentDoneEvent():
                _busy = false;
                break;
              case AgentErrorEvent(:final message):
                _errorText = message;
                _busy = false;
                break;
            }
          });
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _errorText = '$e';
            _busy = false;
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _busy = false);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: mediaQuery.viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部抓把手
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 截图缩略图
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                widget.screenshot.pngBytes,
                height: 120,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 12),
            // 用户输入
            TextField(
              controller: _inputCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '补充说明（可选）',
                hintText: '例如：解析思路',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            // 提交按钮
            FilledButton(
              onPressed: _busy ? null : _runAgent,
              child: Text(_busy ? '分析中...' : '开始分析'),
            ),
            const SizedBox(height: 16),
            // 错误展示
            if (_errorText != null)
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(
                  _errorText!,
                  style: TextStyle(color: Colors.red.shade900),
                ),
              ),
            // 工具调用轨迹
            if (_toolEvents.isNotEmpty) ...[
              const Text('工具调用', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ..._toolEvents.map(
                (e) => Text(e, style: const TextStyle(fontSize: 12)),
              ),
              if (_saved)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '✓ 已保存到知识库',
                      style: TextStyle(color: Colors.green, fontSize: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
            ],
            // AI 回复文本
            if (_aiText.isNotEmpty) ...[
              const Text('AI 回复', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(_aiText.toString()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

> **注意：** 由于 `AgentEvent` 是 sealed class，switch 必须覆盖所有 9 个分支（AgentStarted / TextDelta / ToolCallStart / ToolCallEnd / ToolProgress / Compaction / Retry / AgentDone / AgentError）。漏写任一分支会导致 Dart 编译错误；新增事件类型时此处必须同步补 case。

- [ ] **Step 2: 验证 analyze**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: 若有 lint 报错（多为 `_AiPanelSheetState` private 类的 unused 字段警告或类似），按需补充 suppress 注释或微调实现；目标是 `No issues found!`。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/features/external_qbank/ai_panel_sheet.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): AiPanelSheet（截图预览 + agent 流式对话抽屉）"
```

---

## Task 7: 新增 ExternalQbankPage（WebView 容器页）

**Files:**
- Create: `study_buddy/lib/features/external_qbank/external_qbank_page.dart`

**目的：** 把 QbankWebView + FloatingAiButton + AiPanelSheet 编排到一个页面：AppBar 含「返回」按钮；body 是 Stack（WebView 在底，浮窗在上）；FAB 点击 → 截图 → 弹 AiPanelSheet。

**Interfaces:**

Produces:
- `class ExternalQbankPage extends ConsumerStatefulWidget` — 直接作为路由页使用。

- [ ] **Step 1: 写新文件**

`study_buddy/lib/features/external_qbank/external_qbank_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/webview_screenshot_provider.dart';
import 'ai_panel_sheet.dart';
import 'floating_ai_button.dart';
import 'qbank_web_view.dart';

class ExternalQbankPage extends ConsumerStatefulWidget {
  const ExternalQbankPage({super.key});

  @override
  ConsumerState<ExternalQbankPage> createState() => _ExternalQbankPageState();
}

class _ExternalQbankPageState extends ConsumerState<ExternalQbankPage> {
  InAppWebViewController? _controller;

  Future<void> _onAiButtonPressed() async {
    final ctrl = _controller;
    if (ctrl == null) {
      _toast('页面还未加载完成，请稍候');
      return;
    }
    final service = ref.read(webViewScreenshotServiceProvider);
    final shot = await service.capture(ctrl);
    if (!mounted) return;
    if (shot == null) {
      _toast('截图失败，请稍候再试');
      return;
    }
    await showAiPanel(context, screenshot: shot);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('题库'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Stack(
        children: [
          QbankWebView(
            onControllerReady: (c) => _controller = c,
          ),
          FloatingAiButton(onPressed: _onAiButtonPressed),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: 验证 analyze**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/features/external_qbank/external_qbank_page.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): ExternalQbankPage（WebView 容器 + 浮窗 AI 编排）"
```

---

## Task 8: 注册路由 + HomePage 入口

**Files:**
- Modify: `study_buddy/lib/router.dart`
- Modify: `study_buddy/lib/features/home/home_page.dart`

**目的：** 让 `/external-qbank` 路由可达；首页加「进入题库」按钮跳过去。

- [ ] **Step 1: 修改 router.dart**

`study_buddy/lib/router.dart`:

```dart
import 'package:go_router/go_router.dart';
import 'features/external_qbank/external_qbank_page.dart';
import 'features/home/home_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: '/external-qbank',
        builder: (context, state) => const ExternalQbankPage(),
      ),
    ],
  );
}
```

- [ ] **Step 2: 修改 home_page.dart，把占位文本替换为「进入题库」按钮**

`study_buddy/lib/features/home/home_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/database_provider.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (db) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '地基已就绪 ✅\n数据库已连接。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('进入题库'),
                  onPressed: () => context.go('/external-qbank'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 验证 analyze**

Run:
```bash
cd study_buddy && flutter analyze
```

Expected: `No issues found!`。

- [ ] **Step 4: 提交**

```bash
git add study_buddy/lib/router.dart study_buddy/lib/features/home/home_page.dart
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "feat(app): 注册 /external-qbank 路由 + 首页「进入题库」入口"
```

---

## Task 9: 更新占位 widget_test（防止 HomePage 变更后旧测试失败）

**Files:**
- Modify: `study_buddy/test/widget_test.dart`

**目的：** 地基阶段遗留的占位测试可能因 HomePage 改版而失败。MVP 范围只需保证测试文件**仍能编译**，不要求扩展测试覆盖（spec §8 验收标准 #2 只要求 engine 层测试通过，APP 层不要求单测）。

- [ ] **Step 1: 检查现有测试文件**

Read `study_buddy/test/widget_test.dart`，确认其结构。

- [ ] **Step 2: 如测试已编译失败，按需简化或删除失败用例**

**选项 A（推荐）：** 若 widget_test 仅含一处 `testWidgets('Counter increments ...')` 之类的占位用例，**直接删除整个文件**（地基 spec 已允许 widget 测试不是 MVP 验收项）。

```bash
cd study_buddy && rm test/widget_test.dart
```

**选项 B：** 若保留文件，将内容替换为：

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    // MVP 阶段占位：APP 层 widget 测试待后续子项目补。
    expect(true, isTrue);
  });
}
```

> **判断依据：** 实际执行 `flutter test` 看输出。若旧测试仍在引用被改的 widget，跑选项 B；若想彻底干净，跑选项 A。

- [ ] **Step 3: 验证 widget 测试通过**

Run:
```bash
cd study_buddy && flutter test
```

Expected: `All tests passed!`（或 `No tests were found` 若已删除文件）。

- [ ] **Step 4: 验证 engine 测试仍通过（engine 层零改动验证）**

Run:
```bash
cd packages/study_engine && flutter test
```

Expected: 全部测试通过，与 Task 1 启动前一致。**若有任何 engine 测试失败，立即 STOP 并排查——说明本 plan 误改了 engine。**

- [ ] **Step 5: 提交**

```bash
git add study_buddy/test/widget_test.dart  # 仅当选项 B 才会有 add
git -c user.name="yedazhi" -c user.email="yedazhi@local" commit -m "test(app): 清理 widget_test 占位（HomePage 已变更）"
```

> 若执行选项 A（删除），commit 内容为：`test(app): 删除 widget_test 占位（HomePage 已变更；MVP 不要求 widget 单测）`

---

## Task 10: 全量验证 + 敏感字符串扫描

**Files:** 无（仅运行验证命令 + 可选的 grep 检查）

**目的：** spec §8 验收标准的端到端核对。重点是**静态扫描**：确认 git 历史与源码无 study.keyky.cn 任何鉴权凭据。

- [ ] **Step 1: 全包 analyze**

Run:
```bash
cd study_buddy && flutter analyze && cd ../packages/study_engine && flutter analyze
```

Expected: 两处均 `No issues found!`。

- [ ] **Step 2: 全包 test**

Run:
```bash
cd study_buddy && flutter test && cd ../packages/study_engine && flutter test
```

Expected: 两处测试均通过；engine 测试通过证明零改动承诺兑现。

- [ ] **Step 3: 敏感字符串扫描（spec §8 #4 硬约束）**

```bash
cd "D:/my_space/study"
echo "=== 源码内：网站域名 + 鉴权字段模式扫描 ==="
# 检测代码中是否出现 study.keyky.cn 的硬编码鉴权串（token/cookie/Authorization）
# 模式：study.keyky.cn 域名紧邻 token/cookie/Authorization 关键字
grep -rniE "study\.keyky\.cn" study_buddy/lib study_buddy/test packages/study_engine/lib packages/study_engine/test 2>/dev/null \
  | grep -iE "token|cookie|Authorization|Bearer|ixunke=" \
  || echo "✓ 源码无敏感字符串"

echo "=== git 历史扫描（含本 plan 全部 commit）==="
# 同样的模式扫整个 git 历史（commit 内容 + diff）
git log -p --all 2>/dev/null \
  | grep -iE "study\.keyky\.cn" \
  | grep -iE "token|cookie|Authorization|Bearer|ixunke=" \
  && echo "✗ git 历史有敏感字符串！" \
  || echo "✓ git 历史干净"
```

Expected: 两个 echo 都打出「✓」字样。若任何一处打出「✗」，**立即 STOP 并删除对应 commit**（`git rebase -i HEAD~N` 删 commit，或新建干净分支 cherry-pick）。

- [ ] **Step 4: APK / Windows 构建可行性**

（按用户本地环境二选一）

**Android：**
```bash
cd study_buddy && flutter build apk --debug
```

**Windows：**
```bash
cd study_buddy && flutter build windows
```

Expected: 构建成功；若失败则排查（多见 flutter_inappwebview 平台插件缺失）。

- [ ] **Step 5: 手工启动 + 验收清单**

```bash
cd study_buddy && flutter run -d windows   # 或 android
```

逐项核对：

- [ ] 首页有「进入题库」按钮
- [ ] 点击 → 进入 `/external-qbank` 页
- [ ] WebView 加载 study.keyky.cn，进度条可见，最终进度条消失
- [ ] 未登录可看到首页
- [ ] 在 WebView 内通过网站登录页（扫码 / 手机号）登录，能正常刷题
- [ ] 点击右下角浮窗 → 抽屉弹出，截图缩略图可见
- [ ] 点「开始分析」→ 流式显示 AI 回复文本
- [ ] 若 LLM 自主调 save_topic → 抽屉显示「✓ 已保存到知识库」徽标
- [ ] 关闭抽屉 → 回到 WebView 页面正常

> **手工验收需本地有可用 LLM 配置**（llm_config 表中至少一条 `is_default=1 AND supports_vision=1` 的记录）。若暂无，需先在 db 中插入种子数据——这一步**不在本 plan 范围**，由用户自决（地基 spec 未覆盖此 UI）。

- [ ] **Step 6: 验收完成**

如有任一核对项失败，记录到 commit message 后回滚对应 task 重做。全部通过则 MVP 完成。

---

## 验收对照（spec §8 → plan tasks）

| spec 验收项 | 对应 Task |
|---|---|
| §8 #1 flutter analyze 全绿（app + engine） | Task 10 Step 1 |
| §8 #2 engine 测试通过（无需新增测试） | Task 10 Step 2 |
| §8 #3 APP 启动不崩溃 | Task 10 Step 4 |
| §8 #4 手工验收 7 项 | Task 10 Step 5 |
| §8 #5 平台兼容（Android / iOS / Windows） | Task 10 Step 4 |
| §8 #4 敏感项验证（无鉴权字面值） | Task 10 Step 3 |

---

## 边界提醒（spec §9 YAGNI）

执行过程中**必须保持**：

- ❌ 不调 study.keyky.cn 任何 API
- ❌ 不写 token / cookie / Authorization
- ❌ 不向 WebView 注入 JS
- ❌ 不主动拦截 WebView 网络请求
- ❌ 不在 task 间新增 engine 层代码
- ❌ 不写题库缓存到本地

若任一 task 实施时发现不得不越界，**STOP 并回报**。