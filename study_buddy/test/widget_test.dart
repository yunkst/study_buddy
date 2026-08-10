import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/app.dart';

void main() {
  testWidgets('app 启动并渲染三 Tab 导航', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: StudyBuddyApp()));
    await tester.pump();
    // MainShell 同步渲染 NavigationBar（不依赖 DB 就绪）。
    // 注意：占位页 body 与 Tab label 同名的文本会有多个，只断言 NavigationBar。
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
