// ImageCropPage widget 测试：装配 / 默认全屏裁剪框 / 取消 pop null。
//
// 注意事项：
// - 图片字节合成（ui.PictureRecorder）走 tester.runAsync 让 dart:ui 的 future
//   真实跑完，再回到 fake zone 装载 widget 并 pump 触发 ImageCropPage 的解码。
// - ImageCropPage 内部调 ui.instantiateImageCodec，需 tester.runAsync 包住装载阶段。
//
// 参考范式：test/features/settings/settings_page_test.dart:29-44 用 ProviderContainer
// 配合 runAsync + pumpAndSettle。本测试更简单（不依赖 Provider/DB）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/captured_image.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/crop/image_crop_page.dart';

/// 在真实 async zone 合成测试 PNG（dart:ui 的 future 不能在 fake zone 完成）。
Future<Uint8List> _buildTestPng({
  required int width,
  required int height,
  required WidgetTester tester,
}) async {
  final bytes = await tester.runAsync<Uint8List>(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF1E88E5),
    );
    final picture = recorder.endRecording();
    final img = await picture.toImage(width, height);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// 把 ImageCropPage 装载并推进到「解码完成 + setState 已触发」状态。
///
/// ImageCropPage._load 走 ui.instantiateImageCodec 是 real-async，fake zone 不会推进。
/// 测试里：
///   1. pumpWidget 触发 initState（同步发起 _load，Future 挂起在 fake zone）；
///   2. tester.runAsync 在 real zone 里**真的跑**那个 Future 到完成 → setState 入队；
///   3. 回到 fake zone，pump 触发 setState 重建。
Future<void> _pumpCropPage(
  WidgetTester tester,
  Uint8List bytes,
) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: ImageCropPage(sourceBytes: bytes),
  ));
  // 给 real-async 解码 600ms 足够 ui.instantiateImageCodec + toImage 完成。
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
  });
  // 回到 fake zone 推进 setState 重建（不用 pumpAndSettle，避免 widget 内部
  // pending microtask 造成假死；这里只关心"解码完成 → setState → rebuild"）。
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ImageCropPage 渲染 AppBar + 取消/确认按钮 + 加载图片',
      (tester) async {
    final bytes = await _buildTestPng(
      width: 200,
      height: 100,
      tester: tester,
    );
    await _pumpCropPage(tester, bytes);

    expect(find.text('框选题目区域'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认裁剪'), findsOneWidget);
    // ImageCropPage 至少有一个 CustomPaint（裁剪框 painter）。
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('ImageCropPage 点取消 pop(null)', (tester) async {
    final bytes = await _buildTestPng(
      width: 200,
      height: 100,
      tester: tester,
    );
    CapturedScreenshot? result;

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await Navigator.of(ctx).push<CapturedScreenshot>(
              MaterialPageRoute(
                builder: (_) => ImageCropPage(sourceBytes: bytes),
              ),
            );
          },
          child: const Text('go'),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    // 让 push 切换 + ImageCropPage 解码完成（real-async）。
    await tester.pump(); // 让 push 的 builder 跑完 → ImageCropPage 创建。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(); // 让 setState 重建跑完。

    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    // pop 后推进一帧让 onPressed await resolve。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(result, isNull);
  });
}