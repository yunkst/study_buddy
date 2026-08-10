import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/topic_detail_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  final topic = Topic(
    id: 1,
    categoryId: 10,
    question: '什么是韦达定理？',
    title: '韦达定理',
    summary: '一元二次方程根与系数的关系',
    createdAt: DateTime(2026, 8, 10),
    updatedAt: DateTime(2026, 8, 10),
  );

  testWidgets('详情渲染引子/答案/路径/关联边', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topicDetailProvider.overrideWith(
            (ref, arg) async => TopicDetail(
              topic: topic,
              path: const ['数学', '代数'],
              edges: [
                TopicEdgeView('prerequisite', 2, '一元二次方程'),
                TopicEdgeView('related', 3, '根与系数'),
              ],
            ),
          ),
        ],
        child: const MaterialApp(home: TopicDetailPage(topicId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('韦达定理'), findsWidgets);
    expect(find.text('什么是韦达定理？'), findsOneWidget);
    expect(find.text('一元二次方程根与系数的关系'), findsOneWidget);
    expect(find.text('数学 / 代数'), findsOneWidget);
    expect(find.text('一元二次方程'), findsOneWidget); // 关联边对端
  });

  testWidgets('无关联边时隐藏关联区块', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topicDetailProvider.overrideWith(
            (ref, arg) async => TopicDetail(topic: topic, path: const ['数学'], edges: const []),
          ),
        ],
        child: const MaterialApp(home: TopicDetailPage(topicId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('🔗 关联'), findsNothing);
  });

  testWidgets('详情页有「问 AI」按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topicDetailProvider.overrideWith(
            (ref, arg) async => TopicDetail(topic: topic, path: const ['数学'], edges: const []),
          ),
        ],
        child: const MaterialApp(home: TopicDetailPage(topicId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('问 AI'), findsOneWidget);
  });
}
