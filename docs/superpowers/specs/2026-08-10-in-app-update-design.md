# App 端检查更新机制 · 设计文档

- **日期**: 2026-08-10
- **背景**: study_buddy 发布端（CI + study-app-release 技能）已落地，但 app 内无法感知新版本。参照 `novel_builder` 的成熟实现，移植一套 GitHub Releases 驱动的「检查 → 应用内下载 → 原生安装」更新机制。
- **原则**: 照搬 novel_builder 的逻辑，只做必要适配（目标仓库、包名、去掉 novel 专属依赖、Riverpod 注入）。不重新设计。

## 1. 目标与非目标

### 目标
- 用户在 app 内点「检查更新」，拉 GitHub Releases，有新版则弹窗提示。
- 弹窗内一键下载 APK + 唤起系统安装器（Android）。
- 支持稳定/预览双通道（对齐 CI 的 prerelease 标记）。
- 按设备 ABI 选 split APK。

### 非目标（MVP 不做）
- iOS 更新（需 TestFlight/App Store，另立方案）。
- 启动自动检查（纯手动触发，同 novel_builder）。
- 后台静默下载 / 增量更新。
- 桌面平台安装（桌面仅 dev/CI 用，更新入口对桌面/iOS 隐藏）。

## 2. 架构与文件落点

study_buddy 现有惯例：`core/providers/` 放基础设施 service+provider。更新机制 8 个文件单独开 `core/update/` 子包，provider 收口在 `core/providers/`。

```
study_buddy/lib/
├── core/
│   ├── update/                          # 更新机制子包
│   │   ├── models/
│   │   │   ├── github_release.dart      # GithubRelease + GithubAsset + apkAssetFor(arch)（零改造复用）
│   │   │   ├── app_version.dart          # AppVersion DTO（手写 fromJson，去 codegen）
│   │   │   └── update_check_result.dart  # sealed AppUpdateResult: Available/UpToDate/CheckFailed
│   │   ├── github_release_service.dart   # 网络: fetchLatestRelease + downloadApk + 异常分类（补接线）
│   │   ├── app_update_service.dart       # 编排: checkForUpdateDetailed/hasNewVersion/download/install/ignore/preview
│   │   ├── app_update_check_exception.dart
│   │   ├── device_arch.dart              # DeviceArchDetector（Android ABI 检测）
│   │   └── ui/
│   │       └── app_update_dialog.dart    # 弹窗 Widget + showAppUpdateDialog 辅助函数
│   └── providers/
│       └── app_update_provider.dart      # Riverpod: githubReleaseServiceProvider + appUpdateServiceProvider
└── features/home/home_page.dart          # 加「检查更新」手动入口（仅 Android 显示）
```

**原生侧**（Android）：
```
android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt  # 加 installApk 方法
android/app/src/main/AndroidManifest.xml   # REQUEST_INSTALL_PACKAGES + FileProvider 声明
android/app/src/main/res/xml/file_paths.xml # FileProvider 路径（新建 res/xml/ 目录）
```

## 3. 适配点（novel_builder → study_buddy）

| 项 | novel_builder | study_buddy |
|---|---|---|
| 目标仓库 | `yunkst/novel_builder` | `yunkst/study_buddy` |
| MethodChannel | `com.example.novel_app/app_install` | `io.github.yunkst.studybuddy/app_install` |
| APK 文件前缀 | `novel_app_v$ver.apk` | `study_buddy_v$ver.apk` |
| DI | `AppUpdateService()` 直接 new | Riverpod provider 注入 |
| 模型序列化 | `@JsonSerializable` + build_runner | 手写 fromJson（study_buddy 零 codegen） |
| 日志 | `LoggerService.instance` | `dart:developer` |
| Toast | `ToastUtils.showError` | `SnackBar` |
| 偏好存储 | `PreferencesService` 封装 | `SharedPreferences` 直连 |
| 触发入口 | 设置页手动按钮 | 首页「检查更新」（无设置页） |

**平台范围**：下载+安装链 Android 专属。「检查更新」入口仅 `Platform.isAndroid` 显示，桌面/iOS 隐藏，避免引入 url_launcher 和跨平台安装复杂度。

## 4. 数据流（手动触发）

```
首页「检查更新」onTap  (仅 Android)
  └─ ref.read(appUpdateServiceProvider).checkForUpdate(forceCheck: true, includePrerelease: previewEnabled)
       └─ AppUpdateService.checkForUpdateDetailed()
            1. githubReleaseService.shouldCheck(force)   # force=true 跳过频率控制
            2. githubReleaseService.recordCheckTime()
            3. githubReleaseService.fetchLatestRelease(includePrerelease)
                 stable: GET /repos/yunkst/study_buddy/releases/latest
                 preview: GET /repos/yunkst/study_buddy/releases?per_page=10 → publishedAt desc 取最新非 draft
                 → GithubRelease.fromJson
                 → 403/网络/超时: 抛 AppUpdateCheckException(cause)   # 补接线
                 → 404/无 asset: 返回 null（非错误）
            4. DeviceArchDetector.getCurrent() → release.apkAssetFor('arm64-v8a' 等)
            5. 构造 AppVersion
            6. PackageInfo → hasNewVersion(current, latest)
            7. return Available | UpToDate | CheckFailed
  ├─ Available   → showAppUpdateDialog(context, version, service)
  ├─ UpToDate    → SnackBar「已是最新版本」
  └─ CheckFailed → SnackBar「检查失败：<reason>，稍后重试」

弹窗 AppUpdateDialog（状态机）:
  「立即更新」→ service.downloadUpdate(onProgress, onStatus)
    → Permission.storage（必要时 manageExternalStorage）→ Dio.download 到 appDocs/updates/study_buddy_v$ver.apk
    → 进度回调
    → 成功自动 service.installUpdate(version)
        → Permission.requestInstallPackages → MethodChannel installApk
          → Kotlin: FileProvider + Intent(ACTION_VIEW, "application/vnd.android.package-archive") → 系统安装器
  失败: 留弹窗，「重新下载」/ SnackBar 报错
```

## 5. 错误处理矩阵

| 场景 | service 行为 | 结果类型 | 用户感知 |
|---|---|---|---|
| 403 限流 | 抛 `(rate_limited)` | `CheckFailed("限流")` | SnackBar「GitHub 限流，稍后重试」 |
| 网络错误/超时 | 抛 `(network_error)` | `CheckFailed("网络")` | SnackBar「网络异常」 |
| HTTP 5xx | 抛 `(http_5xx)` | `CheckFailed("服务异常")` | SnackBar「服务暂时不可用」 |
| 404 / 无 release / draft / 无 APK asset | 返回 null | `UpToDate` | SnackBar「已是最新版本」 |
| 有 release 且 version 更高 | 正常 | `Available` | 弹窗 |
| 下载失败 | downloadApk 返回 false | 弹窗内提示 | 留弹窗，「重新下载」 |
| 安装权限被拒 | installUpdate 返回 false | 弹窗内提示 | 留弹窗，可重试授权 |
| 非 Android | 入口隐藏 | — | 不触发 |

### 异常接线修复（本次移植的核心增值）
novel_builder 的 `github_release_service.fetchLatestRelease` 把 403/网络错误全 catch 成返回 null，导致 `AppUpdateService` 的 catch 块和 `CheckFailed` 分类永远走不到（`app_update_check_result_test.dart` 依赖手动抛异常才能跑通）。移植时在 catch 里按 `DioExceptionType` 分类抛 `AppUpdateCheckException(cause)`，让「检查失败（可重试）」与「无新版本」真正区分开。

### 频率控制
`shouldCheck` 默认 1 小时一次（key `app_update_last_check`，SharedPreferences）。手动入口 `forceCheck:true` 绕过。保留是为将来加自动检查时现成可用。

## 6. 测试计划

搬 novel_builder 的 3 个测试 + 适配（`test` 包，纯逻辑，放 `study_buddy/test/core/update/`）：

| 测试文件 | 覆盖 | 适配点 |
|---|---|---|
| `github_release_service_test.dart` | stable/preview 双通道 + publishedAt 排序 + draft 跳过 + 空列表 null | 桩 Dio（`_StubDio implements Dio`），仓库常量改 study_buddy |
| `app_update_service_test.dart` | Available/UpToDate/CheckFailed 分类 + hasNewVersion + preview 通道开关 | fake `GithubReleaseService` 子类 + 注入 fake PackageInfo |
| `has_new_version_test.dart` | null/异常响应不崩（历史 bug 回归）+ semver 三段比较 + 位数补齐 | 基本零改造 |

**新增**：smoke test 断言 `AppUpdateCheckException` 在 403 时被抛出（验证补接线，novel 原版无此测试）。

Widget test（弹窗）MVP 不做。

## 7. 依赖清单（study_buddy/pubspec.yaml 新增）

| 包 | 版本 | 用途 |
|---|---|---|
| `dio` | ^5.4.0 | HTTP + APK 下载 |
| `package_info_plus` | ^8.0.0 | 读当前版本号 |
| `permission_handler` | ^11.0.0 | 存储/安装权限 |
| `device_info_plus` | ^11.0.0 | ABI 检测 |
| `shared_preferences` | ^2.2.2 | 频率控制/忽略版本/preview 开关 |
| `path_provider` | 已有 ✓ | 下载目录 |

**不加**：`json_serializable`/`build_runner`（手写 fromJson）、`url_launcher`（Android-only）、`install_plugin`/`open_file`（自建 MethodChannel）。

## 8. 组件职责速查

| 文件 | 职责 | 复用度 |
|---|---|---|
| `models/github_release.dart` | GitHub Release JSON 反序列化 + 按 ABI 选 APK | 零改造 |
| `models/app_version.dart` | 展示用版本 DTO（含 changelog/size 格式化） | 去 codegen，手写 fromJson |
| `models/update_check_result.dart` | sealed 检查结果（三态） | 零改造 |
| `github_release_service.dart` | GitHub API 网络层 + 下载 APK | 改仓库常量 + 补异常接线 |
| `app_update_service.dart` | 更新编排（检查/比较/下载/安装/忽略/通道） | 改 channel 名 + 文件前缀 + 去依赖 |
| `app_update_check_exception.dart` | 可恢复异常类型（cause 分类） | 零改造 |
| `device_arch.dart` | Android CPU 架构检测 | 零改造 |
| `ui/app_update_dialog.dart` | 更新弹窗（下载/安装状态机） | Toast→SnackBar，Logger→dev log |
| `providers/app_update_provider.dart` | Riverpod 注入（新增） | 新建 |
| 原生 MainActivity.kt installApk | FileProvider + Intent 安装 | 改包名上下文，逻辑零改造 |

## 9. 变更记录
- 2026-08-10: 初版，照搬 novel_builder 更新机制 + study_buddy 适配设计。
