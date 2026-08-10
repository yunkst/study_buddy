import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:study_buddy/core/update/app_update_check_exception.dart';
import 'package:study_buddy/core/update/app_update_service.dart';
import 'package:study_buddy/core/update/github_release_service.dart';
import 'package:study_buddy/core/update/models/app_version.dart';
import 'package:study_buddy/core/update/models/github_release.dart';
import 'package:study_buddy/core/update/models/update_check_result.dart';

/// 用子类 stub 网络层
class _FakeGithubReleaseService implements GithubReleaseService {
  final Future<GithubRelease?> Function() _fetchImpl;
  _FakeGithubReleaseService(this._fetchImpl);

  @override
  Future<GithubRelease?> fetchLatestRelease({bool includePrerelease = false}) =>
      _fetchImpl();

  @override
  Future<bool> shouldCheck({bool forceCheck = false}) async => true;
  @override
  Future<void> recordCheckTime() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PackageInfo _fakePackageInfo(String version) => PackageInfo(
      appName: 'study_buddy',
      packageName: 'io.github.yunkst.studybuddy',
      version: version,
      buildNumber: '1',
      buildSignature: '',
      installerStore: null,
    );

Map<String, dynamic> _releaseJson(String tag) => jsonDecode('''
{
  "tag_name": "$tag",
  "name": "$tag",
  "body": "测试 changelog",
  "published_at": "2026-07-01T09:16:35Z",
  "prerelease": false,
  "draft": false,
  "assets": [
    {"name": "app-arm64-v8a-release.apk", "size": 23449107,
     "browser_download_url": "https://example.com/$tag.apk",
     "content_type": "application/vnd.android.package-archive"}
  ]
}
''') as Map<String, dynamic>;

void main() {
  group('checkForUpdateDetailed - 区分「无新版本」与「请求失败」', () {
    test('限流抛异常 → AppUpdateCheckFailed', () async {
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(
          () async => throw const AppUpdateCheckException('GitHub API 限流', cause: 'rate_limited'),
        ),
      );
      final result = await service.checkForUpdateDetailed(forceCheck: true);
      expect(result, isA<AppUpdateCheckFailed>());
      expect((result as AppUpdateCheckFailed).reason, contains('限流'));
    });

    test('无 release → UpToDate', () async {
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(() async => null),
      );
      expect(await service.checkForUpdateDetailed(forceCheck: true), isA<AppUpdateUpToDate>());
    });

    test('有 release（forceCheck）→ AppUpdateAvailable', () async {
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(() async => GithubRelease.fromJson(_releaseJson('v9.9.9'))),
        packageInfoGetter: () async => _fakePackageInfo('0.1.0'),
      );
      final result = await service.checkForUpdateDetailed(forceCheck: true);
      expect(result, isA<AppUpdateAvailable>());
      expect((result as AppUpdateAvailable).version.version, '9.9.9');
    });

    test('release 无 APK → UpToDate', () async {
      final noApk = jsonDecode('''
      {"tag_name":"v9.9.9","name":"v9.9.9","body":"","published_at":"2026-07-01T09:16:35Z",
       "prerelease":false,"draft":false,"assets":[]}
      ''') as Map<String, dynamic>;
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(() async => GithubRelease.fromJson(noApk)),
        packageInfoGetter: () async => _fakePackageInfo('0.1.0'),
      );
      expect(await service.checkForUpdateDetailed(forceCheck: true), isA<AppUpdateUpToDate>());
    });
  });

  group('旧入口 checkForUpdate 向后兼容', () {
    test('限流 → null', () async {
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(
          () async => throw const AppUpdateCheckException('限流', cause: 'rate_limited'),
        ),
      );
      expect(await service.checkForUpdate(forceCheck: true), isNull);
    });

    test('有 release → AppVersion', () async {
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(() async => GithubRelease.fromJson(_releaseJson('v9.9.9'))),
        packageInfoGetter: () async => _fakePackageInfo('0.1.0'),
      );
      final result = await service.checkForUpdate(forceCheck: true);
      expect(result, isA<AppVersion>());
      expect(result!.version, '9.9.9');
    });
  });

  group('双通道', () {
    test('preview 通道接受 prerelease', () async {
      final pre = {..._releaseJson('v2.0.0-preview.1'), 'prerelease': true};
      final service = AppUpdateService(
        githubService: _FakeGithubReleaseService(() async => GithubRelease.fromJson(pre)),
        packageInfoGetter: () async => _fakePackageInfo('0.1.0'),
      );
      final result = await service.checkForUpdateDetailed(forceCheck: true, includePrerelease: true);
      expect(result, isA<AppUpdateAvailable>());
      expect((result as AppUpdateAvailable).version.version, '2.0.0-preview.1');
    });
  });
}
