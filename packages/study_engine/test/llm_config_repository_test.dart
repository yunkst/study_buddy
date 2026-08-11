import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  late StudyDatabase sdb;
  late LlmConfigRepository repo;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = LlmConfigRepository(sdb);
  });

  tearDown(() async => sdb.close());

  LlmConfig makeConfig({
    String name = '默认',
    String apiUrl = 'https://api.openai.com/v1',
    String apiKey = 'sk-test',
    String model = 'gpt-4o-mini',
    bool supportsVision = false,
    bool isDefault = false,
    int sortOrder = 0,
  }) =>
      LlmConfig(
        name: name,
        apiUrl: apiUrl,
        apiKey: apiKey,
        model: model,
        supportsVision: supportsVision,
        isDefault: isDefault,
        sortOrder: sortOrder,
        createdAt: DateTime.now(),
      );

  group('LlmConfigRepository', () {
    test('insert 一条 is_default=1 → getDefault 返回它', () async {
      await repo.insert(makeConfig(isDefault: true));
      final got = await repo.getDefault();
      expect(got, isNotNull);
      expect(got!.isDefault, isTrue);
      expect(got.apiKey, 'sk-test');
    });

    test('insert 两条，第二条 is_default=1 → getDefault 返回 is_default=1 那条', () async {
      await repo.insert(makeConfig(name: 'A', apiKey: 'sk-a', isDefault: false, sortOrder: 0));
      await repo.insert(makeConfig(name: 'B', apiKey: 'sk-b', isDefault: true, sortOrder: 1));
      final got = await repo.getDefault();
      expect(got, isNotNull);
      expect(got!.apiKey, 'sk-b');
    });

    test('getDefault(vision:true) 在 supports_vision=0 的默认下回退到普通默认', () async {
      await repo.insert(makeConfig(supportsVision: false, isDefault: true));
      final got = await repo.getDefault(vision: true);
      expect(got, isNotNull);
      expect(got!.supportsVision, isFalse);
    });
  });
}