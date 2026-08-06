import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// LLM HTTP 客户端抽象，便于测试注入 mock。
abstract class LlmHttpClient {
  /// POST 并逐行产出 SSE 的 data: 行（已去掉 "data: " 前缀，空行与 [DONE] 过滤）。
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body);
}

/// 基于 dart:io 的实现。生产与测试共用同一接口。
class IoLlmHttpClient implements LlmHttpClient {
  final HttpClient _http;
  IoLlmHttpClient([HttpClient? http]) : _http = http ?? HttpClient();

  @override
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body) async* {
    final req = await _http.postUrl(uri);
    headers.forEach((k, v) => req.headers.set(k, v));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      final sink = StringBuffer();
      await for (final c in resp.transform(utf8.decoder)) {
        sink.write(c);
      }
      throw LlmHttpException(resp.statusCode, sink.toString());
    }
    await for (final rawLine in resp.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!rawLine.startsWith('data:')) continue;
      final data = rawLine.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      yield data;
    }
  }
}

class LlmHttpException implements Exception {
  final int statusCode;
  final String body;
  const LlmHttpException(this.statusCode, this.body);
  @override
  String toString() => 'LlmHttpException($statusCode): $body';
}
