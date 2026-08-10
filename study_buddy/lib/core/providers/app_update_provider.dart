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
