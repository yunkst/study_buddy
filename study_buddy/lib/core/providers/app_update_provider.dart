import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 预览版下载通道开关（与 AppUpdateService 共用 key 'app_update_preview_channel'）。
/// 打开后检查更新走 preview 通道（includePrerelease: true），可下载预览版 APK。
final previewChannelProvider =
    AsyncNotifierProvider<PreviewChannelNotifier, bool>(
  PreviewChannelNotifier.new,
);

class PreviewChannelNotifier extends AsyncNotifier<bool> {
  static const _key = 'app_update_preview_channel';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// 写入并立即更新 state，驱动设置页开关重建。
  /// 不走 invalidateSelf，避免一次多余的重读。
  Future<void> set(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
    state = AsyncData(enabled);
  }
}

/// 当前安装版本（从 PackageInfo 读取；测试/异常环境兜底「未知」）。
final currentVersionProvider = FutureProvider<String>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } catch (_) {
    return '未知';
  }
});
