import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/focus_session_provider.dart';
import 'package:study_buddy/features/focus/focus_page.dart';

void main() {
  testWidgets('idle 态显示开始按钮', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    expect(find.text('开始专注'), findsOneWidget);
    expect(find.text('结束专注'), findsNothing);
  });

  testWidgets('running 态显示结束按钮与计时', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) =>
          _FakeNotifier(ref, state: const FocusSessionState(
            sessionId: 1, running: true, elapsed: Duration(minutes: 5, seconds: 3),
          ))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    expect(find.text('结束专注'), findsOneWidget);
    expect(find.text('开始专注'), findsNothing);
    expect(find.text('00:05:03'), findsOneWidget);
  });

  testWidgets('点开始按钮调用 start', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    await tester.tap(find.text('开始专注'));
    await tester.pump();
    final notifier = container.read(focusSessionProvider.notifier) as _FakeNotifier;
    expect(notifier.startCalled, isTrue);
  });
}

class _FakeNotifier extends FocusSessionNotifier {
  _FakeNotifier(super.ref, {FocusSessionState? state}) {
    if (state != null) this.state = state;
  }
  bool startCalled = false;
  @override
  Future<void> start() async { startCalled = true; }
  @override
  Future<void> stop() async {}
}
