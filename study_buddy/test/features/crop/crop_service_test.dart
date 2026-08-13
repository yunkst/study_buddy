// crop_service 纯函数单测：解码 / 几何映射 / clampRect / 像素裁剪重编码。
//
// 注意事项：
// - 纯 Dart 函数（mapDisplayRectToPixelRect、clampRect）直接用 test()。
// - 涉及 ui.Image 的异步解码/裁剪走 testWidgets + tester.runAsync()，
//   避免 fake-async zone 卡住 dart:ui 的 real future。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/captured_image.dart';
import 'package:study_buddy/features/crop/crop_service.dart';

/// 用 PictureRecorder 现合成一张纯色带角标的小 PNG，验证裁剪像素正确性。
///
/// 在真实 async zone 跑（tester.runAsync 包裹），dart:ui 的 future 不被 fake。
Future<ui.Image> _makeTestImage({
  required int width,
  required int height,
  required WidgetTester tester,
}) async {
  final image = await tester.runAsync<ui.Image>(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF1E88E5),
    );
    // 左上角画一个红色小方块，用于验证裁剪区域像素。
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 40, 40),
      Paint()..color = const Color(0xFFE53935),
    );
    final picture = recorder.endRecording();
    final raw = await picture.toImage(width, height);
    final byteData = await raw.toByteData(format: ui.ImageByteFormat.png);
    raw.dispose();
    picture.dispose();
    final codec = await ui.instantiateImageCodec(byteData!.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  });
  return image!;
}

Future<ui.Image> _decodeFromBytes(Uint8List bytes, WidgetTester tester) async {
  final image = await tester.runAsync<ui.Image>(() async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  });
  return image!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mapDisplayRectToPixelRect 按比例映射并 clamp', () {
    final mapped = mapDisplayRectToPixelRect(
      displayImageRect: const Rect.fromLTWH(0, 0, 200, 100),
      displayCropRect: const Rect.fromLTWH(10, 5, 80, 30),
      imagePixelSize: const Size(200, 100),
    );
    // 像素/显示 = 1:1，直接平移。
    expect(mapped.left, 10);
    expect(mapped.top, 5);
    expect(mapped.width, 80);
    expect(mapped.height, 30);
  });

  test('mapDisplayRectToPixelRect 支持图片居中留白（displayImageRect 非原点）', () {
    // 竖屏 400x600 里 display 图 300x200 居中于 (50,200)。
    final mapped = mapDisplayRectToPixelRect(
      displayImageRect: const Rect.fromLTWH(50, 200, 300, 200),
      displayCropRect: const Rect.fromLTWH(100, 220, 200, 100),
      imagePixelSize: const Size(3000, 2000),
    );
    // scaleX = 3000/300 = 10, scaleY = 2000/200 = 10。
    // 裁剪相对图左上偏移：(100-50)=50 → 500px；(220-200)=20 → 200px。
    expect(mapped.left, 500);
    expect(mapped.top, 200);
    expect(mapped.width, 2000);
    expect(mapped.height, 1000);
  });

  test('mapDisplayRectToPixelRect 裁剪框越界时与图片矩形求交', () {
    final mapped = mapDisplayRectToPixelRect(
      displayImageRect: const Rect.fromLTWH(0, 0, 200, 100),
      // 裁剪框右/下越界。
      displayCropRect: const Rect.fromLTWH(150, 50, 200, 200),
      imagePixelSize: const Size(400, 200),
    );
    // 求交后 width = 50(显示) → 50*2=100, height=50 → 100。
    expect(mapped.left, 300);
    expect(mapped.top, 100);
    expect(mapped.width, 100);
    expect(mapped.height, 100);
  });

  test('clampRect 保持最小边且不越界', () {
    final bounds = const Rect.fromLTWH(0, 0, 200, 100);
    // 足够大 → 原样（若在界内）。
    final ok = clampRect(
      rect: const Rect.fromLTWH(20, 10, 100, 50),
      bounds: bounds,
      minSide: 48,
    );
    expect(ok, const Rect.fromLTWH(20, 10, 100, 50));

    // 太小 → 撑到 minSide。
    final tiny = clampRect(
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      bounds: bounds,
      minSide: 48,
    );
    expect(tiny.width, 48);
    expect(tiny.height, 48);

    // 越界 → 回缩到界内。
    final overflow = clampRect(
      rect: const Rect.fromLTWH(-30, 0, 120, 100),
      bounds: bounds,
      minSide: 48,
    );
    expect(overflow.left, 0);
    expect(overflow.right, 120); // 120 ≤ 200 界内。
    // 下越界。
    final bottomOverflow = clampRect(
      rect: const Rect.fromLTWH(0, 50, 200, 80),
      bounds: bounds,
    );
    expect(bottomOverflow.bottom, 100);
  });

  testWidgets('decodeSourceImage + cropToPng 端到端：裁剪像素并输出 PNG',
      (tester) async {
    final src = await _makeTestImage(width: 200, height: 100, tester: tester);
    expect(src.width, 200);
    expect(src.height, 100);

    final cropped = await tester.runAsync<CapturedScreenshot>(() {
      return cropToPng(
        source: src,
        srcRect: const Rect.fromLTWH(0, 0, 80, 60),
      );
    });
    expect(cropped, isNotNull);
    expect(cropped!.pngBytes, isNotEmpty);
    expect(cropped.base64DataUri, startsWith('data:image/png;base64,'));
    expect(cropped, isA<CapturedScreenshot>());

    // 解码验证尺寸与像素正确。
    final verify = await _decodeFromBytes(cropped.pngBytes, tester);
    expect(verify.width, 80);
    expect(verify.height, 60);

    // 左上角应是红色（裁剪原点对应源图红块）。
    final dataNullable = await tester.runAsync<ByteData?>(() {
      return verify.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    });
    expect(dataNullable, isNotNull);
    final data = dataNullable!;
    final r = data.getUint8(0);
    final g = data.getUint8(1);
    final b = data.getUint8(2);
    // E53935 → r=229,g=57,b=53。
    expect(r, greaterThan(200));
    expect(g, lessThan(120));
    expect(b, lessThan(120));

    verify.dispose();
    src.dispose();
  });

  testWidgets('cropToPng 对非法裁剪区抛 ArgumentError', (tester) async {
    final src = await _makeTestImage(width: 100, height: 100, tester: tester);
    Object? caught;
    // cropToPng 抛 ArgumentError 的检查在函数最开头（同步路径），无需走
    // dart:ui real-async。直接在 fake zone 调，异常作为 Future rejection
    // 透传到 try/catch。
    try {
      await cropToPng(
        source: src,
        srcRect: const Rect.fromLTWH(200, 200, 10, 10), // 完全越界
      );
    } catch (e) {
      caught = e;
    }
    expect(caught, isArgumentError);
    src.dispose();
  });

  testWidgets('downsampleToRgba 等比降采样到长边 maxSide', (tester) async {
    final src = await _makeTestImage(width: 200, height: 100, tester: tester);
    final out = await tester.runAsync(
      () => downsampleToRgba(source: src, maxSide: 50),
    );
    // 长边 50，原图 200×100 → 缩放 0.25 → 50×25。
    expect(out!.width, 50);
    expect(out.height, 25);
    expect(out.rgba.length, 50 * 25 * 4);
    src.dispose();
  });

  testWidgets('downsampleToRgba 对小图不放大（长边已 < maxSide）', (tester) async {
    final src = await _makeTestImage(width: 40, height: 30, tester: tester);
    final out = await tester.runAsync(
      () => downsampleToRgba(source: src, maxSide: 320),
    );
    // 原图长边 40 < 320，scale 被 cap 到 1.0，维持原尺寸不放大。
    expect(out!.width, 40);
    expect(out.height, 30);
    expect(out.rgba.length, out.width * out.height * 4);
    src.dispose();
  });
}