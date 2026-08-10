import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/update/models/app_version.dart';
import 'package:study_buddy/core/update/models/github_release.dart';

Map<String, dynamic> _releaseJson(String tag, {List<Map<String, dynamic>>? assets}) => {
      'tag_name': tag,
      'name': tag,
      'body': 'body',
      'published_at': '2026-08-01T00:00:00Z',
      'prerelease': false,
      'draft': false,
      'assets': assets ?? [],
    };

Map<String, dynamic> _apkAsset(String name) => {
      'name': name,
      'size': 1024,
      'browser_download_url': 'https://example.com/$name',
      'content_type': 'application/vnd.android.package-archive',
    };

void main() {
  group('GithubRelease', () {
    test('fromJson 解析字段', () {
      final r = GithubRelease.fromJson(_releaseJson('v0.2.0'));
      expect(r.tagName, 'v0.2.0');
      expect(r.prerelease, isFalse);
      expect(r.versionNumber, '0.2.0');
    });

    test('apkAssetFor 按架构精确匹配', () {
      final r = GithubRelease.fromJson(_releaseJson('v0.2.0', assets: [
        _apkAsset('app-arm64-v8a-release.apk'),
        _apkAsset('app-armeabi-v7a-release.apk'),
      ]));
      expect(r.apkAssetFor('arm64-v8a')!.name, 'app-arm64-v8a-release.apk');
      expect(r.apkAssetFor('armeabi-v7a')!.name, 'app-armeabi-v7a-release.apk');
    });

    test('apkAssetFor 无匹配架构时兜底通用 fat APK', () {
      final r = GithubRelease.fromJson(_releaseJson('v0.2.0', assets: [
        _apkAsset('app-release.apk'),
      ]));
      expect(r.apkAssetFor('arm64-v8a')!.name, 'app-release.apk');
    });

    test('apkAssetFor 无任何 APK 返回 null', () {
      final r = GithubRelease.fromJson(_releaseJson('v0.2.0'));
      expect(r.apkAssetFor('arm64-v8a'), isNull);
    });
  });

  group('AppVersion', () {
    test('fileSizeFormatted 分级格式化', () {
      expect(AppVersion(version: '1', downloadUrl: '', fileSize: 512, createdAt: '')
          .fileSizeFormatted, '512 B');
      expect(AppVersion(version: '1', downloadUrl: '', fileSize: 2048, createdAt: '')
          .fileSizeFormatted, '2.0 KB');
      expect(AppVersion(version: '1', downloadUrl: '', fileSize: 1048576, createdAt: '')
          .fileSizeFormatted, '1.0 MB');
    });
  });
}
