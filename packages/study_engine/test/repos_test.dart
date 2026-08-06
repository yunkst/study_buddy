import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

void main() {
  late StudyDatabase sdb;
  setUp(() async => sdb = await _fresh());
  tearDown(() async => await sdb.close());

  test('SubjectRepository.ensureCreate 幂等', () async {
    final repo = SubjectRepository(sdb);
    final s1 = await repo.ensureCreate('数学');
    final s2 = await repo.ensureCreate('数学');
    expect(s1.id, s2.id);
    expect(await repo.all(), hasLength(1));
  });

  test('TopicRepository 增查', () async {
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    final id = await topics.insert(Topic(
      subjectId: math.id!,
      domain: '代数',
      title: '一元二次方程',
      createdAt: DateTime.now(),
    ));
    final got = await topics.findById(id);
    expect(got?.title, '一元二次方程');
    expect(await topics.queryBySubject(math.id!), hasLength(1));
    expect(await topics.queryBySubject(math.id!, domain: '几何'), isEmpty);
  });
}
