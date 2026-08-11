import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';

import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/providers/llm_config_provider.dart';

Future<ProviderContainer> _boot() async {
  sqfliteFfiInit();
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWith((ref) async {
      final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      ref.onDispose(() => sdb.close());
      return sdb;
    }),
  ]);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  test('首次 build:表为空时种子一条默认配置', () async {
    final container = await _boot();
    addTearDown(container.dispose);
    final cfg = await container.read(llmConfigProvider.future);
    expect(cfg, isNotNull);
    expect(cfg!.name, '默认配置');
    expect(cfg.isDefault, isTrue);
    expect(cfg.supportsVision, isTrue);
    // 种子后表里确实有一行
    final db = await container.read(databaseProvider.future);
    final rows = await db.db.query('llm_config');
    expect(rows, hasLength(1));
  });

  test('save 更新现有配置,下次读取为新值', () async {
    final container = await _boot();
    addTearDown(container.dispose);
    final initial = await container.read(llmConfigProvider.future);
    expect(initial, isNotNull);
    final saved = await container
        .read(llmConfigProvider.notifier)
        .save(initial!.copyWith(
          apiUrl: 'https://api.example.com/v1',
          apiKey: 'tok-123',
          model: 'gpt-4o',
          name: '我的模型',
        ));
    expect(saved.apiUrl, 'https://api.example.com/v1');
    expect(saved.apiKey, 'tok-123');
    // invalidate 后重新读取,拿到的是落库后的新值
    container.invalidate(llmConfigProvider);
    final reread = await container.read(llmConfigProvider.future);
    expect(reread?.model, 'gpt-4o');
    expect(reread?.name, '我的模型');
    // 表里仍只有一行(非新增)
    final db = await container.read(databaseProvider.future);
    expect(await db.db.query('llm_config'), hasLength(1));
  });
}
