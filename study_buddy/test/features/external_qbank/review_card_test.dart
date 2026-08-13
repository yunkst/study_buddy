import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/captured_image.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/external_qbank/ai_panel_sheet.dart';
import 'package:study_engine/study_engine.dart';

/// 可控假 AgentSession:stream 由外部 StreamController 驱动(同 ai_panel_sheet_test 模式)。
class _ControllableAgentSession extends AgentSession {
  _ControllableAgentSession(super.ref, this._controller);
  final StreamController<AgentEvent> _controller;
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today}) async {
    return AgentSessionHandle(stream: _controller.stream);
  }
}

Uint8List _pngBytes() => Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC'));

/// 装配 helper：注入 GoRouter（包含 /、/ai、/crop）+ AppTheme.light。
/// 与 ai_panel_sheet_test.pumpPanel 同构（这里不需要 crop，但保留 /ai 点 open → 推对话页）。
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
    ],
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router, theme: AppTheme.light),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('save_review 工具完成后,对话流出现批改卡片', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _ControllableAgentSession(ref, controller)),
    ]);
    addTearDown(container.dispose);

    await pumpPanel(tester, container: container, screenshot: screenshot);
    await tester.tap(find.byTooltip('发送'));
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

  testWidgets('详情页渲染逐题明细', (tester) async {
    // 预存一条 review 的内存假 repo
    final review = Review(
      id: 7,
      chatSessionId: null,
      summary: '批改3题,对1错2',
      items: [
        ReviewItem(
          seq: 1,
          question: '求 lim(x→0) sin x / x',
          userAnswer: '0',
          verdict: 'wrong',
          analysis: '应为 1',
          topicIds: const [12],
        ),
      ],
      createdAt: DateTime(2026),
    );
    final fakeRepo = _FakeReviewRepository({7: review});

    final container = ProviderContainer(overrides: [
      reviewRepositoryProvider.overrideWith((ref) async => fakeRepo),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ReviewDetailPage(reviewId: 7)),
    ));
    await tester.pumpAndSettle();

    // 摘要可见
    expect(find.textContaining('批改3题'), findsOneWidget);
    // 逐题 question 可见
    expect(find.textContaining('求 lim'), findsOneWidget);
    // 错题徽标(wrong → 朱砂✗)
    expect(find.text('✗'), findsOneWidget);
  });

  testWidgets('详情页输入框发消息走同一 chat session', (tester) async {
    // 详情页底部输入 → 调 currentChatProvider.send → messages 追加 user
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final fakeRepo = _FakeReviewRepository({
      7: Review(
        id: 7,
        chatSessionId: null,
        summary: 's',
        items: const [],
        createdAt: DateTime(2026),
      ),
    });
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _ControllableAgentSession(ref, controller)),
      reviewRepositoryProvider.overrideWith((ref) async => fakeRepo),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ReviewDetailPage(reviewId: 7)),
    ));
    await tester.pumpAndSettle();

    // 输入并提交
    await tester.enterText(find.byType(TextField), '第1题为什么错');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // currentChatProvider 的 messages 多了一条 user 消息
    final state = container.read(currentChatProvider);
    expect(state.messages.any((m) => m.role == 'user'), isTrue);
  });
}

/// 内存假 ReviewRepository,详情页测试用。
class _FakeReviewRepository implements ReviewRepository {
  _FakeReviewRepository(this._store);
  final Map<int, Review> _store;
  @override
  Future<int> save({
    int? chatSessionId,
    required String summary,
    required List<ReviewItem> items,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Review?> findById(int id) async => _store[id];

  @override
  Future<List<Review>> findBySession(int chatSessionId) async => const [];
}
