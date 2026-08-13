import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/logger_service.dart';
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
      LoggerService.instance.d('GitHub API: $url',
          category: LogCategory.general, tags: const ['app_update']);

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
      LoggerService.instance.i('从 GitHub 下载 APK: $downloadUrl',
          category: LogCategory.general, tags: const ['app_update']);
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
      LoggerService.instance.e('APK 下载失败: ${e.message}',
          category: LogCategory.general, tags: const ['app_update']);
      onStatus?.call(e.response != null
          ? '下载失败: 服务器错误 ${e.response?.statusCode}'
          : '下载失败: ${e.message ?? '网络错误'}');
      return false;
    } catch (e) {
      LoggerService.instance.e('APK 下载异常: $e',
          category: LogCategory.general, tags: const ['app_update']);
      onStatus?.call('下载出错: $e');
      return false;
    }
  }
}
