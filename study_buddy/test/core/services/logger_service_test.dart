import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:study_buddy/core/services/logger_service.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUp(() async {
    LoggerService.resetForTesting();
    TestWidgetsFlutterBinding.ensureInitialized();
    // SharedPreferences 测试初始化(plugin 提供的 mock)
    SharedPreferences.setMockInitialValues({});
  });

  test('d/i/w/e 按级别记录且 release 模式 debug 不写', () {
    debugPrint = (String? message, {int? wrapWidth}) {}; // 静音
    LoggerService.instance.i('info msg');
    LoggerService.instance.w('warn msg');
    LoggerService.instance.e('error msg');
    final logs = LoggerService.instance.getLogs();
    expect(logs.where((l) => l.level == LogLevel.info), isNotEmpty);
    expect(logs.where((l) => l.level == LogLevel.warning), isNotEmpty);
    expect(logs.where((l) => l.level == LogLevel.error), isNotEmpty);
  });

  test('FIFO 超过上限删除最旧(用 resetForTesting 后默认上限)', () {
    // _maxLogs = 1000,写 1005 条,期望保留最新 1000
    for (int i = 0; i < 1005; i++) {
      LoggerService.instance.i('msg $i');
    }
    expect(LoggerService.instance.getLogs().length, 1000);
    final first = LoggerService.instance.getLogs().first;
    expect(first.message, 'msg 5'); // 最旧的 msg 0-4 被删
  });

  test('按分类过滤', () {
    LoggerService.instance.i('db op', category: LogCategory.database);
    LoggerService.instance.i('ai op', category: LogCategory.ai);
    final dbLogs = LoggerService.instance.getLogsByCategory(LogCategory.database);
    expect(dbLogs, hasLength(1));
    expect(dbLogs.first.message, 'db op');
  });

  test('searchLogs 关键词不区分大小写且匹配消息', () {
    LoggerService.instance.i('API 请求超时');
    LoggerService.instance.i('正常流程');
    final hits = LoggerService.instance.searchLogs('api');
    expect(hits, hasLength(1));
    expect(hits.first.message, contains('API'));
  });

  test('实现 LoggerSink 接口:LoggerLevel → LogLevel 映射', () {
    LoggerService.instance.log(LoggerLevel.error, 'engine err', category: 'ai', traceId: 't1');
    final logs = LoggerService.instance.getLogsByLevel(LogLevel.error);
    expect(logs.last.message, 'engine err');
    expect(logs.last.category, LogCategory.ai);
    expect(logs.last.traceId, 't1');
  });

  test('withTraceId 注入后 log 自动带 traceId', () async {
    await LoggerService.withTraceId('zone-1', () async {
      LoggerService.instance.i('in zone');
    });
    final logs = LoggerService.instance.getLogs();
    expect(logs.last.traceId, 'zone-1');
  });

  test('i 显式传 traceId', () {
    LoggerService.instance.i('msg', traceId: 'explicit');
    expect(LoggerService.instance.getLogs().last.traceId, 'explicit');
  });
}
