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

/// 当前 App 版本号（如 "0.1.0-preview.8"），供设置页「版本更新/关于」显示。
/// 复用 [AppUpdateService.getCurrentVersion]（PackageInfo.fromPlatform），
/// 避免版本号在 pubspec 与硬编码两处漂移。取不到时降级为 '未知版本'。
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await ref.watch(appUpdateServiceProvider).getCurrentVersion();
  final v = info.version.trim();
  return v.isEmpty ? '未知版本' : v;
});
