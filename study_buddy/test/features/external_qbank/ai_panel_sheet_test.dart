import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
// image_picker_platform_interface 是 image_picker 的传递依赖：
// 我们直接 import 它来 mock ImagePickerPlatform.instance（无需在 pubspec 中声明）。
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/captured_image.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/core/widgets/markdown_latex.dart';
import 'package:study_buddy/features/external_qbank/ai_panel_sheet.dart';
import 'package:study_engine/study_engine.dart';

/// 假 AgentSession：收到 run 后返回一个立即完成的纯文本轮。
///
/// 事件序列遵循引擎真实契约（agent_loop.dart）：
/// 纯文本轮 = TextDelta* + AgentDoneEvent(finalText)，无 RoundEnd。
/// 最终回答经 AgentDoneEvent 由 Notifier append 进 messages。
///
/// 注：Riverpod 3.x 中 `Ref` 为 sealed 类，外部库无法 `implements Ref`。
/// 因此 fake 通过 `overrideWith((ref) => _FakeAgentSession(ref))` 注入，
/// 由 Riverpod 把真实 Ref 传进来，再交给 `super(ref)`。
class _FakeAgentSession extends AgentSession {
  _FakeAgentSession(super.ref);
  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {int? chatSessionId}) async {
    return Stream.fromIterable([
      TextDeltaEvent('这是'),
      TextDeltaEvent('分析'),
      AgentDoneEvent('这是分析'),
    ]);
  }
}

/// 可控假 AgentSession：stream 由外部 [StreamController] 驱动，
/// 不 close 前 `send()` 一直处于 busy（用于断言"分析中..."）。
class _ControllableAgentSession extends AgentSession {
  _ControllableAgentSession(super.ref, this._controller);
  final StreamController<AgentEvent> _controller;
  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {int? chatSessionId}) async {
    return _controller.stream;
  }
}

/// 假 /crop 裁剪页：点击「确认裁剪」即 pop 一个 CapturedScreenshot。
/// 真实裁剪页（ImageCropPage）依赖 ui 解码，测试里用这个假的替代，
/// 让 `context.push('/crop', extra: ...)` 能返回结果。
class _FakeCropPage extends StatelessWidget {
  const _FakeCropPage({required this.sourceBytes});
  final Uint8List sourceBytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => context.pop(
            CapturedScreenshot(sourceBytes, 'data:image/png;base64,ZmFrZQ=='),
          ),
          child: const Text('确认裁剪'),
        ),
      ),
    );
  }
}

Uint8List _pngBytes() => Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC'));

/// 查找 [SelectableText.rich] 中包含 [text] 的 widget。
///
/// 纸感化后 assistant 回复用 `SelectableText.rich`（知识点 ※ 解析），
/// `find.text` 无法命中（含 `findRichText: true` 也不行——底层是
/// `EditableText`/`RenderEditable` 而非 `RichText`），故按 textSpan 明文匹配。
Finder _selectableTextContaining(String text) =>
    find.byWidgetPredicate((w) =>
        w is SelectableText &&
        (w.textSpan?.toPlainText() ?? '').contains(text));

/// 假 image_picker platform：与 Task 2 测试同范式，本任务内复制到本文件。
/// 只 mock getImage 路径（面板走的 picker 接口），其他方法留默认 noop。
class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? returnValue;
  Object? throwOnPick;

  @override
  Future<XFile?> getImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (throwOnPick != null) throw throwOnPick!;
    return returnValue;
  }
}

/// 装配 helper：注入 GoRouter（包含 /、/ai、/crop）与 AppTheme.light，避免裸 MaterialApp
/// 下 `context.push('/ai')` / `context.push('/crop')` 触发 GoRouter 断言崩溃。
///
/// tap `open` → pumpAndSettle → 跳到 /ai 全屏对话页（rect 上屏可见）。
Future<void> pumpPanel(
  WidgetTester tester, {
  required ProviderContainer container,
  CapturedScreenshot? screenshot,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Builder(builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => showAiPanel(ctx, screenshot: screenshot),
                  child: const Text('open'),
                ),
              )),
        ),
      ),
      GoRoute(
        path: '/ai',
        builder: (_, state) => AiChatPage(
          initialScreenshot: state.extra is CapturedScreenshot
              ? state.extra as CapturedScreenshot
              : null,
        ),
      ),
      // 用 _FakeCropPage 而非真实 ImageCropPage：避免 ui 解码拖慢/污染测试。
      GoRoute(
        path: '/crop',
        builder: (_, state) =>
            _FakeCropPage(sourceBytes: state.extra as Uint8List),
      ),
    ],
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light,
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首轮:截图预览可见,发送后显示 user 与 assistant 气泡', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);

    // 首轮截图预览可见
    expect(find.byType(Image), findsWidgets);
    // 点发送
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();

    // user 消息与 assistant 消息都渲染
    expect(find.text('分析这道题涉及的知识点'), findsOneWidget);
    expect(_selectableTextContaining('这是分析'), findsOneWidget);
  });

  testWidgets('追问:输入框可连续输入,加图按钮存在', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);

    // 输入框存在
    expect(find.byType(TextField), findsOneWidget);
    // 加图按钮存在（icon）
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);
  });

  testWidgets('busy 时输入框禁用,按钮显示分析中', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    // 可控 fake：stream 不 close 前一直 busy
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider
          .overrideWith((ref) => _ControllableAgentSession(ref, controller)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);

    await tester.tap(find.text('开始分析'));
    await tester.pump(); // 不等完成

    // 按钮变为分析中
    expect(find.text('分析中...'), findsOneWidget);

    // 放行事件流：本轮完成,恢复可用。
    // StreamController 事件派发是真实异步，需 runAsync 才能推进；
    // 完成后用 pump 渲染（不用 pumpAndSettle，避免 fake async 下等待真实 future）。
    await tester.runAsync(() async {
      // 真实纯文本轮序列：TextDelta + AgentDoneEvent（无 RoundEnd）
      controller.add(TextDeltaEvent('慢'));
      controller.add(AgentDoneEvent('慢'));
      await controller.close();
    });
    await tester.pump();
    await tester.pump();

    // 结束后不再 busy
    expect(find.text('分析中...'), findsNothing);
  });

  testWidgets('追问轮:tap 加图按钮弹 Sheet,选相册后预览出现', (tester) async {
    // 1. mock picker —— 完整 1x1 PNG 字节(复用 _pngBytes)，确保 Image.memory
    //    异步解码不抛异常污染 pumpAndSettle 队列。
    final fake = _FakeImagePickerPlatform()
      ..returnValue = XFile.fromData(
        _pngBytes(),
        mimeType: 'image/png',
        name: 'q.png',
      );
    final original = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = fake;
    addTearDown(() => ImagePickerPlatform.instance = original);

    // 2. 面板启动（装配 GoRouter：_pickImageForFollowUp 会 context.push('/crop')）
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);
    await pumpPanel(tester, container: container, screenshot: screenshot);

    // 3. 先点「开始分析」让 _firstSent=true（追问轮加图才生效；实际首轮加图也可，
    //    但测追问轮更贴近真实使用场景）
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();

    // 4. tap 加图按钮 → Sheet 弹出 → 选"从相册选择"
    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();

    // 5. pickImageForAi 成功 → context.push('/crop') 打开假裁剪页 → 点「确认裁剪」返回结果。
    expect(find.text('确认裁剪'), findsOneWidget);
    await tester.tap(find.text('确认裁剪'));
    await tester.pumpAndSettle();

    // 6. _pendingImage 预览出现：Image widget + 移除按钮(close icon)
    expect(find.byType(Image), findsWidgets);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('save_topic 工具结果落地后,流式轨迹转 SavedTopicCapsule,AI 走 MarkdownLatex',
      (tester) async {
    // 接线回归（task 7.2）：save_topic 工具结果(JSON) → SavedTopicCapsule，
    // AI 文本经 MarkdownLatex 渲染。
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider
          .overrideWith((ref) => _ControllableAgentSession(ref, controller)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);
    await tester.tap(find.text('开始分析'));
    await tester.pump();

    // save_topic 事件：tool result 与 tool 消息 content 都是
    // SaveTopicResult.toJson() 字符串。落库走 AgentRoundEndEvent（持久路径
    // _buildMessage tool 分支），流式走 ToolCallStart/End（_AiNote toolEvents）。
    const args = '{"path":"数学/导数","title":"极限","question":"q","summary":"s"}';
    const toolResult = '{"id":7,"is_new":true,"msg":"已保存知识点"}';
    await tester.runAsync(() async {
      controller.add(ToolCallStartEvent('save_topic', 't1'));
      controller.add(ToolCallEndEvent('save_topic', toolResult, 't1'));
      controller.add(AgentRoundEndEvent([
        ChatMessage(role: 'assistant', content: '已保存', toolCalls: [
          ToolCall(id: 't1', name: 'save_topic', arguments: args),
        ]),
        ChatMessage(role: 'tool', content: toolResult, toolCallId: 't1'),
      ]));
      controller.add(AgentDoneEvent('已保存'));
      await controller.close();
    });
    await tester.pump();
    await tester.pump();

    // (1) save_topic 工具结果渲染为 SavedTopicCapsule —— isNew=true → 「新」badge。
    // (2) 不再出现原始『save_topic: …』灰色轨迹行（流式+持久路径均已转卡片）。
    expect(find.text('新'), findsWidgets);
    expect(find.textContaining('save_topic:'), findsNothing);
    // (3) AI 文本经 MarkdownLatex 渲染（selectable）。
    expect(find.byType(MarkdownLatex), findsWidgets);
  });

  testWidgets('「新对话」按钮:点击后 messages 清空、页面仍在、输入框还在',
      (tester) async {
    // 纯文字入口（无 screenshot），保证 _FakeAgentSession 一次走完
    // TextDelta + AgentDoneEvent 完整契约，messages 累计 2 条（user+assistant）。
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container);

    // 纯文字入口必须先输入内容，否则 send('', null) 在 chat_session_provider 直接 return，
    // messages 不会累计（空输入不发送是本产品的既定语义）。
    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();

    // 已有 user + assistant 两条消息
    expect(container.read(currentChatProvider).messages, hasLength(2));

    // 点「新对话」(AppBar IconButton, tooltip '新对话')
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();

    // messages 已清，对话页仍在（输入框在）
    expect(container.read(currentChatProvider).messages, isEmpty);
    expect(find.byType(TextField), findsOneWidget);
  });
}
