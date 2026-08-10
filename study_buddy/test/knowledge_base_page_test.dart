import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/knowledge_base_page.dart';

void main() {
  // 根级（parentId=null）：返回「数学」分类 + 直挂「韦达定理」知识点
  const rootChildren = <CategoryChild>[
    CategoryChild(isCategory: true, id: 1, name: '数学', hasChildren: true),
    CategoryChild(isCategory: false, id: 11, name: '韦达定理'),
  ];
  // 数学层（parentId=1）：返回「高等数学」分类
  const mathChildren = <CategoryChild>[
    CategoryChild(isCategory: true, id: 2, name: '高等数学', hasChildren: true),
  ];
  // 高等数学层（parentId=2）：返回「极限」知识点
  const higherMathChildren = <CategoryChild>[
    CategoryChild(isCategory: false, id: 12, name: '极限'),
  ];

  // 按 parentId 返回不同数据，模拟逐级下钻
  List<CategoryChild> childrenFor(int? parentId) {
    if (parentId == null) return rootChildren;
    if (parentId == 1) return mathChildren;
    if (parentId == 2) return higherMathChildren;
    return const [];
  }

  Widget build() => ProviderScope(
        overrides: [
          categoryChildrenProvider.overrideWith(
            (ref, arg) async => childrenFor(arg),
          ),
        ],
        child: const MaterialApp(home: KnowledgeBasePage()),
      );

  testWidgets('浏览视图渲染分类与知识点混排', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('韦达定理'), findsOneWidget);
  });

  testWidgets('下钻两层后点中间段面包屑回到正确层级（off-by-one 回归）',
      (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // 下钻：点列表「数学」→ 数学层（面包屑：[全部][数学]）
    await tester.tap(find.widgetWithText(ListTile, '数学'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '高等数学'), findsOneWidget);

    // 下钻：点列表「高等数学」→ 高等数学层（面包屑：[全部][数学][高等数学]）
    await tester.tap(find.widgetWithText(ListTile, '高等数学'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '极限'), findsOneWidget);

    // 点中间段面包屑「数学」（TextButton）——应回到数学层（展示「高等数学」），
    // 而非 off-by-one 弹回根级（根级展示「数学」+「韦达定理」）
    await tester.tap(find.widgetWithText(TextButton, '数学'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '高等数学'), findsOneWidget,
        reason: '点面包屑「数学」应回到数学层，展示其子分类「高等数学」');
    expect(find.widgetWithText(ListTile, '韦达定理'), findsNothing,
        reason: '不应弹回根级');

    // 再下钻到高等数学层，测末段 inert
    await tester.tap(find.widgetWithText(ListTile, '高等数学'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '极限'), findsOneWidget);

    // 点末段面包屑「高等数学」应 inert（当前已是该层，列表不变）
    // 末段 onPressed 调 _goToDepth(i+1)，i=1 → _goToDepth(2) → path 截到长度 2（不变）
    await tester.tap(find.widgetWithText(TextButton, '高等数学'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '极限'), findsOneWidget,
        reason: '点末段应 inert，列表不变');
    expect(find.widgetWithText(ListTile, '高等数学'), findsNothing,
        reason: '末段不应回退到上层');
  });
}
