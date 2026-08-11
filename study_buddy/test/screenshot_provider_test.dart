import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  // Task 5：hideOverlay 走轻量 ACTION_HIDE_OVERLAY（保留 FGS），不再 stopService。
  test('hideOverlay 调用原生 hideOverlay method（轻量，不 stopService）', () async {
    await provider.hideOverlay();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'hideOverlay');
  });

  // Task 5：showOverlay 走 ACTION_SHOW_OVERLAY（复位 suppressedByForeground）。
  test('showOverlay 调用原生 showOverlay method（复位前台抑制标志）', () async {
    await provider.showOverlay();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'showOverlay');
  });

  test('hideOverlay 后 showOverlay 各调用一次，按序记录', () async {
    await provider.hideOverlay();
    await provider.showOverlay();
    expect(calls.map((c) => c.method).toList(), ['hideOverlay', 'showOverlay']);
  });

  group('suppressOverlayOnPauseProvider', () {
    test('初值 false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(suppressOverlayOnPauseProvider), false);
    });

    test('set(true) 后读为 true，set(false) 复位', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(suppressOverlayOnPauseProvider.notifier).set(true);
      expect(container.read(suppressOverlayOnPauseProvider), true);
      container.read(suppressOverlayOnPauseProvider.notifier).set(false);
      expect(container.read(suppressOverlayOnPauseProvider), false);
    });
  });
}