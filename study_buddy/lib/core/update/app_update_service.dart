import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/logger_service.dart';
import 'app_update_check_exception.dart';
import 'device_arch.dart';
import 'github_release_service.dart';
import 'models/app_version.dart';
import 'models/update_check_result.dart';

/// APP 更新编排服务：通过 GitHub Releases 检查版本、下载并安装 APK
class AppUpdateService {
  static const String _ignoreVersionKey = 'app_update_ignore_version';
  static const String _previewChannelKey = 'app_update_preview_channel';
  static const _platformChannel =
      MethodChannel('io.github.yunkst.studybuddy/app_install');

  final GithubReleaseService _githubService;
  final Future<PackageInfo> Function()? _packageInfoGetter;

  AppUpdateService({
    GithubReleaseService? githubService,
    Future<PackageInfo> Function()? packageInfoGetter,
  })  : _githubService = githubService ?? GithubReleaseService(),
        _packageInfoGetter = packageInfoGetter;

  /// 获取当前 APP 版本信息
  Future<PackageInfo> getCurrentVersion() async {
    if (_packageInfoGetter != null) return await _packageInfoGetter();
    return await PackageInfo.fromPlatform();
  }

  /// 检查更新（详细结果，区分「无新版本」与「请求失败」）
  Future<AppUpdateResult> checkForUpdateDetailed({
    bool forceCheck = false,
    bool includePrerelease = false,
  }) async {
    try {
      if (!await _githubService.shouldCheck(forceCheck: forceCheck)) {
        return const AppUpdateUpToDate();
      }
      await _githubService.recordCheckTime();

      final release = await _githubService.fetchLatestRelease(
        includePrerelease: includePrerelease,
      );
      if (release == null) return const AppUpdateUpToDate();

      final arch = await DeviceArchDetector.getCurrent();
      final asset = release.apkAssetFor(arch.apkNameSegment);
      if (asset == null) return const AppUpdateUpToDate();

      final appVersion = AppVersion(
        version: release.versionNumber,
        downloadUrl: asset.browserDownloadUrl,
        fileSize: asset.size,
        changelog: _extractChangelog(release.body),
        createdAt: release.publishedAt,
      );

      final currentInfo = await getCurrentVersion();
      final hasNew = hasNewVersion(currentInfo.version, appVersion.version);
      LoggerService.instance.i('版本比较: ${currentInfo.version} vs ${appVersion.version}, hasNew: $hasNew',
          category: LogCategory.general, tags: const ['app_update']);

      // 强制检查或有新版本都返回 Available（调用方按需提示）
      if (forceCheck || hasNew) {
        return AppUpdateAvailable(appVersion);
      }
      return const AppUpdateUpToDate();
    } on AppUpdateCheckException catch (e) {
      return AppUpdateCheckFailed(e.message);
    } catch (e) {
      LoggerService.instance.e('检查更新失败: $e',
          category: LogCategory.general, tags: const ['app_update']);
      return const AppUpdateCheckFailed('检查更新失败，请稍后重试');
    }
  }

  /// 检查更新（向后兼容入口）：Available→返回 AppVersion，其余→null
  Future<AppVersion?> checkForUpdate({
    bool forceCheck = false,
    bool includePrerelease = false,
  }) async {
    final result = await checkForUpdateDetailed(
      forceCheck: forceCheck,
      includePrerelease: includePrerelease,
    );
    if (result is AppUpdateAvailable) return result.version;
    return null;
  }

  /// 版本号比较：返回 true 表示 latest 比 current 新
  ///
  /// 支持 semver prerelease 后缀（study_buddy 用 `0.1.0-preview.N`）：
  /// core 相同时，stable（无后缀）> prerelease（有后缀）；同为 prerelease 时比后缀中的数字。
  bool hasNewVersion(String current, String latest) {
    try {
      return _compareVersions(current, latest) < 0;
    } catch (e) {
      LoggerService.instance.w('版本号比较失败: $e',
          category: LogCategory.general, tags: const ['app_update']);
      return false;
    }
  }

  /// 语义化版本比较：返回负数表示 a 小于 b，`0` 相等，正数表示 a 大于 b
  int _compareVersions(String a, String b) {
    final pa = _parseSemver(a);
    final pb = _parseSemver(b);
    for (var i = 0; i < 3; i++) {
      if (pa.nums[i] != pb.nums[i]) return pa.nums[i].compareTo(pb.nums[i]);
    }
    // core 相同：stable（pre==null）> prerelease
    if (pa.pre == null && pb.pre == null) return 0;
    if (pa.pre == null) return 1;
    if (pb.pre == null) return -1;
    return _comparePre(pa.pre!, pb.pre!);
  }

  /// 解析 `X.Y.Z[-pre]` → (3 位数字, prerelease 后缀?)
  _Semver _parseSemver(String v) {
    final dashIdx = v.indexOf('-');
    final core = dashIdx >= 0 ? v.substring(0, dashIdx) : v;
    final pre = dashIdx >= 0 ? v.substring(dashIdx + 1) : null;
    final parts = core.split('.').map(int.parse).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return _Semver(parts.sublist(0, 3), pre);
  }

  /// 比较两个 prerelease 后缀：优先比末尾 `.N` 数字，否则字符串比较
  int _comparePre(String a, String b) {
    final an = _trailingInt(a);
    final bn = _trailingInt(b);
    if (an != null && bn != null) return an.compareTo(bn);
    return a.compareTo(b);
  }

  int? _trailingInt(String s) {
    final idx = s.lastIndexOf('.');
    if (idx < 0) return null;
    return int.tryParse(s.substring(idx + 1));
  }

  /// 请求安装权限（Android 8+）
  Future<bool> requestInstallPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.requestInstallPackages.request();
    return status.isGranted;
  }

  /// 下载更新
  Future<bool> downloadUpdate({
    required AppVersion version,
    void Function(double progress)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    final fileName = 'study_buddy_v${version.version}.apk';
    return await _githubService.downloadApk(
      downloadUrl: version.downloadUrl,
      fileName: fileName,
      onProgress: onProgress,
      onStatus: onStatus,
    );
  }

  /// 安装 APK（经 MethodChannel 触发系统安装器）
  Future<bool> installUpdate(String version) async {
    try {
      final hasPermission = await requestInstallPermission();
      if (!hasPermission) return false;

      final fileName = 'study_buddy_v$version.apk';
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/updates/$fileName';
      final file = File(filePath);
      if (!await file.exists()) {
        LoggerService.instance.w('APK 文件不存在: $filePath',
            category: LogCategory.general, tags: const ['app_update']);
        return false;
      }
      final result = await _platformChannel.invokeMethod('installApk', {
        'filePath': filePath,
      });
      return result == true;
    } on PlatformException catch (e) {
      LoggerService.instance.e('安装失败: ${e.code}',
          category: LogCategory.general, tags: const ['app_update']);
      return false;
    } catch (e) {
      LoggerService.instance.e('安装 APK 失败: $e',
          category: LogCategory.general, tags: const ['app_update']);
      return false;
    }
  }

  /// 忽略此版本
  Future<void> ignoreVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ignoreVersionKey, version);
  }

  Future<bool> isVersionIgnored(String version) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ignoreVersionKey) == version;
  }

  Future<void> clearIgnoredVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ignoreVersionKey);
  }

  /// 预览版通道开关
  static Future<bool> isPreviewChannelEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_previewChannelKey) ?? false;
  }

  static Future<void> setPreviewChannelEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_previewChannelKey, enabled);
  }

  /// 从 GitHub Release body 提取 changelog
  ///
  /// 优先 `<!--CHANGELOG_START-->...<!--CHANGELOG_END-->` 标记（study_buddy 发布模板所用），
  /// 回退 `## 📝 更新日志` 标题之后内容，再回退完整 body。
  static String _extractChangelog(String? body) {
    if (body == null || body.isEmpty) return '';
    const startMarker = '<!--CHANGELOG_START-->';
    const endMarker = '<!--CHANGELOG_END-->';
    final startIdx = body.indexOf(startMarker);
    final endIdx = body.indexOf(endMarker);
    if (startIdx != -1 && endIdx != -1 && endIdx > startIdx) {
      final content = body.substring(startIdx + startMarker.length, endIdx).trim();
      if (content.isNotEmpty) return content;
    }
    const headerMarker = '## 📝 更新日志';
    final headerIdx = body.indexOf(headerMarker);
    if (headerIdx != -1) {
      final afterHeader = body.substring(headerIdx + headerMarker.length).trim();
      if (afterHeader.isNotEmpty) return afterHeader;
    }
    return body;
  }
}

/// 内部 semver 解析结构
class _Semver {
  final List<int> nums; // 长度 3
  final String? pre;
  _Semver(this.nums, this.pre);
}
