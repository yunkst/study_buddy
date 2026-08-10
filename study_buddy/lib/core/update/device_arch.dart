import 'dart:developer';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// 设备 CPU 架构枚举（用于选取对应架构的 split APK）
enum DeviceArch {
  /// ARM 64-bit（现代 Android 主流）
  arm64,
  /// ARM 32-bit（老旧设备）
  arm,
  /// x86 64-bit（模拟器 / ChromeOS）
  x64,
  /// 未知（非 Android 或检测失败）
  unknown,
}

extension DeviceArchName on DeviceArch {
  /// APK 文件名中的架构标识片段，对应 `--split-per-abi` 产物
  String get apkNameSegment {
    switch (this) {
      case DeviceArch.arm64:
        return 'arm64-v8a';
      case DeviceArch.arm:
        return 'armeabi-v7a';
      case DeviceArch.x64:
        return 'x86_64';
      case DeviceArch.unknown:
        return '';
    }
  }
}

/// 设备架构检测器：通过 Android Build.SUPPORTED_ABIS 按优先级返回最优架构
class DeviceArchDetector {
  DeviceArchDetector._();

  /// 获取当前设备 CPU 架构，非 Android 返回 unknown
  static Future<DeviceArch> getCurrent() async {
    if (!Platform.isAndroid) {
      return DeviceArch.unknown;
    }
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final abis = info.supportedAbis;
      if (abis.contains('arm64-v8a')) return DeviceArch.arm64;
      if (abis.contains('x86_64')) return DeviceArch.x64;
      if (abis.contains('armeabi-v7a')) return DeviceArch.arm;
      log('未识别的设备 ABI: $abis，将使用通用 APK', name: 'app_update');
      return DeviceArch.unknown;
    } catch (e) {
      log('获取设备架构失败: $e', name: 'app_update');
      return DeviceArch.unknown;
    }
  }
}
