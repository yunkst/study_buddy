import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
// image_picker_platform_interface 是 image_picker 的传递依赖：
// 我们直接 import 它来 mock ImagePickerPlatform.instance（无需在 pubspec 中声明）。
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;
import 'package:study_buddy/core/providers/image_pick_provider.dart';

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

  test('用户取消返回 null', () async {
    fake.returnValue = null;
    expect(await pickImageForAi(fromCamera: true), isNull);
  });

  test('pickImage 抛异常返回 null', () async {
    fake.throwOnPick = Exception('image_picker_canceled');
    expect(await pickImageForAi(fromCamera: false), isNull);
  });
}
