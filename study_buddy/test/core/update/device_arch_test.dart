import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/update/device_arch.dart';

void main() {
  group('DeviceArch.apkNameSegment', () {
    test('各架构映射到正确的 APK 文件名片段', () {
      expect(DeviceArch.arm64.apkNameSegment, 'arm64-v8a');
      expect(DeviceArch.arm.apkNameSegment, 'armeabi-v7a');
      expect(DeviceArch.x64.apkNameSegment, 'x86_64');
      expect(DeviceArch.unknown.apkNameSegment, '');
    });
  });
}
