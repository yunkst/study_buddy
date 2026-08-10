import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
