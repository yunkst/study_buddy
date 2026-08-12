import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/app.dart';

void main() {
  testWidgets('app 启动并渲染 3-Tab shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: StudyBuddyApp(showOnboarding: false)));
    await tester.pump(); // 触发数据库 FutureProvider
    // 3.1 起落地页为 /today 的 StatefulShellRoute：出现底部 NavigationBar 即 shell 启动成功。
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
