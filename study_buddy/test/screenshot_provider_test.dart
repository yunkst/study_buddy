import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/screenshot_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late ScreenshotProvider provider;

  setUp(() {
    calls = [];
    provider = ScreenshotProvider();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('study_buddy/overlay'), (call) async {
      calls.add(call);
      switch (call.method) {
        case 'checkOverlayPermission':
          return true;
        case 'takePendingScreenshot':
          return Uint8List.fromList([1, 2, 3]); // 假 PNG bytes
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('study_buddy/overlay'), null);
  });

  test('checkOverlayPermission 调用原生并返回 bool', () async {
    expect(await provider.checkOverlayPermission(), true);
    expect(calls.single.method, 'checkOverlayPermission');
  });

  test('takePendingScreenshot 返回 CapturedScreenshot，bytes 与 dataUri 对应', () async {
    final shot = await provider.takePendingScreenshot();
    expect(shot, isNotNull);
    expect(shot!.pngBytes, [1, 2, 3]);
    expect(shot.base64DataUri, startsWith('data:image/png;base64,'));
  });

  test('takePendingScreenshot 原生返回 null 时返回 null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('study_buddy/overlay'), (call) async {
      return call.method == 'takePendingScreenshot' ? null : true;
    });
    expect(await provider.takePendingScreenshot(), isNull);
  });
}