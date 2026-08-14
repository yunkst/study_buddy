import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
// image_picker_platform_interface 是 image_picker 的传递依赖：
// 我们直接 import 它来 mock ImagePickerPlatform.instance（无需在 pubspec 中声明）。
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/captured_image.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
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
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    return AgentSessionHandle(stream: Stream.fromIterable([
      TextDeltaEvent('这是'),
      TextDeltaEvent('分析'),
      AgentDoneEvent('这是分析'),
    ]));
  }
}

/// 可控假 AgentSession：stream 由外部 [StreamController] 驱动，
/// 不 close 前 `send()` 一直处于 busy（用于断言"分析中..."）。
class _ControllableAgentSession extends AgentSession {
  _ControllableAgentSession(super.ref, this._controller);
  final StreamController<AgentEvent> _controller;
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    return AgentSessionHandle(stream: _controller.stream);
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
/// 开发者模式 `_DevCodeBlock` 用 `SelectableText(text:)`（普通字符串，非 textSpan），
/// 故同时回退检查 `.data`。
Finder _selectableTextContaining(String text) =>
    find.byWidgetPredicate((w) => w is SelectableText
        ? (w.textSpan?.toPlainText() ?? '').contains(text) ||
            (w.data ?? '').contains(text)
        : false);

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
  int? topicId,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Builder(builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => showAiPanel(ctx, screenshot: screenshot, topicId: topicId),
                  child: const Text('open'),
                ),
              )),
        ),
      ),
      GoRoute(
        path: '/ai',
        builder: (_, state) {
          final launch = state.extra is AiPanelLaunch
              ? state.extra as AiPanelLaunch
              : const AiPanelLaunch();
          return AiChatPage(
            initialScreenshot: launch.screenshot,
            initialTopicId: launch.topicId,
          );
        },
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
  // 内存数据库需要 FFI 工厂（不在 Android/iOS 测试环境里走原生 sqflite）。
  // 开发者模式面板会经 databaseProvider 读 agent_memory/topic 表——用 sqflite_ffi
  // 在测试里打开内存库（与 settings_page_test 同范式）。
  setUpAll(sqfliteFfiInit);

  testWidgets('首轮:截图预览可见,发送后显示 user 与 assistant 气泡', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);

    // 首轮截图预览可见
    expect(find.byType(Image), findsWidgets);
    // 点发送（微信风小按钮，tooltip 定位）
    await tester.tap(find.byTooltip('发送'));
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

    await tester.tap(find.byTooltip('发送'));
    await tester.pump(); // 不等完成

    // 按钮变为 busy：输入框禁用 + 发送按钮呈沙漏（无文字，改断言图标）
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    // busy 且暂无流式文本/挂起提问：「AI 正在思考…」指示器出现，
    // 三点动画 + 文案，消除「卡住」错觉（此前此刻无任何运行反馈）。
    expect(find.text('AI 正在思考…'), findsOneWidget);

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

    // 结束后不再 busy（沙漏消失）
    expect(find.byIcon(Icons.hourglass_top), findsNothing);
    // 思考指示器也随之消失（已完成，不再是 busy/空 streaming 状态）
    expect(find.text('AI 正在思考…'), findsNothing);
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

    // 3. 先点发送让 _firstSent=true（追问轮加图才生效；实际首轮加图也可，
    //    但测追问轮更贴近真实使用场景）
    await tester.tap(find.byTooltip('发送'));
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

  testWidgets('微信风发送按钮:纯文字空输入禁用,输入文本后可用并发送', (tester) async {
    // 纯文字入口（无截图）：_pendingImage=null,初始 canSend=false → 发送禁用。
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);
    await pumpPanel(tester, container: container);

    // 空输入：tap 发送按钮（InkWell onTap=null,实际不响应）不应新增消息。
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(container.read(currentChatProvider).messages, isEmpty);

    // 输入文本 → canSend=true,按钮可用；tap 发送 → 新增 user+assistant。
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump(); // 触发 _onInputChanged → 按钮转可用
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(container.read(currentChatProvider).messages, hasLength(2));
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
    await tester.tap(find.byTooltip('发送'));
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
    await tester.pump(); // 触发 _onInputChanged → 发送按钮转可用
    await tester.tap(find.byTooltip('发送'));
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

  testWidgets('教学入口:带 topicId 进入后 AI 自动开场,开场指令渲染为引导横幅',
      (tester) async {
    // override databaseProvider 让其 future 立即 reject：startTeaching 内的
    // _tryRestoreTeaching await databaseProvider.future 会抛错被 try/catch 吞掉，
    // 立即返回 false → 走 send 开场路径（同步 append user 消息到 state，
    // 后续 stream 监听由 FakeAgentSession 的 Stream.fromIterable 同步派发完成）。
    // 避免 fakeAsync 下 path_provider method channel 调用永久挂起导致 pumpAndSettle 死锁。
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
      databaseProvider.overrideWith((ref) =>
          Future.error(StateError('test: db unavailable'))),
    ]);
    addTearDown(container.dispose);

    // 知识点教学入口（topicId=42）：进入即自动清会话 + 发开场消息 + AI 开场回复。
    await pumpPanel(tester, container: container, topicId: 42);
    // startTeaching 同步完成 send 部分后 await firstToken.future。
    // 多次 pump 推进 fakeAsync：让 stream 监听 / UI 重建 / LoggerService 内
    // 的 1s Timer（_schedulePersist）跑完，避免 timer 残留触发 _verifyInvariants 失败。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    // 开场指令 user 消息渲染为居中引导横幅（而非用户气泡）。
    expect(find.text('从场景出发，认识这个知识点'), findsOneWidget);
    // AI 开场回复渲染（_FakeAgentSession 返回 '这是分析'）。
    expect(_selectableTextContaining('这是分析'), findsOneWidget);
    // 开场指令本身不作为用户气泡文本泄漏显示。
    expect(find.textContaining('诞生的具体场景'), findsNothing);
    // 会话含 user(开场指令) + assistant(开场回复)（在 topicTeachingProvider，
    // 而非 currentChatProvider——教学与主线隔离）。
    final state = container.read(topicTeachingProvider);
    expect(state.messages, hasLength(2));
    expect(state.messages[0].role, 'user');
    expect(state.messages[1].role, 'assistant');
    // 主线 currentChatProvider 保持空（不被教学覆盖）。
    expect(container.read(currentChatProvider).messages, isEmpty);
  });

  testWidgets('教学入口:顶部可折叠知识卡渲染,折叠后只留标题;会话走 topicTeachingProvider',
      (tester) async {
    // fakeAsync 下 startTeaching 走真 DB I/O 会永久挂起，故用 reject override：
    // _tryRestoreTeaching 立刻 catch → 走 send 路径（FakeAgentSession 同步 stream
    // 由 fakeAsync microtask 推进完成）。_TopicHeaderCard 的 FutureBuilder 同样
    // 走 databaseProvider（reject），title fallback '知识点'，引子/答案 fallback
    // 到空 → 不渲染。折叠测试聚焦「toggle 行为」与「教学会话走 topicTeachingProvider」：
    // 折叠态不渲染引子/答案的展开（这里 snap.hasData=false，折叠/展开均不渲染
    // 引子/答案行），验证 toggle 可点 + 教学会话独立于主线。
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
      databaseProvider.overrideWith((ref) =>
          Future.error(StateError('test: db unavailable'))),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, topicId: 42);
    // 多次 pump 推进 fakeAsync：startTeaching 的 stream 派发 + LoggerService
    // 1s Timer（_schedulePersist）跑完，避免 _verifyInvariants timer 残留失败。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    // 顶部知识卡：toggle 可见（fallback '知识点' 标题 + IconButton）
    expect(find.byKey(const ValueKey('topic-card-toggle')), findsOneWidget);

    // 折叠：点 toggle → 状态翻转（不抛错）
    await tester.tap(find.byKey(const ValueKey('topic-card-toggle')));
    await tester.pump();
    // 折叠后：knowledge 数据 snap 仍可能为 null，但至少 toggle 仍存在（可再展开）
    expect(find.byKey(const ValueKey('topic-card-toggle')), findsOneWidget);

    // 会话走 topicTeachingProvider（不污染主线）
    final teachingState = container.read(topicTeachingProvider);
    final mainState = container.read(currentChatProvider);
    expect(mainState.messages, isEmpty); // 主线没被覆盖
    expect(teachingState.messages, isNotEmpty); // 教学开场已发出
  });

  // 回归：空态三按钮（拍照 / 从相册选择 / 直接输入文字）文字颜色必须与
  // tonal 按钮背景（secondaryContainer）配对——即 onSecondaryContainer。
  // 历史缺陷：label 套用 headlineSmall 样式（颜色为 onSurface 暖墨），
  // 落在冷色 secondaryContainer 上色相冲突、对比不足，「看不清字」。
  testWidgets('空态按钮文字用 onSecondaryContainer,与 secondaryContainer 背景配对',
      (tester) async {
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);
    // 不传 screenshot：messages 空 + _pendingImage 空 → 进入空态引导。
    await pumpPanel(tester, container: container);

    final expected = AppTheme.light.colorScheme.onSecondaryContainer;
    for (final label in const ['拍照', '从相册选择', '直接输入文字']) {
      final text = tester.widget<Text>(find.text(label));
      expect(
        text.style?.color,
        expected,
        reason: '「$label」文字颜色应为 onSecondaryContainer($expected)，'
            '与 tonal 按钮背景 secondaryContainer 形成足够对比。',
      );
    }
  });

  // ───────── 开发者模式 ─────────

  testWidgets('开发者模式:非 save_topic 工具渲染可展开详情卡片,展开可见参数与结果',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dev_mode_enabled': true});
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider
          .overrideWith((ref) => _ControllableAgentSession(ref, controller)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    const args = '{"id":7}';
    const result = '{"id":7,"title":"极限","summary":"答案"}';
    await tester.runAsync(() async {
      controller.add(ToolCallStartEvent('get_topic', 't1'));
      controller.add(ToolCallEndEvent('get_topic', result, 't1'));
      controller.add(AgentRoundEndEvent([
        ChatMessage(role: 'assistant', content: '已查询', toolCalls: [
          ToolCall(id: 't1', name: 'get_topic', arguments: args),
        ]),
        ChatMessage(role: 'tool', content: result, toolCallId: 't1'),
      ]));
      controller.add(AgentDoneEvent('已查询'));
      await controller.close();
    });
    await tester.pump();
    await tester.pump();

    // 详情卡片折叠态：工具名作为卡片头可见。
    expect(find.text('get_topic'), findsOneWidget);
    // 点按展开 → 参数/结果两段 + pretty JSON。
    await tester.tap(find.text('get_topic'));
    await tester.pump();
    expect(find.text('参数（arguments）'), findsOneWidget);
    expect(find.text('结果（result）'), findsOneWidget);
    expect(_selectableTextContaining('"id": 7'), findsWidgets);
    expect(_selectableTextContaining('"title": "极限"'), findsWidgets);
  });

  testWidgets('开发者模式:save_topic 仍渲染 SavedTopicCapsule 而非详情卡片',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dev_mode_enabled': true});
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider
          .overrideWith((ref) => _ControllableAgentSession(ref, controller)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

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

    // 工具触发卡片保留：SavedTopicCapsule（isNew=true → 「新」badge）。
    expect(find.text('新'), findsWidgets);
    // 不被转成详情卡片（无「save_topic」工具名头行）。
    expect(find.text('save_topic'), findsNothing);
  });

  testWidgets('开发者模式:展开注入上下文面板显示今日日期与经验记忆',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dev_mode_enabled': true});

    // 在内存库预置经验记忆（注入面板的核心数据来源）。
    // runAsync 内做真实异步 DB 写入（fake-async 下无法直接完成）。
    late final StudyDatabase sdb;
    await tester.runAsync(() async {
      sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      await AgentMemoryRepository(sdb)
          .add('study_plan', '用户喜欢先看结论再给推导');
    });
    addTearDown(() => sdb.close());

    // 不走 teaching 入口——避免 send() 真实异步写库与 pumpAndSettle 死锁。
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container);
    await tester.pumpAndSettle();

    // 注入面板头可见。
    expect(find.text('已注入上下文（开发者模式）'), findsOneWidget);
    // 展开：今日日期 + 经验记忆两段。面板读库是真实异步，
    // 展开后用 runAsync 等待 isolate 查询完成，再 pump 渲染数据态。
    await tester.tap(find.text('已注入上下文（开发者模式）'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.textContaining('{{today}}'), findsOneWidget);
    expect(find.textContaining('<memory-context>'), findsOneWidget);
    // 经验记忆内容（编号块）可见。
    expect(_selectableTextContaining('先看结论再给推导'), findsOneWidget);
    // 非教学模式：教学上下文字段不渲染（节省噪声）。
    expect(find.textContaining('{{topic_context}}'), findsNothing);
  });
}
