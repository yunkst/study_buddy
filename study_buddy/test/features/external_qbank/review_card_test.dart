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

/// 可控假 AgentSession:stream 由外部 StreamController 驱动(同 ai_panel_sheet_test 模式)。
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

void main() {
  testWidgets('save_review 工具完成后,对话流出现批改卡片', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _ControllableAgentSession(ref, controller)),
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
    await tester.pump();

    // 模拟一轮 save_review 工具调用。
    // arguments 是原始 JSON 字符串(对应 ToolCall.arguments)。
    const args = '{"summary":"批改3题,对1错2","items":[{"seq":1,"question":"求极限","verdict":"wrong","analysis":"应为1"}]}';
    await tester.runAsync(() async {
      controller.add(ToolCallStartEvent('save_review', 'c1'));
      controller.add(ToolCallEndEvent('save_review', '已保存批改(共 1 题,review_id=7)', 'c1'));
      controller.add(AgentRoundEndEvent([
        ChatMessage(role: 'assistant', content: '已批改', toolCalls: [
          ToolCall(id: 'c1', name: 'save_review', arguments: args),
        ]),
        ChatMessage(role: 'tool', content: '已保存批改(共 1 题,review_id=7)', toolCallId: 'c1'),
      ]));
      controller.add(AgentDoneEvent('已批改'));
      await controller.close();
    });
    await tester.pump();
    await tester.pump();

    // 对话流出现纸感批改卡片
    expect(find.byKey(const ValueKey('review_card_c1')), findsOneWidget);
    // 卡片含摘要文案
    expect(find.textContaining('批改'), findsWidgets);
  });
}
