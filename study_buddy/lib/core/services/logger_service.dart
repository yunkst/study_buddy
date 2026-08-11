import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:study_engine/study_engine.dart';

/// App 日志级别。index 顺序与 engine LoggerLevel 对齐。
enum LogLevel { debug, info, warning, error }

/// App 日志分类(study 业务域)。
enum LogCategory { database, ai, focus, plan, ui, general }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? stackTrace;
  final LogCategory category;
  final List<String> tags;
  final String? traceId;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.stackTrace,
    this.category = LogCategory.general,
    this.tags = const [],
    this.traceId,
  });

  Map<String, dynamic> toMap() => {
        'timestamp': timestamp.millisecondsSinceEpoch,
        'level': level.index,
        'message': message,
        'stackTrace': stackTrace,
        'category': category.index,
        'tags': tags,
        if (traceId != null) 'traceId': traceId,
      };

  factory LogEntry.fromMap(Map<String, dynamic> m) => LogEntry(
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
        level: LogLevel.values[m['level'] as int],
        message: m['message'] as String,
        stackTrace: m['stackTrace'] as String?,
        category: m.containsKey('category') ? LogCategory.values[m['category'] as int] : LogCategory.general,
        tags: m.containsKey('tags') ? (m['tags'] as List).cast<String>() : const [],
        traceId: m['traceId'] as String?,
      );
}

class LogStatistics {
  final int total;
  final Map<LogLevel, int> byLevel;
  final Map<LogCategory, int> byCategory;
  Map<LogLevel, double> get levelPercentage => total == 0
      ? {}
      : byLevel.map((l, c) => MapEntry(l, c / total));
  const LogStatistics({required this.total, required this.byLevel, required this.byCategory});
}

/// App 运行日志服务。单例。内存 1000 FIFO + SharedPreferences(文件回退)。
/// 实现 engine 的 [LoggerSink] 供 engine 模块上报。
class LoggerService implements LoggerSink {
  LoggerService._internal();
  static LoggerService? _instance;
  static LoggerService get instance => _instance ??= LoggerService._internal();

  static const int _maxLogs = 1000;
  static const String _prefsKey = 'app_logs';
  static const String _exportFileName = 'app_logs.txt';
  static const String _fallbackFileName = 'app_logs_fallback.json';
  static const Symbol _traceIdKey = #_logTraceId;
  static const int _flushIntervalMs = 1000;

  final List<LogEntry> _logs = [];
  bool _initialized = false;
  bool _isPersisting = false;
  bool _pendingPersist = false;
  DateTime? _lastPersistTime;
  Timer? _pendingFlushTimer;

  static ValueNotifier<int> _logChangeNotifier = ValueNotifier<int>(0);
  static ValueNotifier<int> get logChangeNotifier => _logChangeNotifier;

  static void resetForTesting() {
    _instance?._pendingFlushTimer?.cancel();
    _logChangeNotifier = ValueNotifier<int>(0);
    _instance = null;
  }

  // —— traceId Zone 传播 ——
  static String? get currentTraceId {
    try {
      return Zone.current[_traceIdKey] as String?;
    } catch (_) {
      return null;
    }
  }

  static Future<T> withTraceId<T>(String traceId, Future<T> Function() action) {
    return runZoned(action, zoneValues: {_traceIdKey: traceId});
  }

  // —— 初始化 ——
  Future<void> init() async {
    if (_initialized) return;
    await _loadLogs();
    _initialized = true;
  }

  // —— 级别便捷方法 ——
  void d(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace, String? traceId}) {
    if (kReleaseMode) return;
    _write(message, LogLevel.debug, stackTrace, category, tags, traceId: traceId);
  }

  void i(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace, String? traceId}) {
    _write(message, LogLevel.info, stackTrace, category, tags, traceId: traceId);
  }

  void w(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace, String? traceId}) {
    _write(message, LogLevel.warning, stackTrace, category, tags, traceId: traceId);
  }

  void e(String message, {LogCategory category = LogCategory.general, List<String> tags = const [], String? stackTrace, String? traceId}) {
    _write(message, LogLevel.error, stackTrace, category, tags, traceId: traceId);
  }

  // —— LoggerSink 接口实现(engine 调用)——
  @override
  void log(LoggerLevel level, String message,
      {String category = 'general', String? traceId, String? stackTrace, List<String> tags = const []}) {
    if (kReleaseMode && level == LoggerLevel.debug) return;
    _write(
      message,
      LogLevel.values[level.index],
      stackTrace,
      _parseCategory(category),
      tags,
      traceId: traceId ?? currentTraceId,
    );
  }

  LogCategory _parseCategory(String s) {
    switch (s) {
      case 'database': return LogCategory.database;
      case 'ai': return LogCategory.ai;
      case 'focus': return LogCategory.focus;
      case 'plan': return LogCategory.plan;
      case 'ui': return LogCategory.ui;
      default: return LogCategory.general;
    }
  }

  void _write(String message, LogLevel level, String? stackTrace, LogCategory category, List<String> tags,
      {String? traceId}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      stackTrace: stackTrace,
      category: category,
      tags: tags,
      traceId: traceId ?? currentTraceId,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogs) _logs.removeAt(0);
    _logChangeNotifier.value++;
    _schedulePersist();
  }

  // —— 查询 ——
  List<LogEntry> getLogs() => List.unmodifiable(_logs);
  List<LogEntry> getLogsByLevel([LogLevel? level]) =>
      level == null ? getLogs() : _logs.where((l) => l.level == level).toList();
  List<LogEntry> getLogsByCategory(LogCategory category) =>
      _logs.where((l) => l.category == category).toList();
  List<LogEntry> searchLogs(String query, {LogCategory? category}) {
    Iterable<LogEntry> r = _logs;
    if (category != null) r = r.where((l) => l.category == category);
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      r = r.where((l) => l.message.toLowerCase().contains(q) || l.tags.any((t) => t.toLowerCase().contains(q)));
    }
    return r.toList();
  }

  LogStatistics getStatistics() {
    final byLevel = {for (final l in LogLevel.values) l: 0};
    final byCategory = {for (final c in LogCategory.values) c: 0};
    for (final log in _logs) {
      byLevel[log.level] = byLevel[log.level]! + 1;
      byCategory[log.category] = byCategory[log.category]! + 1;
    }
    return LogStatistics(total: _logs.length, byLevel: byLevel, byCategory: byCategory);
  }

  int get logCount => _logs.length;

  Future<void> clearLogs() async {
    _logs.clear();
    await _persistLogs();
    _logChangeNotifier.value++;
  }

  Future<void> flush() async {
    if (_pendingPersist) await _persistChain();
  }

  Future<File> exportToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_exportFileName');
    final content = _logs.map((l) {
      final ts = formatTimestamp(l.timestamp);
      final st = l.stackTrace != null ? '\n${l.stackTrace}' : '';
      return '[$ts] [${l.level.name}] ${l.message}$st';
    }).join('\n\n---\n\n');
    await file.writeAsString(content, flush: true);
    return file;
  }

  static String formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  // —— 持久化(对齐 novel_builder)——
  void _schedulePersist() {
    _pendingPersist = true;
    final now = DateTime.now();
    if (_lastPersistTime == null || now.difference(_lastPersistTime!).inMilliseconds >= _flushIntervalMs) {
      _persistChain();
    } else {
      _pendingFlushTimer?.cancel();
      _pendingFlushTimer = Timer(const Duration(milliseconds: _flushIntervalMs), () {
        _pendingFlushTimer = null;
        _persistChain();
      });
    }
  }

  Future<void> _persistChain() async {
    if (_isPersisting) return;
    _isPersisting = true;
    try {
      while (_pendingPersist) {
        _pendingPersist = false;
        _lastPersistTime = DateTime.now();
        await _persistLogs();
      }
    } finally {
      _isPersisting = false;
    }
  }

  Future<void> _loadLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      if (json != null && json.isNotEmpty) {
        final decoded = jsonDecode(json) as List;
        _logs.addAll(decoded.map((e) => LogEntry.fromMap(e as Map<String, dynamic>)));
        return;
      }
    } catch (e) {
      debugPrint('LoggerService: SP 加载失败: $e');
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fallbackFileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content) as List;
          _logs.addAll(decoded.map((e) => LogEntry.fromMap(e as Map<String, dynamic>)));
        }
      }
    } catch (e) {
      debugPrint('LoggerService: 文件回退加载失败: $e');
    }
  }

  Future<void> _persistLogs() async {
    final data = jsonEncode(_logs.map((e) => e.toMap()).toList());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, data);
      return;
    } catch (e) {
      debugPrint('LoggerService: SP 写失败,回退文件: $e');
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fallbackFileName');
      await file.writeAsString(data, flush: true);
    } catch (e) {
      debugPrint('LoggerService: 文件回退也失败: $e');
    }
  }
}