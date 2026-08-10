import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/screenshot_provider.dart';
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

void main() {
  testWidgets('首轮:截图预览可见,发送后显示 user 与 assistant 气泡', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

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

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

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

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

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
}
