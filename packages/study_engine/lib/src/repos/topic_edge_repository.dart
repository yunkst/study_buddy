import '../db/database.dart';
import '../logging/logger_sink.dart';

/// findByTopic 返回的边项：类型 + 对端 topic 的 id/title。
class TopicEdgeView {
  final String type;
  final int otherId;
  final String otherTitle;
  TopicEdgeView(this.type, this.otherId, this.otherTitle);
}

class TopicEdgeRepository {
  final StudyDatabase _db;
  TopicEdgeRepository(this._db);

  /// 建边。UNIQUE(from,to,type) 冲突时忽略（不报错）。
  Future<void> insert(int fromTopicId, int toTopicId, String type) async {
    try {
      await _db.db.insert('topic_edge', {
        'from_topic_id': fromTopicId,
        'to_topic_id': toTopicId,
        'type': type,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      // 仅忽略 UNIQUE 冲突；FK/锁/IO 等异常必须上抛，否则知识点图谱静默断链。
      if (!e.toString().contains('UNIQUE constraint failed')) rethrow;
      // 幂等：边已存在则忽略。记 debug 供排障确认「重复建边被吞」。
      _db.logger.log(LoggerLevel.debug,
          '知识点边重复被吞: $fromTopicId -> $toTopicId ($type)',
          category: 'database', tags: const ['idempotent-unique']);
    }
  }

  /// 双向查该 topic 参与的所有边（from 或 to 匹配）。
  Future<List<TopicEdgeView>> findByTopic(int topicId) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT e.type,
             CASE WHEN e.from_topic_id = ? THEN e.to_topic_id ELSE e.from_topic_id END AS other_id,
             t.title AS other_title
      FROM topic_edge e
      JOIN topic t ON t.id = CASE WHEN e.from_topic_id = ? THEN e.to_topic_id ELSE e.from_topic_id END
      WHERE e.from_topic_id = ? OR e.to_topic_id = ?
      ''',
      [topicId, topicId, topicId, topicId],
    );
    return rows.map((r) => TopicEdgeView(r['type'] as String, r['other_id'] as int, r['other_title'] as String)).toList();
  }
}
