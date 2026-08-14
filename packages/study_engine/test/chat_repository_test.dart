import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// chat_session / chat_message 持久化往返测试：
/// addMessage → loadMessages 还原（含 content 双层 JSON、tool_calls、图片剥离语义）。
void main() {
  setUpAll(sqfliteFfiInit);

  test('纯文本消息往返', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study_plan', '测试会话');
    final msg = ChatMessage(role: 'user', content: '你好');
    await repo.addMessage(sid, msg);

    final loaded = await repo.loadMessages(sid);
    expect(loaded, hasLength(1));
    expect(loaded.single.role, 'user');
    expect(loaded.single.content, '你好');
    expect(loaded.single.toolCalls, isNull);
    expect(loaded.single.toolCallId, isNull);
    await sdb.close();
  });

  test('工具调用消息往返（tool_calls + toolCallId 还原）', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study_plan', '测试');
    final assistant = ChatMessage(
      role: 'assistant',
      content: '',
      toolCalls: [
        const ToolCall(id: 'c1', name: 'save_topic', arguments: '{"title":"x"}'),
      ],
    );
    final tool = ChatMessage(
        role: 'tool', content: '已保存', toolCallId: 'c1');
    await repo.appendMessages(sid, [assistant, tool]);

    final loaded = await repo.loadMessages(sid);
    expect(loaded, hasLength(2));
    expect(loaded[0].toolCalls, hasLength(1));
    expect(loaded[0].toolCalls!.single.id, 'c1');
    expect(loaded[0].toolCalls!.single.name, 'save_topic');
    expect(loaded[0].toolCalls!.single.arguments, '{"title":"x"}');
    expect(loaded[1].toolCallId, 'c1');
    await sdb.close();
  });

  test('含图消息往返（content parts 还原，含 ImageUrlPart）', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study_plan', '测试');
    final msg = ChatMessage(role: 'user', content: [
      const TextPart('拍题'),
      const ImageUrlPart('data:image/png;base64,MTIz', detail: 'high'),
    ]);
    await repo.addMessage(sid, msg);

    final loaded = await repo.loadMessages(sid);
    final parts = loaded.single.content as List<ContentPart>;
    expect(parts, hasLength(2));
    expect((parts[0] as TextPart).text, '拍题');
    expect((parts[1] as ImageUrlPart).url, 'data:image/png;base64,MTIz');
    await sdb.close();
  });

  test('latestSession 按 updated_at 取最近会话', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = ChatRepository(sdb);
    final s1 = await repo.createSession('study_plan', '旧会话');
    final s2 = await repo.createSession('study_plan', '新会话');
    // 确保 s1 是「最近」：先 touch s2 再 touch s1（后 touch 者 updated_at 更大，
    // 由 touchSession 的 DateTime.now() 保证先后顺序，即使毫秒级间隔）
    await repo.touchSession(s2);
    await repo.touchSession(s1);

    final latest = await repo.latestSession('study_plan');
    expect(latest!.id, s1);
    // 不同 scenario 不混
    final other = await repo.createSession('other', '其他');
    await repo.touchSession(other);
    expect((await repo.latestSession('study_plan'))!.id, s1);
    expect((await repo.latestSession('other'))!.id, other);
    await sdb.close();
  });

  test('无会话时 latestSession 返回 null', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = ChatRepository(sdb);
    expect(await repo.latestSession('study_plan'), isNull);
    await sdb.close();
  });

  test('教学会话:createSession 带 topicId,findTeachingSession 命中且 latestSession 主线过滤', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = ChatRepository(sdb);
    // 一条主线（无 topicId）+ 一条教学（topicId=42）
    final mainlineId = await repo.createSession('study_plan', '主线');
    final teachingId =
        await repo.createSession('study_plan', '教学', topicId: 42);
    await repo.addMessage(mainlineId, const ChatMessage(role: 'user', content: '主线消息'));
    await repo.addMessage(teachingId, const ChatMessage(role: 'user', content: '教学消息'));

    // findTeachingSession 命中 topicId=42 的教学会话
    final found = await repo.findTeachingSession(42);
    expect(found, isNotNull);
    expect(found!.id, teachingId);
    // 未命中其他 topic
    expect(await repo.findTeachingSession(99), isNull);

    // latestSession 默认只回主线（不被教学会话污染）
    final latest = await repo.latestSession('study_plan');
    expect(latest!.id, mainlineId);

    // latestSession 关闭主线过滤时能看到教学会话
    final any = await repo.latestSession('study_plan', mainlineOnly: false);
    expect(any!.id, teachingId); // 教学会话更新晚，按 updated_at 排前
    await sdb.close();
  });
}
