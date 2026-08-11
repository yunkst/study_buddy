// packages/study_engine/lib/src/logging/logger_sink.dart

/// 日志级别。枚举 index 顺序与 app 层 LogLevel 对齐,
/// app 侧用 `LogLevel.values[level.index]` 直接映射。
enum LoggerLevel { debug, info, warning, error }

/// App 运行日志出口。engine 各模块通过此接口上报,默认 [NullLoggerSink]。
///
/// [category] 为字符串(非枚举):engine 不定义业务分类,由 app 约定
/// (study 用 database/ai/focus/plan/ui/general),engine 只透传。
abstract class LoggerSink {
  void log(
    LoggerLevel level,
    String message, {
    String category = 'general',
    String? traceId,
    String? stackTrace,
    List<String> tags = const [],
  });
}

/// noop 实现:engine 测试与未注入时使用。零开销,const 构造。
class NullLoggerSink implements LoggerSink {
  const NullLoggerSink();

  @override
  void log(
    LoggerLevel level,
    String message, {
    String category = 'general',
    String? traceId,
    String? stackTrace,
    List<String> tags = const [],
  }) {}
}