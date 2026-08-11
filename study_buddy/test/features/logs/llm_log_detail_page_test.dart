import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/llm_logger/llm_logger.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/logs/llm_log_detail_page.dart';

void main() {
  setUp(() {
    LlmLogger.resetForTesting();
  });

  testWidgets('渲染详情:摘要 + 请求体 + 响应体', (tester) async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: '/v1/chat',
      model: 'gpt-4',
      requestBody: '{"messages":[{"content":"hello"}]}',
      isStreaming: true,
      traceId: 'trace-1',
    );
    LlmLogger.instance.onResponse(id,
        responseBody: '{"content":"hi"}',
        durationMs: 1200,
        isSuccess: true,
        totalTokens: 10);

    await tester.pumpWidget(
      MaterialApp(
          theme: AppTheme.light, home: LlmLogDetailPage(recordId: id)),
    );
    await tester.pumpAndSettle();

    // 摘要行
    expect(find.text('gpt-4'), findsOneWidget);
    expect(find.text('/v1/chat'), findsOneWidget);
    expect(find.text('是'), findsOneWidget); // 流式=是
    expect(find.text('成功'), findsOneWidget); // 状态
    expect(find.text('trace-1'), findsOneWidget);
    // 区段标题
    expect(find.text('请求体'), findsOneWidget);
    expect(find.text('响应体'), findsOneWidget);
  });

  testWidgets('未找到记录时显示占位', (tester) async {
    await LlmLogger.instance.initializeForTest();
    await tester.pumpWidget(
      MaterialApp(
          theme: AppTheme.light,
          home: const LlmLogDetailPage(recordId: 'no-such-id')),
    );
    await tester.pumpAndSettle();
    expect(find.text('未找到该记录'), findsOneWidget);
  });

  testWidgets('失败记录的响应体区段标记失败并展示 errorMessage', (tester) async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: 'ep',
      model: 'm',
      requestBody: '{"messages":[{"content":"q"}]}',
      isStreaming: false,
    );
    LlmLogger.instance.onResponse(id,
        responseBody: '',
        durationMs: 30,
        isSuccess: false,
        errorMessage: 'connection-reset');

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: LlmLogDetailPage(recordId: id)),
    );
    await tester.pumpAndSettle();

    expect(find.text('失败'), findsOneWidget); // 状态行
    expect(find.text('响应体(失败)'), findsOneWidget);
    expect(find.text('connection-reset'), findsWidgets);
  });
}
