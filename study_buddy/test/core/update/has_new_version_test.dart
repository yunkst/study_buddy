import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/update/app_update_service.dart';

void main() {
  final service = AppUpdateService();

  group('hasNewVersion - 纯数字版本', () {
    test('主/次/修订号更大 → 有新版本', () {
      expect(service.hasNewVersion('1.0.0', '2.0.0'), isTrue);
      expect(service.hasNewVersion('1.0.0', '1.1.0'), isTrue);
      expect(service.hasNewVersion('1.0.0', '1.0.1'), isTrue);
    });
    test('相同/当前更新 → 无新版本', () {
      expect(service.hasNewVersion('1.0.0', '1.0.0'), isFalse);
      expect(service.hasNewVersion('2.0.0', '1.0.0'), isFalse);
    });
    test('位数补齐（1.0 == 1.0.0）', () {
      expect(service.hasNewVersion('1.0', '1.0.0'), isFalse);
      expect(service.hasNewVersion('1.0', '1.0.1'), isTrue);
    });
  });

  group('hasNewVersion - prerelease 版本（study_buddy 核心）', () {
    test('preview.N 递增 → 有新版本', () {
      expect(service.hasNewVersion('0.1.0-preview.2', '0.1.0-preview.3'), isTrue);
    });
    test('相同 preview → 无新版本', () {
      expect(service.hasNewVersion('0.1.0-preview.2', '0.1.0-preview.2'), isFalse);
    });
    test('同 core 下 stable 新于 preview', () {
      expect(service.hasNewVersion('0.1.0-preview.2', '0.1.0'), isTrue);
      expect(service.hasNewVersion('0.1.0', '0.1.0-preview.2'), isFalse);
    });
    test('core 更大时忽略 prerelease 直接判定', () {
      expect(service.hasNewVersion('0.1.0-preview.5', '0.2.0-preview.1'), isTrue);
      expect(service.hasNewVersion('0.2.0-preview.1', '0.1.0-preview.5'), isFalse);
    });
  });

  group('hasNewVersion - 非法输入不抛异常', () {
    test('空串/非法 → false', () {
      expect(service.hasNewVersion('1.0.0', ''), isFalse);
      expect(service.hasNewVersion('1.0.0', 'invalid'), isFalse);
      expect(service.hasNewVersion('', '1.0.0'), isFalse);
    });
  });
}
