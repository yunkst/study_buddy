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
