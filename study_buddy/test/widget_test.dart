import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/app.dart';

void main() {
  testWidgets('app 启动并渲染首页', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: StudyBuddyApp()));
    await tester.pump(); // 触发数据库 FutureProvider
    // 至少应出现 AppBar 标题
    expect(find.text('Study Buddy'), findsOneWidget);
  });
}
