import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:image_picker/image_picker.dart';
// image_picker_platform_interface 是 image_picker 的传递依赖：
// 我们直接 import 它来 mock ImagePickerPlatform.instance（无需在 pubspec 中声明）。
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;
import 'package:study_buddy/core/providers/image_pick_provider.dart';

/// 构造一张 2x1 深色实色 JPEG bytes，并按需写入 EXIF orientation 值。
///
/// 用 image 包直接生成测试图，避免依赖真实相机文件。宽≠高，便于断言 90° 旋转。
Uint8List _jpegWithOrientation(int? orientation) {
  final img = im.Image(width: 2, height: 1);
  if (orientation != null) {
    img.exif.imageIfd.orientation = orientation;
  }
  return im.encodeJpg(img, quality: 90);
}

/// 假 platform：可控地返回预设 XFile 或抛异常，驱动 pickImage 走不同分支。
class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? returnValue;
  Object? throwOnPick;

  @override
  Future<XFile?> getImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (throwOnPick != null) throw throwOnPick!;
    return returnValue;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeImagePickerPlatform fake;
  late ImagePickerPlatform original;

  setUp(() {
    original = ImagePickerPlatform.instance;
    fake = _FakeImagePickerPlatform();
    ImagePickerPlatform.instance = fake;
  });
  tearDown(() => ImagePickerPlatform.instance = original);

  test('JPEG: dataUri MIME 为 image/jpeg', () async {
    fake.returnValue = XFile.fromData(
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]),
      mimeType: 'image/jpeg',
      name: 'photo.jpg',
    );
    final shot = await pickImageForAi(fromCamera: false);
    expect(shot, isNotNull);
    expect(shot!.base64DataUri, startsWith('data:image/jpeg;base64,'));
    expect(shot.pngBytes, isNotEmpty);
  });

  test('PNG: dataUri MIME 为 image/png', () async {
    fake.returnValue = XFile.fromData(
      Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]),
      mimeType: 'image/png',
      name: 'photo.png',
    );
    final shot = await pickImageForAi(fromCamera: false);
    expect(shot, isNotNull);
    expect(shot!.base64DataUri, startsWith('data:image/png;base64,'));
    expect(shot.pngBytes, isNotEmpty);
  });

  test('横屏 JPEG（EXIF orientation=6）被旋正：宽高互换且 orientation 清空', () async {
    // 2x1 + orientation=6（顺时针 90°）→ 校正后应为 1x2
    fake.returnValue = XFile.fromData(
      _jpegWithOrientation(6),
      mimeType: 'image/jpeg',
      name: 'landscape.jpg',
    );
    final shot = await pickImageForAi(fromCamera: true);
    expect(shot, isNotNull);
    final decoded = im.decodeJpg(shot!.pngBytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 1);
    expect(decoded.height, 2);
    // 校正会清掉 EXIF orientation tag，下游不会再误读
    expect(decoded.exif.imageIfd.hasOrientation, isFalse);
  });

  test('无 EXIF orientation 的 JPEG 不被改动（幂等）', () async {
    final src = _jpegWithOrientation(null); // 2x1，无 orientation tag
    fake.returnValue = XFile.fromData(
      src,
      mimeType: 'image/jpeg',
      name: 'no-exif.jpg',
    );
    final shot = await pickImageForAi(fromCamera: false);
    expect(shot, isNotNull);
    final decoded = im.decodeJpg(shot!.pngBytes);
    expect(decoded, isNotNull);
    // 幂等：orientation=1/无 tag → bakeOrientation no-op，尺寸不变
    expect(decoded!.width, 2);
    expect(decoded.height, 1);
    expect(decoded.exif.imageIfd.hasOrientation, isFalse);
  });

  test('PNG 不走方向校正，bytes 原样保留', () async {
    final pngBytes = im.encodePng(im.Image(width: 3, height: 2));
    fake.returnValue = XFile.fromData(
      pngBytes,
      mimeType: 'image/png',
      name: 'photo.png',
    );
    final shot = await pickImageForAi(fromCamera: false);
    expect(shot, isNotNull);
    // PNG 早退：pngBytes 原样回流（不含 JPEG 重编码开销）
    expect(shot!.pngBytes, pngBytes);
  });

  test('用户取消返回 null', () async {
    fake.returnValue = null;
    expect(await pickImageForAi(fromCamera: true), isNull);
  });

  test('pickImage 抛异常返回 null', () async {
    fake.throwOnPick = Exception('image_picker_canceled');
    expect(await pickImageForAi(fromCamera: false), isNull);
  });
}
