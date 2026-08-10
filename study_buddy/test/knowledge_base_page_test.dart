import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/knowledge_base_page.dart';

void main() {
  testWidgets('浏览视图渲染分类与知识点混排', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryChildrenProvider.overrideWith(
            (ref, arg) async => const [
              CategoryChild(isCategory: true, id: 1, name: '数学', hasChildren: true),
              CategoryChild(isCategory: false, id: 11, name: '韦达定理'),
            ],
          ),
        ],
        child: const MaterialApp(home: KnowledgeBasePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('韦达定理'), findsOneWidget);
  });
}
