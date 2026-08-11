// study_buddy/lib/core/services/llm_logger/llm_logger.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, ValueNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:study_engine/study_engine.dart';

import 'llm_call_record.dart';

class LlmLogger implements LlmCallSink {
  LlmLogger._internal();
  static LlmLogger? _instance;
  static LlmLogger get instance => _instance ??= LlmLogger._internal();

  static void resetForTesting() {
    _instance = null;
    changeNotifier.value = 0;
  }

  static final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  static const String _logDirName = 'llm_logs';
  static const String _logFilePrefix = 'llm_';
  static const int _retentionDays = 7;
  static const int _maxResponseLength = 5 * 1024 * 1024;
  static const int _cacheSize = 200;

  String? _logDir;
  bool _initialized = false;
  final List<String> _writeQueue = [];
  bool _isWriting = false;
  final List<LlmCallRecord> _recentCache = [];
  int _changeCount = 0;
  int _idCounter = 0;

  /// 测试用:初始化到临时目录。生产用 initialize()。
  Future<void> initializeForTest() async {
    _logDir = null; // 测试不写文件,onResponse 仅更新缓存
    _initialized = true;
    _recentCache.clear();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _logDir = '${docs.path}/$_logDirName';
      await Directory(_logDir!).create(recursive: true);
      await _cleanOldFiles();
      await _loadRecentCache();
      _initialized = true;
    } catch (e) {
      debugPrint('LlmLogger: 初始化失败: $e');
    }
  }

  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) {
    final id = 'llm-${DateTime.now().millisecondsSinceEpoch}-${_idCounter++}';
    final record = LlmCallRecord(
      id: id,
      timestamp: DateTime.now().toUtc(),
      endpoint: endpoint,
      model: model,
      isStreaming: isStreaming,
      requestBody: requestBody,
      isSuccess: false,
      traceId: traceId,
    );
    _updateCache(record);
    return id;
  }

  @override
  void onResponse(String id,
      {required String responseBody,
      required int durationMs,
      required bool isSuccess,
      String? errorMessage,
      int? promptTokens,
      int? completionTokens,
      int? totalTokens}) {
    final truncated = responseBody.length > _maxResponseLength
        ? '${responseBody.substring(0, _maxResponseLength)}...(truncated at $_maxResponseLength bytes)'
        : responseBody;
    final idx = _recentCache.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      final updated = _recentCache[idx].copyWith(
        responseBody: truncated,
        durationMs: durationMs,
        isSuccess: isSuccess,
        errorMessage: errorMessage,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: totalTokens,
      );
      _recentCache[idx] = updated;
      _enqueueWrite(updated);
    }
    _changeCount++;
    changeNotifier.value = _changeCount;
  }

  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {
    final idx = _recentCache.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      final updated = _recentCache[idx].copyWith(
        durationMs: durationMs,
        isSuccess: false,
        errorMessage: errorMessage,
      );
      _recentCache[idx] = updated;
      _enqueueWrite(updated);
    }
    _changeCount++;
    changeNotifier.value = _changeCount;
  }

  Future<List<LlmCallRecord>> getRecent({int limit = 50}) async {
    if (_recentCache.length >= limit) return _recentCache.sublist(0, limit);
    final fromFile = await _readRecentFromFile(limit - _recentCache.length);
    return [..._recentCache, ...fromFile];
  }

  Future<LlmCallRecord?> getById(String id) async {
    final cached = _recentCache.where((r) => r.id == id).firstOrNull;
    if (cached != null) return cached;
    return _findByIdInFiles(id);
  }

  Future<void> clear() async {
    _recentCache.clear();
    _writeQueue.clear();
    _changeCount++;
    changeNotifier.value = _changeCount;
    if (_logDir == null) return;
    try {
      final dir = Directory(_logDir!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('LlmLogger: 清空失败: $e');
    }
  }

  Future<int> getTotalSize() async {
    if (_logDir == null) return 0;
    int total = 0;
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  void _updateCache(LlmCallRecord r) {
    final idx = _recentCache.indexWhere((x) => x.id == r.id);
    if (idx >= 0) {
      _recentCache[idx] = r;
    } else {
      _recentCache.insert(0, r);
      if (_recentCache.length > _cacheSize) _recentCache.removeLast();
    }
  }

  void _enqueueWrite(LlmCallRecord r) {
    if (_logDir == null) return; // 测试模式不落盘
    _writeQueue.add(jsonEncode(r.toJson()));
    _flushWriteQueue();
  }

  Future<void> _flushWriteQueue() async {
    if (_isWriting || _writeQueue.isEmpty || _logDir == null) return;
    _isWriting = true;
    try {
      final lines = List<String>.from(_writeQueue);
      _writeQueue.clear();
      final today = _dateStr(DateTime.now().toUtc());
      final file = File('$_logDir/$_logFilePrefix$today.jsonl');
      final content = lines.join('\n');
      if (await file.exists()) {
        await file.writeAsString('\n$content', mode: FileMode.append, flush: true);
      } else {
        await file.writeAsString(content, flush: true);
      }
    } catch (e) {
      debugPrint('LlmLogger: 写入失败: $e');
    } finally {
      _isWriting = false;
      if (_writeQueue.isNotEmpty) _flushWriteQueue();
    }
  }

  Future<void> _cleanOldFiles() async {
    if (_logDir == null) return;
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().toUtc().subtract(const Duration(days: _retentionDays));
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.jsonl')) {
          final name = p.basename(e.path);
          final dateStr = name.replaceAll(_logFilePrefix, '').replaceAll('.jsonl', '');
          try {
            final y = int.parse(dateStr.substring(0, 4));
            final m = int.parse(dateStr.substring(4, 6));
            final d = int.parse(dateStr.substring(6, 8));
            if (DateTime.utc(y, m, d).isBefore(cutoff)) await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _loadRecentCache() async {
    final records = await _readRecentFromFile(_cacheSize);
    _recentCache.addAll(records);
  }

  Future<List<LlmCallRecord>> _readRecentFromFile(int limit) async {
    if (_logDir == null) return [];
    final records = <LlmCallRecord>[];
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return [];
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.jsonl')) files.add(e);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final file in files) {
        if (records.length >= limit) break;
        final content = await file.readAsString();
        for (final line in content.split('\n').where((l) => l.trim().isNotEmpty)) {
          if (records.length >= limit) break;
          try {
            records.add(LlmCallRecord.fromJson(jsonDecode(line) as Map<String, dynamic>));
          } catch (_) {}
        }
      }
    } catch (_) {}
    return records;
  }

  Future<LlmCallRecord?> _findByIdInFiles(String id) async {
    if (_logDir == null) return null;
    try {
      final dir = Directory(_logDir!);
      if (!await dir.exists()) return null;
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.jsonl')) continue;
        final content = await e.readAsString();
        for (final line in content.split('\n').reversed) {
          if (line.trim().isEmpty) continue;
          try {
            final j = jsonDecode(line) as Map<String, dynamic>;
            if (j['id'] == id) return LlmCallRecord.fromJson(j);
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  static String _dateStr(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}';
  }
}
