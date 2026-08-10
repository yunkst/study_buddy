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
