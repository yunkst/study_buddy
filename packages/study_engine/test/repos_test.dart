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

  test('MasteryRepository 日志驱动当前状态', () async {
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final mastery = MasteryRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    final tid = await topics.insert(Topic(subjectId: math.id!, title: 't', createdAt: DateTime.now()));

    expect(await mastery.currentStatus(tid), MasteryStatus.unknown);
    await mastery.log(tid, MasteryStatus.learning);
    await mastery.log(tid, MasteryStatus.mastered);
    expect(await mastery.currentStatus(tid), MasteryStatus.mastered);
    expect(await mastery.timeline(tid), hasLength(2));
  });

  test('TopicDomainRepository 增查', () async {
    final subjects = SubjectRepository(sdb);
    final domains = TopicDomainRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    await domains.insert(TopicDomain(subjectId: math.id!, name: '代数', createdAt: DateTime.now()));
    expect(await domains.queryBySubject(math.id!), hasLength(1));
  });
}
