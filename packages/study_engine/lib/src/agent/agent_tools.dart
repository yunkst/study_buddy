/// Agent 工具 schema（OpenAI function calling）。地基阶段 2 个工具。
class AgentTools {
  AgentTools._();

  static const saveTopic = {
    'type': 'function',
    'function': {
      'name': 'save_topic',
      'description': '保存一个知识点到知识库。若指定学科不存在会自动创建。'
          '用于在分析题目或讲解后，把涉及的知识点入库。',
      'parameters': {
        'type': 'object',
        'properties': {
          'subject': {'type': 'string', 'description': '学科名，如“数学”“物理”'},
          'title': {'type': 'string', 'description': '知识点标题'},
          'domain': {'type': 'string', 'description': '学科内领域，如“代数”，可省略'},
          'summary': {'type': 'string', 'description': '知识点摘要，可省略'},
        },
        'required': ['subject', 'title'],
      },
    },
  };

  static const queryTopics = {
    'type': 'function',
    'function': {
      'name': 'query_topics',
      'description': '查询知识库中已保存的知识点列表，可按学科和领域过滤。',
      'parameters': {
        'type': 'object',
        'properties': {
          'subject': {'type': 'string', 'description': '学科名'},
          'domain': {'type': 'string', 'description': '领域，可省略'},
        },
        'required': ['subject'],
      },
    },
  };

  static const studyTools = [saveTopic, queryTopics];
}
