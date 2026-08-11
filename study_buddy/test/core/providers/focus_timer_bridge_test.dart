import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/focus_timer_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('study_buddy/focus');
  late List<MethodCall> calls;
  late FocusTimerBridge bridge;

  setUp(() {
    calls = [];
    bridge = FocusTimerBridge();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'isRunning') return false;
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start 调用原生 start 并传 sessionId', () async {
    await bridge.start(42);
    expect(calls, hasLength(1));
    expect(calls.first.method, 'start');
    expect(calls.first.arguments, 42);
  });

  test('stop 调用原生 stop', () async {
    await bridge.stop();
    expect(calls.single.method, 'stop');
  });

  test('isRunning 返回原生布尔值', () async {
    final running = await bridge.isRunning();
    expect(running, isFalse);
  });

  test('setOnStopped 注册的回调在原生反向调用 onStopped 时触发', () async {
    var stopped = false;
    bridge.setOnStopped(() => stopped = true);
    // 模拟原生反向调用 Flutter（用 TestDefaultBinaryMessengerBinding 避免 deprecated 警告）
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('onStopped')),
      (data) {},
    );
    expect(stopped, isTrue);
  });
}
