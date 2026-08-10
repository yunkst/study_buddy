import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/topic_chat_sheet.dart';
import 'package:study_engine/study_engine.dart';

/// 假会话仓库：记录写入。
class FakeChatRepository implements ChatRepository {
  final List<ChatMessage> persisted = [];
  int _nextId = 100;
  int sessionId = 42;
  @override
  Future<int> createSession(String scenarioId, String title, {int? topicId}) async => _nextId++;
  @override
  Future<int> findOrCreateByTopic(int topicId, String title) async => sessionId;
  @override
  Future<int> addMessage(int sessionId, ChatMessage m) async {
    persisted.add(m);
    return 1;
  }
  @override
  Future<List<ChatMessage>> listMessages(int sessionId) async => [
        ChatMessage(role: 'assistant', content: '历史上的回答'),
      ];
}

/// 假 Agent 会话：run() 立即发一回合 TextDelta + Done，不触 DB/LLM。
class FakeAgentSession extends AgentSession {
  FakeAgentSession(super.ref);
  @override
  Future<Stream<AgentEvent>> run(
    List<ChatMessage> messages, {
    AgentScenarioContext? context,
  }) async {
    return Stream.fromIterable([
      TextDeltaEvent('回答'),
      AgentDoneEvent('回答'),
    ]);
  }
}

void main() {
  testWidgets('抽屉打开加载历史 + 显示标题', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [chatRepositoryProvider.overrideWith((ref) async => FakeChatRepository())],
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) => Center(
        child: FilledButton(
          onPressed: () => showTopicChat(ctx, topicId: 1, title: 'ε-δ极限定义'),
          child: const Text('打开'),
        ),
      )))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('ε-δ极限定义'), findsWidgets); // 标题条
    expect(find.text('历史上的回答'), findsOneWidget); // 历史气泡
  });

  testWidgets('发送一轮：AgentDone 后 user+assistant 落库', (tester) async {
    final fakeRepo = FakeChatRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWith((ref) async => fakeRepo),
        agentSessionProvider.overrideWith((ref) => FakeAgentSession(ref)),
        topicDetailProvider(1).overrideWith((ref) async => TopicDetail(
              topic: Topic(
                id: 1,
                categoryId: 10,
                question: '什么是极限',
                title: 'ε-δ极限定义',
                summary: '答案正文',
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
              ),
              path: const ['数学', '微积分'],
              edges: const [],
            )),
      ],
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) => Center(
        child: FilledButton(
          onPressed: () => showTopicChat(ctx, topicId: 1, title: 'ε-δ极限定义'),
          child: const Text('打开'),
        ),
      )))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 输入并发送
    await tester.enterText(find.byType(TextField), '继续追问');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    // 断言：user + assistant 两条 addMessage 调用
    expect(fakeRepo.persisted.length, 2);
    expect(fakeRepo.persisted[0].role, 'user');
    expect(fakeRepo.persisted[0].content, '继续追问');
    expect(fakeRepo.persisted[1].role, 'assistant');
    expect(fakeRepo.persisted[1].content, '回答');
  });
}
