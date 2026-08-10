/// Agent 工具 schema（OpenAI function calling）。知识点体系 6 个工具。
class AgentTools {
  AgentTools._();

  static const listTopics = {
    'type': 'function',
    'function': {
      'name': 'list_topics',
      'description': '分层浏览知识体系。传入 path 下钻到某分类，返回该层子分类和直挂知识点；不传 path 返回顶级分类。用于了解现有知识结构、为新建知识点找挂载位置。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '分类路径，用 / 分隔，如"数学/高等数学"。省略时返回顶级分类。'},
        },
      },
    },
  };

  static const searchTopics = {
    'type': 'function',
    'function': {
      'name': 'search_topics',
      'description': '按关键词搜索知识点（匹配标题、引子、内容）。用于判断某知识点是否已存在、避免重复录入。返回轻量列表（仅标题+id+路径）。',
      'parameters': {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string', 'description': '搜索关键词'},
          'offset': {'type': 'integer', 'description': '分页偏移，默认0'},
        },
        'required': ['keyword'],
      },
    },
  };

  static const getTopic = {
    'type': 'function',
    'function': {
      'name': 'get_topic',
      'description': '按 id 获取知识点完整详情，含引子、答案、关联边。用于查看已有知识点内容、判断是否需要更新。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '知识点 id'},
        },
        'required': ['id'],
      },
    },
  };

  static const saveTopic = {
    'type': 'function',
    'function': {
      'name': 'save_topic',
      'description': '保存一个细粒度知识点。知识点的粒度必须低：一个引子对应一个知识点，若内容需要多个引子才能讲清，应拆成多个知识点分别保存。学科/模块/章节不存在的会自动创建。title 全库唯一，重复会被拒绝。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '分类路径，如"数学/高等数学/极限"'},
          'title': {'type': 'string', 'description': '知识点标题，应简短且唯一可识别'},
          'question': {'type': 'string', 'description': '背诵引子，如"如何求0/0型极限?"'},
          'summary': {'type': 'string', 'description': '答案本体，背诵揭晓时展示的完整内容'},
        },
        'required': ['path', 'title', 'question', 'summary'],
      },
    },
  };

  static const updateTopic = {
    'type': 'function',
    'function': {
      'name': 'update_topic',
      'description': '更新已有知识点的答案本体(summary)。用于补充或修正已有知识点的答案。不改标题、引子、分类。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '知识点 id'},
          'summary': {'type': 'string', 'description': '新的答案本体'},
        },
        'required': ['id', 'summary'],
      },
    },
  };

  static const linkTopics = {
    'type': 'function',
    'function': {
      'name': 'link_topics',
      'description': '建立两个知识点之间的关联边。prerequisite=前置依赖(有向，from依赖to)；related=相关(无向)。仅在分析出明确的依赖/关联关系时使用。',
      'parameters': {
        'type': 'object',
        'properties': {
          'from': {'type': 'integer', 'description': '起点知识点 id(prerequisite 时为依赖方)'},
          'to': {'type': 'integer', 'description': '终点知识点 id(prerequisite 时为被依赖方)'},
          'type': {'type': 'string', 'enum': ['prerequisite', 'related']},
        },
        'required': ['from', 'to', 'type'],
      },
    },
  };

  static const studyTools = [listTopics, searchTopics, getTopic, saveTopic, updateTopic, linkTopics];
}
