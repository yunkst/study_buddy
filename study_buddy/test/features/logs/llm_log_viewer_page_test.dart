import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/llm_logger/llm_logger.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/logs/llm_log_viewer_page.dart';

void main() {
  setUp(() {
    // 隔离单例:每个测试从全新 LlmLogger 实例起步。
    LlmLogger.resetForTesting();
  });

  testWidgets('渲染 LLM 日志列表', (tester) async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: 'e',
      model: 'gpt',
      requestBody: '{"messages":[{"content":"问"}]}',
      isStreaming: true,
    );
    LlmLogger.instance.onResponse(id,
        responseBody: 'r', durationMs: 100, isSuccess: true, totalTokens: 5);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const LlmLogViewerPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('gpt'), findsOneWidget);
    expect(find.textContaining('问'), findsWidgets);
  });

  testWidgets('空状态显示占位文案', (tester) async {
    await LlmLogger.instance.initializeForTest();
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const LlmLogViewerPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无 LLM 调用记录'), findsOneWidget);
  });

  testWidgets('失败请求显示错误图标与失败状态', (tester) async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: 'ep',
      model: 'm',
      requestBody: '{"messages":[{"content":"boom"}]}',
      isStreaming: false,
    );
    LlmLogger.instance.onResponse(id,
        responseBody: '',
        durationMs: 50,
        isSuccess: false,
        errorMessage: 'timeout');
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const LlmLogViewerPage()),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.text('m'), findsOneWidget);
  });
}
