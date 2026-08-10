# App 端检查更新机制 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 study_buddy 内移植 novel_builder 的「检查更新 → 应用内下载 → 原生安装」机制，目标仓库改为 `yunkst/study_buddy`。

**Architecture:** 照搬 novel_builder 的 GitHub Releases 驱动更新链路，落在 `lib/core/update/` 子包，经 Riverpod provider 注入，首页手动触发（仅 Android）。原生侧 MethodChannel + FileProvider 触发系统安装器。

**Tech Stack:** Flutter 3.35 / Dart 3.9, Riverpod 3（手写 Provider，无 codegen）, dio 5, package_info_plus 8, permission_handler 11, device_info_plus 11, shared_preferences 2, go_router。

## Global Constraints（所有任务隐含遵守）

- **目标仓库**: `yunkst/study_buddy`（GitHub API: `https://api.github.com/repos/yunkst/study_buddy`）
- **MethodChannel 名**: `io.github.yunkst.studybuddy/app_install`（Flutter 侧与 Kotlin 侧一致）
- **FileProvider authority**: `io.github.yunkst.studybuddy.fileprovider`
- **APK 文件名前缀**: `study_buddy_v`（如 `study_buddy_v0.1.0-preview.2.apk`）
- **版本号格式含 `-preview.N`**（如 `0.1.0-preview.2`），版本比较必须支持 prerelease 后缀
- **去 codegen**：所有模型手写 `fromJson`/`toJson`，不引入 `json_serializable`/`build_runner`
- **日志**：novel 的 `LoggerService.instance.x(...)` 全部替换为 `developer.log('...', name: 'app_update')`（`import 'dart:developer';`）
- **偏好存储**：novel 的 `PreferencesService.instance.xxx(key)` 替换为 `SharedPreferences` 直连（`final prefs = await SharedPreferences.getInstance(); prefs.xxx(key)`），`getInt` 缺省用 `?? 0`，`getBool` 用 `?? false`
- **Toast**：novel 的 `ToastUtils.showError(msg)` 替换为 `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)))`
- **存储权限**：novel 的 `downloadApk` 请求 `Permission.storage` / `manageExternalStorage` —— **删除**。下载目标 `getApplicationDocumentsDirectory()/updates/` 是 app 私有目录，无需存储权限；避免无谓的"所有文件访问"授权弹窗。仅保留安装时 `Permission.requestInstallPackages`
- **study_engine 零改动**：所有更新代码在 study_buddy app 层，不碰 engine
- **提交信息**结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`，Conventional Commits 前缀
- 所有 Dart 文件用中文文档注释，与现有 `database_provider.dart` 风格一致

## 文件结构

```
study_buddy/lib/core/update/
├── models/
│   ├── github_release.dart       # GithubRelease + GithubAsset（从 novel 逐字复制）
│   ├── app_version.dart           # AppVersion DTO（手写 fromJson/toJson，去 @JsonSerializable）
│   └── update_check_result.dart   # sealed AppUpdateResult 三态
├── app_update_check_exception.dart # 可恢复异常（从 novel 逐字复制）
├── device_arch.dart               # DeviceArchDetector（去 LoggerService）
├── github_release_service.dart    # 网络 + 下载（改仓库 + 补异常接线 + 去存储权限）
├── app_update_service.dart        # 编排（改 channel/前缀 + semver 比较 + 去 Logger/Pref）
└── ui/
    └── app_update_dialog.dart     # 弹窗（Toast→SnackBar，Logger→dev log）

study_buddy/lib/core/providers/app_update_provider.dart  # Riverpod 注入（新建）

study_buddy/lib/features/home/home_page.dart             # 加「检查更新」入口

study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt  # installApk + MethodChannel
study_buddy/android/app/src/main/AndroidManifest.xml      # INTERNET + REQUEST_INSTALL_PACKAGES + FileProvider
study_buddy/android/app/src/main/res/xml/file_paths.xml   # FileProvider 路径（新建）
study_buddy/android/app/build.gradle.kts                  # 加 androidx.core 依赖

study_buddy/test/core/update/
├── github_release_service_test.dart   # 双通道 + 排序 + 异常分类
├── app_update_service_test.dart       # 结果分类 + 通道
└── has_new_version_test.dart          # semver 比较（含 prerelease）
```

---

## Task 1: 添加依赖

**Files:**
- Modify: `study_buddy/pubspec.yaml`

- [ ] **Step 1: 在 `dependencies:` 下追加 5 个包**

打开 `study_buddy/pubspec.yaml`，在 `path_provider: ^2.1.5` 这一行之后、`study_engine:` 之前，插入：

```yaml
  # App 检查更新机制
  dio: ^5.4.0
  package_info_plus: ^8.0.0
  permission_handler: ^11.0.0
  device_info_plus: ^11.0.0
  shared_preferences: ^2.2.2
```

- [ ] **Step 2: 拉取依赖**

Run: `cd study_buddy && flutter pub get`
Expected: `Got dependencies!`，无版本冲突。

- [ ] **Step 3: 静态检查通过**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 4: 提交**

```bash
git add study_buddy/pubspec.yaml study_buddy/pubspec.lock
git commit -m "chore(app): 引入检查更新机制依赖（dio/package_info_plus/permission_handler/device_info_plus/shared_preferences）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: 数据模型（github_release / app_version / update_check_result）

**Files:**
- Create: `study_buddy/lib/core/update/models/github_release.dart`
- Create: `study_buddy/lib/core/update/models/app_version.dart`
- Create: `study_buddy/lib/core/update/models/update_check_result.dart`
- Test: `study_buddy/test/core/update/models_test.dart`

**Interfaces:**
- Produces: `GithubRelease`（字段 `tagName/name/body/publishedAt/prerelease/draft/assets`，方法 `apkAssetFor(String archSegment)`、`get versionNumber`），`GithubAsset`（`name/size/browserDownloadUrl/contentType`），`AppVersion`（`version/downloadUrl/fileSize/changelog?/createdAt`，`get fileSizeFormatted`），`sealed AppUpdateResult`（`AppUpdateAvailable(version)` / `AppUpdateUpToDate()` / `AppUpdateCheckFailed(reason)`）

- [ ] **Step 1: 写 `github_release.dart`（从 novel 逐字复制，无改动）**

```dart
/// GitHub Release 数据模型
///
/// 对应 GitHub API `/repos/{owner}/{repo}/releases/latest` 响应
class GithubRelease {
  final String tagName;
  final String name;
  final String? body;
  final String publishedAt;
  final bool prerelease;
  final bool draft;
  final List<GithubAsset> assets;

  GithubRelease({
    required this.tagName,
    required this.name,
    this.body,
    required this.publishedAt,
    required this.prerelease,
    required this.draft,
    required this.assets,
  });

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    return GithubRelease(
      tagName: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      body: json['body'] as String?,
      publishedAt: json['published_at'] as String? ?? '',
      prerelease: json['prerelease'] as bool? ?? false,
      draft: json['draft'] as bool? ?? false,
      assets: (json['assets'] as List<dynamic>?)
              ?.map((e) => GithubAsset.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// 通用 APK asset：取第一个 APK（兼容旧逻辑）
  GithubAsset? get apkAsset {
    try {
      return assets.firstWhere(
        (a) => a.contentType == 'application/vnd.android.package-archive',
      );
    } catch (_) {
      try {
        return assets.firstWhere((a) => a.name.endsWith('.apk'));
      } catch (_) {
        return null;
      }
    }
  }

  /// 按设备架构选择最合适的 APK asset
  ///
  /// 兜底链：
  ///   1. 精确匹配当前架构的 split APK（如 `app-arm64-v8a-release.apk`）
  ///   2. 通用 fat APK（`app-release.apk`，包含所有架构）
  ///   3. 任意一个 APK（避免升级流程完全走不通）
  GithubAsset? apkAssetFor(String archSegment) {
    if (archSegment.isNotEmpty) {
      final matched = _firstApkNameContains(archSegment);
      if (matched != null) return matched;
    }
    final universal = _firstApkNameContains('-release.apk') ??
        _firstApkNameContains('app-release');
    if (universal != null) return universal;
    return _anyApk();
  }

  GithubAsset? _firstApkNameContains(String segment) {
    for (final a in assets) {
      if (!a.name.endsWith('.apk')) continue;
      if (a.name.contains(segment)) return a;
    }
    return null;
  }

  GithubAsset? _anyApk() {
    for (final a in assets) {
      if (a.name.endsWith('.apk')) return a;
    }
    return null;
  }

  /// 版本号（去除 'v' 前缀）："v1.7.7" → "1.7.7"
  String get versionNumber => tagName.replaceFirst(RegExp(r'^v'), '');
}

/// GitHub Release Asset 数据模型
class GithubAsset {
  final String name;
  final int size;
  final String browserDownloadUrl;
  final String contentType;

  GithubAsset({
    required this.name,
    required this.size,
    required this.browserDownloadUrl,
    required this.contentType,
  });

  factory GithubAsset.fromJson(Map<String, dynamic> json) {
    return GithubAsset(
      name: json['name'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      browserDownloadUrl: json['browser_download_url'] as String? ?? '',
      contentType: json['content_type'] as String? ?? '',
    );
  }
}
```

- [ ] **Step 2: 写 `app_version.dart`（手写 fromJson/toJson，去 codegen）**

```dart
/// APP 版本信息模型（用于 App 内展示更新信息）
class AppVersion {
  final String version;
  final String downloadUrl;
  final int fileSize;
  final String? changelog;
  final String createdAt;

  AppVersion({
    required this.version,
    required this.downloadUrl,
    required this.fileSize,
    this.changelog,
    required this.createdAt,
  });

  factory AppVersion.fromJson(Map<String, dynamic> json) {
    return AppVersion(
      version: json['version'] as String? ?? '',
      downloadUrl: json['download_url'] as String? ?? '',
      fileSize: json['file_size'] as int? ?? 0,
      changelog: json['changelog'] as String?,
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'download_url': downloadUrl,
        'file_size': fileSize,
        'changelog': changelog,
        'created_at': createdAt,
      };

  /// 格式化文件大小显示
  String get fileSizeFormatted {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  @override
  String toString() =>
      'AppVersion(version: $version, downloadUrl: $downloadUrl, fileSize: $fileSize)';
}
```

- [ ] **Step 3: 写 `update_check_result.dart`**

```dart
/// App 更新检查的结果类型
///
/// 区分三种情况，避免把「请求失败/限流」误报成「无新版本」：
/// - [AppUpdateAvailable]：远端存在可用 release
/// - [AppUpdateUpToDate]：请求成功，但远端无可用 release（draft/prerelease/无 APK）
/// - [AppUpdateCheckFailed]：请求失败（限流 / 网络错误），用户应重试
library;

import 'app_version.dart';

sealed class AppUpdateResult {
  const AppUpdateResult();
}

/// 远端存在可用的 release（含至少一个匹配架构的 APK）
class AppUpdateAvailable extends AppUpdateResult {
  final AppVersion version;
  const AppUpdateAvailable(this.version);
}

/// 请求成功，但没有可用的 release（404 无 release / draft / prerelease / 无 APK）
class AppUpdateUpToDate extends AppUpdateResult {
  const AppUpdateUpToDate();
}

/// 检查失败（限流 / 网络错误 / 解析异常），[reason] 是面向用户的简短说明
class AppUpdateCheckFailed extends AppUpdateResult {
  final String reason;
  const AppUpdateCheckFailed(this.reason);
}
```

- [ ] **Step 4: 写测试 `models_test.dart`**

```dart
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
```

- [ ] **Step 5: 跑测试**

Run: `cd study_buddy && flutter test test/core/update/models_test.dart`
Expected: All tests passed.

- [ ] **Step 6: 提交**

```bash
git add study_buddy/lib/core/update/models/ study_buddy/test/core/update/models_test.dart
git commit -m "feat(update): 更新机制数据模型（GithubRelease/AppVersion/AppUpdateResult）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: 异常类型 + 设备架构检测

**Files:**
- Create: `study_buddy/lib/core/update/app_update_check_exception.dart`
- Create: `study_buddy/lib/core/update/device_arch.dart`
- Test: `study_buddy/test/core/update/device_arch_test.dart`

**Interfaces:**
- Produces: `AppUpdateCheckException(message, {cause})`（cause: `rate_limited`/`network_error`/`http_xxx`/`unknown`），`enum DeviceArch {arm64, arm, x64, unknown}`，`extension DeviceArchName.apkNameSegment`，`DeviceArchDetector.getCurrent()`

**Consumes:** Task 2 无（这两个文件互相独立，但 device_arch 不依赖模型）

- [ ] **Step 1: 写 `app_update_check_exception.dart`（从 novel 逐字复制）**

```dart
/// App 更新检查过程中的可恢复异常
///
/// 用于将「网络错误 / 限流 / 服务器错误」与「真无新版本」区分开，
/// 避免把所有 null 都误报成「已是最新版本」。
class AppUpdateCheckException implements Exception {
  final String message;

  /// 失败原因分类：`rate_limited` / `network_error` / `http_xxx` / `unknown`
  final String cause;

  const AppUpdateCheckException(this.message, {required this.cause});

  @override
  String toString() => 'AppUpdateCheckException($cause): $message';
}
```

- [ ] **Step 2: 写 `device_arch.dart`（去 LoggerService，失败走 dev log）**

```dart
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
```

- [ ] **Step 3: 写测试 `device_arch_test.dart`（纯枚举映射，无需平台）**

```dart
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
```

- [ ] **Step 4: 跑测试**

Run: `cd study_buddy && flutter test test/core/update/device_arch_test.dart`
Expected: All tests passed.

- [ ] **Step 5: analyze**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: 提交**

```bash
git add study_buddy/lib/core/update/app_update_check_exception.dart study_buddy/lib/core/update/device_arch.dart study_buddy/test/core/update/device_arch_test.dart
git commit -m "feat(update): 异常类型 + 设备架构检测

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: GithubReleaseService（网络层 + 异常接线 + 下载）

**Files:**
- Create: `study_buddy/lib/core/update/github_release_service.dart`
- Test: `study_buddy/test/core/update/github_release_service_test.dart`

**Interfaces:**
- Consumes: `GithubRelease`（Task 2），`AppUpdateCheckException`（Task 3）
- Produces: `GithubReleaseService({Dio? dio})`，方法：
  - `Future<GithubRelease?> fetchLatestRelease({bool includePrerelease = false})` — **403/限流/网络错误抛 `AppUpdateCheckException`**，404/无 release 返回 null
  - `Future<bool> shouldCheck({bool forceCheck = false})`
  - `Future<void> recordCheckTime()`
  - `Future<bool> downloadApk({required String downloadUrl, required String fileName, void Function(double)? onProgress, void Function(String)? onStatus})`

> **核心修复**：novel 的 `fetchLatestRelease` 把所有 DioException 吞成返回 null，导致下游 `CheckFailed` 分类永远走不到。本任务在 catch 里按状态码/异常类型分类抛 `AppUpdateCheckException`，让「检查失败」与「无新版本」真正区分。下载方法**删除** novel 的 `Permission.storage` / `manageExternalStorage` 请求（app 私有目录无需存储权限）。

- [ ] **Step 1: 写 `github_release_service.dart`**

> `fetchLatestRelease` 用 try/catch 包裹，catch 里分类抛 `AppUpdateCheckException`（核心修复），404 视为「无 release」返回 null（非错误）。

```dart
import 'dart:developer';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_check_exception.dart';
import 'models/github_release.dart';

/// GitHub Releases API 服务：获取最新版本信息并下载 APK
class GithubReleaseService {
  static const String _apiBase = 'https://api.github.com';
  static const String _repoOwner = 'yunkst';
  static const String _repoName = 'study_buddy';

  static const String _lastCheckKey = 'app_update_last_check';
  static const Duration _checkInterval = Duration(hours: 1);

  final Dio _dio;

  GithubReleaseService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ));

  /// 获取最新 Release 信息
  ///
  /// - [includePrerelease] = false（stable 通道）调 `/releases/latest`，GitHub 原生跳过 prerelease
  /// - [includePrerelease] = true（preview 通道）调 `/releases?per_page=10`，客户端按 publishedAt
  ///   desc 取最新非 draft（GitHub API 默认排序在 prerelease 存在时不可靠）
  ///
  /// 返回 null 表示无可用 release（404 / draft / prerelease 被跳过 / 无 APK）；
  /// 网络错误 / 限流 / 服务器错误抛 [AppUpdateCheckException]（让调用方区分「失败」与「无新版本」）。
  Future<GithubRelease?> fetchLatestRelease({
    bool includePrerelease = false,
  }) async {
    try {
      final path = includePrerelease
          ? '/repos/$_repoOwner/$_repoName/releases?per_page=10'
          : '/repos/$_repoOwner/$_repoName/releases/latest';
      final url = '$_apiBase$path';
      log('GitHub API: $url', name: 'app_update');

      final response = await _dio.get<dynamic>(url);
      if (response.statusCode != 200 || response.data == null) {
        return null;
      }

      final dynamic data = response.data;
      final GithubRelease release;
      if (data is List) {
        if (data.isEmpty) return null;
        final releases = data
            .map((e) => GithubRelease.fromJson(e as Map<String, dynamic>))
            .where((r) => !r.draft)
            .toList();
        if (releases.isEmpty) return null;
        // publishedAt 是 ISO 8601 字符串，直接降序排序取最新
        releases.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
        release = releases.first;
      } else {
        release = GithubRelease.fromJson(data as Map<String, dynamic>);
      }

      if (release.draft) return null;
      if (release.prerelease && !includePrerelease) return null;
      if (release.apkAsset == null) return null;
      return release;
    } on DioException catch (e) {
      // 404 = 无 release，非错误
      if (e.response?.statusCode == 404) return null;
      throw _classifyDioException(e);
    } catch (e) {
      throw AppUpdateCheckException('获取更新信息失败: $e', cause: 'unknown');
    }
  }

  /// 将 DioException 分类为可恢复的 AppUpdateCheckException
  AppUpdateCheckException _classifyDioException(DioException e) {
    final code = e.response?.statusCode;
    if (code == 403 || code == 429) {
      return const AppUpdateCheckException('GitHub API 限流，请稍后重试', cause: 'rate_limited');
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return AppUpdateCheckException('网络错误：${e.message ?? '连接失败'}', cause: 'network_error');
    }
    if (code != null && code >= 500) {
      return AppUpdateCheckException('GitHub 服务器错误：$code', cause: 'http_$code');
    }
    if (code != null) {
      return AppUpdateCheckException('GitHub API 错误：$code', cause: 'http_$code');
    }
    return AppUpdateCheckException('网络错误：${e.message ?? '未知'}', cause: 'network_error');
  }

  /// 检查是否应执行更新检查（频率控制）。非强制时距上次不足 1 小时则跳过。
  Future<bool> shouldCheck({bool forceCheck = false}) async {
    if (forceCheck) return true;
    final prefs = await SharedPreferences.getInstance();
    final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - lastCheck) >= _checkInterval.inMilliseconds;
  }

  /// 记录检查时间
  Future<void> recordCheckTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 下载 APK 文件到 app 私有目录 `documents/updates/`
  ///
  /// app 私有目录无需存储权限，故不再请求 storage/manageExternalStorage。
  Future<bool> downloadApk({
    required String downloadUrl,
    required String fileName,
    void Function(double progress)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    try {
      onStatus?.call('准备下载...');
      final directory = await getApplicationDocumentsDirectory();
      final updatesDir = Directory('${directory.path}/updates');
      if (!await updatesDir.exists()) {
        await updatesDir.create(recursive: true);
      }
      final filePath = '${updatesDir.path}/$fileName';
      final existingFile = File(filePath);
      if (await existingFile.exists()) {
        await existingFile.delete();
      }
      onStatus?.call('开始下载...');
      log('从 GitHub 下载 APK: $downloadUrl', name: 'app_update');
      await _dio.download(
        downloadUrl,
        filePath,
        options: Options(receiveTimeout: const Duration(minutes: 10)),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
      );
      onStatus?.call('下载完成');
      onProgress?.call(1.0);
      return true;
    } on DioException catch (e) {
      log('APK 下载失败: ${e.message}', name: 'app_update');
      onStatus?.call(e.response != null
          ? '下载失败: 服务器错误 ${e.response?.statusCode}'
          : '下载失败: ${e.message ?? '网络错误'}');
      return false;
    } catch (e) {
      log('APK 下载异常: $e', name: 'app_update');
      onStatus?.call('下载出错: $e');
      return false;
    }
  }
}
```

- [ ] **Step 2: 写测试 `github_release_service_test.dart`**

```dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/update/app_update_check_exception.dart';
import 'package:study_buddy/core/update/github_release_service.dart';

/// 最小 Dio 桩：按 URL 子串返回预设数据，未命中则按 [errorStatusCode] 抛 DioException
class _StubDio implements Dio {
  final Map<String, dynamic> responses;
  final int? errorStatusCode;

  _StubDio(this.responses, {this.errorStatusCode});

  @override
  Future<Response<T>> get<T>(String path,
      {Object? data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      ProgressCallback? onReceiveProgress}) async {
    for (final entry in responses.entries) {
      if (path.contains(entry.key)) {
        return Response<T>(
          data: entry.value as T,
          statusCode: 200,
          requestOptions: RequestOptions(path: path),
        );
      }
    }
    throw DioException(
      requestOptions: RequestOptions(path: path),
      // 超时场景（errorStatusCode==null）不带 response，确保走 type 分类而非 404 兜底
      response: errorStatusCode != null
          ? Response(statusCode: errorStatusCode, requestOptions: RequestOptions(path: path))
          : null,
      type: errorStatusCode == null
          ? DioExceptionType.connectionTimeout
          : DioExceptionType.unknown,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _release(String tag,
        {bool prerelease = false, bool draft = false, String createdAt = '2026-07-01T00:00:00Z'}) =>
    {
      'tag_name': tag,
      'name': tag,
      'body': '',
      'published_at': createdAt,
      'prerelease': prerelease,
      'draft': draft,
      'assets': [
        {
          'name': 'app-arm64-v8a-release.apk',
          'size': 100,
          'browser_download_url': 'https://example.com/$tag.apk',
          'content_type': 'application/vnd.android.package-archive',
        }
      ],
    };

void main() {
  group('stable 通道 (includePrerelease=false)', () {
    test('调用 /releases/latest 返回稳定版', () async {
      final service = GithubReleaseService(
          dio: _StubDio({'/releases/latest': _release('v2.0.0', createdAt: '2026-07-18T15:00:00Z')}));
      final result = await service.fetchLatestRelease(includePrerelease: false);
      expect(result, isNotNull);
      expect(result!.tagName, 'v2.0.0');
    });

    test('stable 通道跳过 prerelease', () async {
      final service = GithubReleaseService(dio: _StubDio({
        '/releases/latest': _release('v2.0.0-preview.1', prerelease: true, createdAt: '2026-07-18T18:00:00Z'),
      }));
      expect(await service.fetchLatestRelease(includePrerelease: false), isNull);
    });
  });

  group('preview 通道 (includePrerelease=true)', () {
    test('按 publishedAt desc 取最新一条（含 prerelease）', () async {
      final service = GithubReleaseService(dio: _StubDio({
        '?per_page=10': [
          _release('v2.0.0', createdAt: '2026-07-18T15:00:00Z'),
          _release('v2.0.0-preview.1', prerelease: true, createdAt: '2026-07-18T18:00:00Z'),
          _release('v1.9.34', createdAt: '2026-07-17T09:00:00Z'),
        ],
      }));
      final result = await service.fetchLatestRelease(includePrerelease: true);
      expect(result!.tagName, 'v2.0.0-preview.1');
      expect(result.prerelease, isTrue);
    });

    test('跳过 draft 取最新非 draft', () async {
      final service = GithubReleaseService(dio: _StubDio({
        '?per_page=10': [
          _release('v2.0.0', createdAt: '2026-07-18T15:00:00Z'),
          _release('v2.0.0-preview.2', prerelease: true, draft: true, createdAt: '2026-07-19T10:00:00Z'),
        ],
      }));
      expect((await service.fetchLatestRelease(includePrerelease: true))!.tagName, 'v2.0.0');
    });

    test('空列表返回 null', () async {
      final service = GithubReleaseService(dio: _StubDio({'?per_page=10': <Map<String, dynamic>>[]}));
      expect(await service.fetchLatestRelease(includePrerelease: true), isNull);
    });
  });

  group('异常分类（核心修复）', () {
    test('404 返回 null（无 release，非错误）', () async {
      final service = GithubReleaseService(dio: _StubDio({}, errorStatusCode: 404));
      expect(await service.fetchLatestRelease(), isNull);
    });

    test('403 限流抛 AppUpdateCheckException(rate_limited)', () async {
      final service = GithubReleaseService(dio: _StubDio({}, errorStatusCode: 403));
      await expectLater(
        service.fetchLatestRelease(),
        throwsA(isA<AppUpdateCheckException>()
            .having((e) => e.cause, 'cause', 'rate_limited')),
      );
    });

    test('连接超时抛 AppUpdateCheckException(network_error)', () async {
      final service = GithubReleaseService(dio: _StubDio({}, errorStatusCode: null));
      await expectLater(
        service.fetchLatestRelease(),
        throwsA(isA<AppUpdateCheckException>()
            .having((e) => e.cause, 'cause', 'network_error')),
      );
    });

    test('5xx 抛 AppUpdateCheckException(http_5xx)', () async {
      final service = GithubReleaseService(dio: _StubDio({}, errorStatusCode: 503));
      await expectLater(
        service.fetchLatestRelease(),
        throwsA(isA<AppUpdateCheckException>()
            .having((e) => e.cause, 'cause', 'http_503')),
      );
    });
  });
}
```

- [ ] **Step 3: 跑测试**

Run: `cd study_buddy && flutter test test/core/update/github_release_service_test.dart`
Expected: All tests passed.（确认 4 个异常分类测试通过 = 异常接线修复生效）

- [ ] **Step 4: 提交**

```bash
git add study_buddy/lib/core/update/github_release_service.dart study_buddy/test/core/update/github_release_service_test.dart
git commit -m "feat(update): GithubReleaseService 网络层 + 异常分类接线

补 novel 未接线的异常分类：403→rate_limited、超时→network_error、5xx→http_xxx，
让 CheckFailed vs UpToDate 区分生效。去掉冗余存储权限请求（app 私有目录无需）。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: AppUpdateService（编排 + semver 版本比较）

**Files:**
- Create: `study_buddy/lib/core/update/app_update_service.dart`
- Test: `study_buddy/test/core/update/app_update_service_test.dart`
- Test: `study_buddy/test/core/update/has_new_version_test.dart`

**Interfaces:**
- Consumes: `GithubReleaseService`（Task 4），`DeviceArchDetector`（Task 3），`AppVersion`/`AppUpdateResult`/`AppUpdateCheckException`（Task 2/3）
- Produces: `AppUpdateService({GithubReleaseService? githubService, Future<PackageInfo> Function()? packageInfoGetter})`，方法：
  - `Future<AppUpdateResult> checkForUpdateDetailed({bool forceCheck = false, bool includePrerelease = false})`
  - `Future<AppVersion?> checkForUpdate({bool forceCheck, bool includePrerelease})`（向后兼容，委托 detailed）
  - `bool hasNewVersion(String current, String latest)` — **支持 `-preview.N` 的 semver 比较**
  - `Future<bool> downloadUpdate({required AppVersion version, onProgress, onStatus})`
  - `Future<bool> installUpdate(String version)`
  - `Future<bool> requestInstallPermission()`
  - `Future<void> ignoreVersion(String)` / `Future<bool> isVersionIgnored(String)` / `Future<void> clearIgnoredVersion()`
  - `static Future<bool> isPreviewChannelEnabled()` / `static Future<void> setPreviewChannelEnabled(bool)`

> **核心适配**：`hasNewVersion` 改为支持 prerelease 的 semver 比较。novel 用 `int.parse('.'.split())`，遇到 `0.1.0-preview.2` 会抛异常返回 false → 对 study_buddy 预览通道（默认通道）永远检测不到更新。新实现：拆出 core（`X.Y.Z`）与 prerelease 后缀分别比较；core 相同时无后缀（stable）> 有后缀（prerelease）；同为 prerelease 时比 `preview.N` 的 N。

- [ ] **Step 1: 写 `app_update_service.dart`**

```dart
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_check_exception.dart';
import 'device_arch.dart';
import 'github_release_service.dart';
import 'models/app_version.dart';
import 'models/github_release.dart';
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
    if (_packageInfoGetter != null) return await _packageInfoGetter!();
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
      log('版本比较: ${currentInfo.version} vs ${appVersion.version}, hasNew: $hasNew',
          name: 'app_update');

      // 强制检查或有新版本都返回 Available（调用方按需提示）
      if (forceCheck || hasNew) {
        return AppUpdateAvailable(appVersion);
      }
      return const AppUpdateUpToDate();
    } on AppUpdateCheckException catch (e) {
      return AppUpdateCheckFailed(e.message);
    } catch (e) {
      log('检查更新失败: $e', name: 'app_update');
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
      log('版本号比较失败: $e', name: 'app_update');
      return false;
    }
  }

  /// 语义化版本比较：返回 <0 表示 a<b，0 相等，>0 a>b
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
        log('APK 文件不存在: $filePath', name: 'app_update');
        return false;
      }
      final result = await _platformChannel.invokeMethod('installApk', {
        'filePath': filePath,
      });
      return result == true;
    } on PlatformException catch (e) {
      log('安装失败: ${e.code}', name: 'app_update');
      return false;
    } catch (e) {
      log('安装 APK 失败: $e', name: 'app_update');
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
```

- [ ] **Step 2: 写 `app_update_service_test.dart`（结果分类，port novel 测试）**

```dart
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
```

- [ ] **Step 3: 写 `has_new_version_test.dart`（semver，含 prerelease）**

```dart
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
```

- [ ] **Step 4: 跑测试**

Run: `cd study_buddy && flutter test test/core/update/app_update_service_test.dart test/core/update/has_new_version_test.dart`
Expected: All tests passed.（prerelease 比较测试通过 = 核心适配生效）

- [ ] **Step 5: analyze**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: 提交**

```bash
git add study_buddy/lib/core/update/app_update_service.dart study_buddy/test/core/update/app_update_service_test.dart study_buddy/test/core/update/has_new_version_test.dart
git commit -m "feat(update): AppUpdateService 编排 + semver 版本比较

hasNewVersion 改为支持 -preview.N 的 semver 比较：novel 的 int.parse 在
preview 版本上误判（study_buddy 默认通道），core 相同时 stable>prerelease，
同为 prerelease 比 preview.N。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: 更新弹窗 UI

**Files:**
- Create: `study_buddy/lib/core/update/ui/app_update_dialog.dart`

**Interfaces:**
- Consumes: `AppVersion`（Task 2），`AppUpdateService`（Task 5）
- Produces: `AppUpdateDialog`（StatefulWidget），`Future<void> showAppUpdateDialog(BuildContext, {required AppVersion version, required AppUpdateService updateService, VoidCallback? onUpdateComplete, bool isNewVersion = true})`

> 从 novel 的 `app_update_dialog.dart` 移植：`ToastUtils.showError` → `ScaffoldMessenger SnackBar`，去掉 `LoggerService`。

- [ ] **Step 1: 写 `app_update_dialog.dart`**

```dart
import 'package:flutter/material.dart';

import '../app_update_service.dart';
import '../models/app_version.dart';

/// APP 更新对话框：显示新版本，提供下载 + 安装
class AppUpdateDialog extends StatefulWidget {
  final AppVersion version;
  final AppUpdateService updateService;
  final VoidCallback? onUpdateComplete;
  final bool isNewVersion; // false 表示版本相同但用户重新下载

  const AppUpdateDialog({
    super.key,
    required this.version,
    required this.updateService,
    this.onUpdateComplete,
    this.isNewVersion = true,
  });

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  double _downloadProgress = 0.0;
  String _statusMessage = '';
  bool _isDownloading = false;
  bool _isDownloadComplete = false;
  bool _isInstalling = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(children: [
        Icon(Icons.new_releases, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(widget.isNewVersion ? '发现新版本' : '重新下载',
            style: const TextStyle(fontSize: 18)),
      ]),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本 ${widget.version.version}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('大小: ${widget.version.fileSizeFormatted}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (widget.version.changelog != null &&
                widget.version.changelog!.isNotEmpty) ...[
              Text('更新内容:', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(widget.version.changelog!,
                      style: theme.textTheme.bodySmall),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_isDownloading || _isDownloadComplete) ...[
              if (_isDownloading) ...[
                LinearProgressIndicator(
                  value: _downloadProgress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_downloadProgress * 100).toStringAsFixed(0)}% - $_statusMessage',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('下载完成',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
      actions: _buildActions(),
    );
  }

  List<Widget> _buildActions() {
    if (_isInstalling) {
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: CircularProgressIndicator(),
          ),
        ),
      ];
    }
    if (_isDownloadComplete) {
      return [
        TextButton(
          onPressed: _isInstalling ? null : _installApk,
          child: const Text('立即安装'),
        ),
      ];
    }
    if (_isDownloading) {
      return const [TextButton(onPressed: null, child: Text('下载中...'))];
    }
    return [
      TextButton(
        onPressed: () async {
          await widget.updateService.ignoreVersion(widget.version.version);
          if (mounted) Navigator.of(context).pop();
        },
        child: const Text('稍后提醒'),
      ),
      ElevatedButton(
        onPressed: _startDownload,
        child: Text(widget.isNewVersion ? '立即更新' : '重新下载'),
      ),
    ];
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _statusMessage = '准备下载...';
    });
    final success = await widget.updateService.downloadUpdate(
      version: widget.version,
      onProgress: (p) => mounted ? setState(() => _downloadProgress = p) : null,
      onStatus: (s) => mounted ? setState(() => _statusMessage = s) : null,
    );
    if (!mounted) return;
    setState(() {
      _isDownloading = false;
      _isDownloadComplete = success;
      _statusMessage = success ? '下载完成' : '下载失败';
    });
    if (success) _installApk();
  }

  Future<void> _installApk() async {
    setState(() => _isInstalling = true);
    final success = await widget.updateService.installUpdate(widget.version.version);
    if (!mounted) return;
    setState(() => _isInstalling = false);
    if (success) {
      Navigator.of(context).pop();
      widget.onUpdateComplete?.call();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('安装失败，请手动安装')),
      );
    }
  }
}

/// 显示更新对话框的辅助函数
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppVersion version,
  required AppUpdateService updateService,
  VoidCallback? onUpdateComplete,
  bool isNewVersion = true,
}) {
  return showDialog(
    context: context,
    builder: (context) => AppUpdateDialog(
      version: version,
      updateService: updateService,
      onUpdateComplete: onUpdateComplete,
      isNewVersion: isNewVersion,
    ),
  );
}
```

- [ ] **Step 2: analyze**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/core/update/ui/app_update_dialog.dart
git commit -m "feat(update): 更新弹窗 UI（下载/安装状态机）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Riverpod provider 注入

**Files:**
- Create: `study_buddy/lib/core/providers/app_update_provider.dart`

**Interfaces:**
- Consumes: `GithubReleaseService`（Task 4），`AppUpdateService`（Task 5）
- Produces: `githubReleaseServiceProvider`（`Provider<GithubReleaseService>`），`appUpdateServiceProvider`（`Provider<AppUpdateService>`）

- [ ] **Step 1: 写 `app_update_provider.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../update/app_update_service.dart';
import '../update/github_release_service.dart';

/// GitHub Releases 网络服务（单例）
final githubReleaseServiceProvider = Provider<GithubReleaseService>((ref) {
  return GithubReleaseService();
});

/// APP 更新编排服务（单例），注入上面的 github service
final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(
    githubService: ref.watch(githubReleaseServiceProvider),
  );
});
```

- [ ] **Step 2: analyze**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/core/providers/app_update_provider.dart
git commit -m "feat(update): Riverpod provider 注入更新服务

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: 首页「检查更新」入口

**Files:**
- Modify: `study_buddy/lib/features/home/home_page.dart`

**Interfaces:**
- Consumes: `appUpdateServiceProvider`（Task 7），`AppUpdateService`（Task 5），`AppUpdateResult`（Task 2），`showAppUpdateDialog`（Task 6）

> 仅 Android 显示入口（`Platform.isAndroid`）。点击 → 读 preview 通道开关 → `checkForUpdateDetailed(forceCheck: true)` → 按结果弹窗 / SnackBar。

- [ ] **Step 1: 改写 `home_page.dart`（在现有 Column 内追加入口）**

将 `home_page.dart` 完整替换为：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_update_provider.dart';
import '../../core/providers/database_provider.dart';
import '../../core/update/app_update_service.dart';
import '../../core/update/models/update_check_result.dart';
import '../../core/update/ui/app_update_dialog.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (db) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '地基已就绪 ✅\n数据库已连接。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('进入题库'),
                  onPressed: () => context.go('/external-qbank'),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('检查更新'),
                    onPressed: () => _checkForUpdate(context, ref),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context, WidgetRef ref) async {
    final service = ref.read(appUpdateServiceProvider);
    final preview = await AppUpdateService.isPreviewChannelEnabled();
    final result = await service.checkForUpdateDetailed(
      forceCheck: true,
      includePrerelease: preview,
    );
    if (!context.mounted) return;
    switch (result) {
      case AppUpdateAvailable(:final version):
        await showAppUpdateDialog(context, version: version, updateService: service);
      case AppUpdateUpToDate():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已是最新版本')),
        );
      case AppUpdateCheckFailed(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查失败：$reason')),
        );
    }
  }
}
```

- [ ] **Step 2: analyze**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: 跑现有 widget test 确认未破坏**

Run: `cd study_buddy && flutter test test/widget_test.dart`
Expected: All tests passed.（smoke test 仍通过）

- [ ] **Step 4: 提交**

```bash
git add study_buddy/lib/features/home/home_page.dart
git commit -m "feat(update): 首页「检查更新」入口（仅 Android）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 9: 原生 Android 安装（MethodChannel + FileProvider）

**Files:**
- Modify: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt`
- Modify: `study_buddy/android/app/src/main/AndroidManifest.xml`
- Create: `study_buddy/android/app/src/main/res/xml/file_paths.xml`
- Modify: `study_buddy/android/app/build.gradle.kts`

> Kotlin 侧注册 `io.github.yunkst.studybuddy/app_install` MethodChannel，`installApk` 用 FileProvider + Intent 唤起系统安装器。Manifest 加 `INTERNET`（release 也需要 dio 联网）+ `REQUEST_INSTALL_PACKAGES` + FileProvider 声明。`file_paths.xml` 覆盖 app 私有 `files/updates/` 目录。

- [ ] **Step 1: 改写 `MainActivity.kt`**

```kotlin
package io.github.yunkst.studybuddy

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val APP_INSTALL_CHANNEL = "io.github.yunkst.studybuddy/app_install"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        if (installApk(filePath)) {
                            result.success(true)
                        } else {
                            result.error("INSTALL_FAILED", "Failed to install APK", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "File path is required", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /// 用 FileProvider + Intent 触发系统 APK 安装器
    private fun installApk(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) return false

            val intent = Intent(Intent.ACTION_VIEW).apply {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    FileProvider.getUriForFile(
                        this@MainActivity,
                        "$packageName.fileprovider",
                        file
                    )
                } else {
                    Uri.fromFile(file)
                }
                setDataAndType(uri, "application/vnd.android.package-archive")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
```

- [ ] **Step 2: 在 `build.gradle.kts` 末尾 `flutter { ... }` 块之前追加 androidx.core 依赖**

在 `study_buddy/android/app/build.gradle.kts` 的 `flutter { source = "../.." }` **之前**插入：

```kotlin
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}

```

- [ ] **Step 3: 改写 `AndroidManifest.xml`（加权限 + FileProvider）**

将 `<manifest>` 标签内、`<application>` 标签**之前**追加权限（与现有内容合并，最终 manifest 含这些 uses-permission）：

```xml
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
```

在 `<application>` 标签内、`</application>` 之前追加 FileProvider：

```xml
        <!-- FileProvider for APK installation -->
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>
```

> 最终 manifest 的 `<application>` 内应同时包含原来的 `<activity>`、`flutterEmbedding` meta-data、以及新增的 `<provider>`。`android:label` 保持 `study_buddy`。

- [ ] **Step 4: 创建 `res/xml/file_paths.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <!-- app 私有文件目录：覆盖 getApplicationDocumentsDirectory()/updates/ -->
    <files-path name="updates" path="updates/" />
    <files-path name="files_root" path="." />

    <!-- 兜底：根目录（应对意外路径） -->
    <root-path name="root" path="." />
</paths>
```

> 目录 `study_buddy/android/app/src/main/res/xml/` 不存在则新建。

- [ ] **Step 5: 构建 APK 验证原生侧编译通过**

Run: `cd study_buddy && flutter build apk --debug`
Expected: `✓ Built build\app\outputs\flutter-apk\app-debug.apk`，无 Kotlin/Manifest 编译错误。

> 若报 `androidx.core.content.FileProvider` 找不到，确认 Step 2 的 `dependencies` 块已加且 `flutter pub get` 已跑。

- [ ] **Step 6: 提交**

```bash
git add study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt study_buddy/android/app/src/main/AndroidManifest.xml study_buddy/android/app/src/main/res/xml/file_paths.xml study_buddy/android/app/build.gradle.kts
git commit -m "feat(android): APK 安装 MethodChannel + FileProvider + 安装权限

注册 io.github.yunkst.studybuddy/app_install 通道，installApk 经 FileProvider
+ Intent 唤起系统安装器。Manifest 加 INTERNET（release 联网）+ REQUEST_INSTALL_PACKAGES。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 10: 集成验证

**Files:**
- 无新增，仅验证

- [ ] **Step 1: 全量 analyze + test**

Run: `cd study_buddy && flutter analyze && flutter test`
Expected: `No issues found!` + All tests passed.

- [ ] **Step 2: release APK 构建（确认 release 通道也通过）**

Run: `cd study_buddy && flutter build apk --release`
Expected: 成功生成 APK（本地无 keystore 则降级 debug 签名，仅验证能构建）。

- [ ] **Step 3: 引擎侧回归（确保未误碰 engine）**

Run: `cd packages/study_engine && dart analyze && dart test -j 1`
Expected: No issues + All tests passed.

- [ ] **Step 4: 手动端到端（需真机/模拟器，可选）**

1. `flutter run` 到 Android 设备
2. 首页点「检查更新」
3. 预期：连 GitHub API（当前无 release → SnackBar「已是最新版本」；或有限流 → 「检查失败」）
4. （待首个 release 发布后）应弹更新窗，下载 + 安装链路通

> 无真机时跳过本步，依赖 Step 1-3 的自动化验证。

- [ ] **Step 5: 更新 SKILL.md 变更记录（可选，记录 app 端更新机制已落地）**

在 `study_buddy/.claude/skills/study-app-release/SKILL.md` 末尾「变更记录」追加一条（如需）。非必须。

- [ ] **Step 6: 收尾提交（若有改动）**

```bash
git status
# 若有未提交改动：
git add -A
git commit -m "chore(update): 集成验证收尾

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 自检结论

- **Spec 覆盖**: 设计文档 §3 适配点逐项落地（仓库/channel/前缀/semver/去依赖/去权限/Riverpod）；§5 异常接线 = Task 4；§6 测试 = Task 2/3/4/5 各有；原生 = Task 9。
- **关键适配**: `hasNewVersion` 支持 prerelease（Task 5，study_buddy 默认通道必需，否则照搬 novel 会失效）；下载去存储权限（Task 4，app 私有目录无需）。
- **类型一致性**: `AppUpdateResult` 三态、`AppUpdateCheckException.cause`、`GithubReleaseService` 构造参数 `Dio? dio`、`AppUpdateService` 构造参数在各任务间一致。
- **无占位符**: 所有代码块为完整可编译内容。
