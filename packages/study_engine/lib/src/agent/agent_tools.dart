/// Agent 工具 schema（OpenAI function calling）。知识点体系 12 个工具（含删除）。
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
      'description': '保存一个细粒度、普遍性的知识点。知识点的粒度必须低：一个引子对应一个知识点，若内容需要多个引子才能讲清，应拆成多个知识点分别保存。**内容必须是脱离具体题目的通用规律，而非某道题本身**：question/summary/title 一律抽象成一般情形，不得出现题目的具体数字、专有量、选项、答案或题干原文。学科/模块/章节不存在的会自动创建。title 全库唯一，重复会被拒绝。返回 JSON {id, is_new, msg}：is_new=true 表示新建成功并返回新 id；is_new=false 表示该知识点已存在（id 为已有记录 id），此时如需补充答案请改用 update_topic；path 为空时 id=null。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '分类路径，如"数学/高等数学/极限"'},
          'title': {'type': 'string', 'description': '知识点标题，应简短、唯一可识别，且用一般概念命名（如"洛必达法则"），不要照搬题干'},
          'question': {'type': 'string', 'description': '背诵引子，用一般化提问（如"如何求0/0型未定式极限?"）。禁止复述原题、抄录题干数值或选项。会被渲染展示，支持 Markdown 与 LaTeX 公式（行内 \$...\$、块级 \$\$...\$\$）。'},
          'summary': {'type': 'string', 'description': '答案本体（通用规律/方法/定义）。必须是对该类问题的通用解法或原理，绝不抄录某道题的具体答案或带具体数字的解题过程。会被渲染展示（知识点详情/对话同样式），支持 Markdown（标题/列表/加粗/表格/代码块）与 LaTeX 公式（行内 \$...\$、块级 \$\$...\$\$，如 \$\\lim_{x\\to0}\\frac{\\sin x}{x}=1\$）。'},
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
          'summary': {'type': 'string', 'description': '新的答案本体。会被渲染展示，支持 Markdown 与 LaTeX 公式（行内 \$...\$、块级 \$\$...\$\$）。'},
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

  static const setMastery = {
    'type': 'function',
    'function': {
      'name': 'set_mastery',
      'description': '记录某知识点/技巧的掌握程度(基于一次作答或复习判定)。映射规则:全对→升一级(unknown/weak→learning、learning→mastered、mastered 保持);部分对→learning(已 mastered 则回退 learning);全错→weak。reason 必填,写明判定依据。',
      'parameters': {
        'type': 'object',
        'properties': {
          'topic_id': {'type': 'integer', 'description': '知识点/技巧 id'},
          'status': {'type': 'string', 'enum': ['learning', 'mastered', 'weak'], 'description': '目标掌握状态'},
          'reason': {'type': 'string', 'description': '判定依据,如"洛必达题答错:混淆适用条件"'},
        },
        'required': ['topic_id', 'status', 'reason'],
      },
    },
  };

  static const getMastery = {
    'type': 'function',
    'function': {
      'name': 'get_mastery',
      'description': '查询某知识点/技巧的当前掌握程度与最近变更历史。批改前了解现状以决定如何调整。',
      'parameters': {
        'type': 'object',
        'properties': {
          'topic_id': {'type': 'integer', 'description': '知识点/技巧 id'},
        },
        'required': ['topic_id'],
      },
    },
  };

  static const saveReview = {
    'type': 'function',
    'function': {
      'name': 'save_review',
      'description': '批改完成后保存结构化批改明细(逐题对错/解析/涉及知识点),供卡片展示与复盘对话。调用后前端渲染批改卡片,用户可点进查看、继续探讨。与 set_mastery 各司其职:set_mastery 写掌握度日志,save_review 写批改明细。',
      'parameters': {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string', 'description': '批改摘要,如"批改3题,对1错2,薄弱:洛必达适用条件"'},
          'items': {
            'type': 'array',
            'description': '逐题明细',
            'items': {
              'type': 'object',
              'properties': {
                'seq': {'type': 'integer', 'description': '题序,从1开始'},
                'question': {'type': 'string', 'description': '题目文本'},
                'user_answer': {'type': 'string', 'description': '用户作答(可空)'},
                'verdict': {'type': 'string', 'enum': ['correct', 'partial', 'wrong'], 'description': '判定'},
                'analysis': {'type': 'string', 'description': '解析'},
                'topic_ids': {'type': 'array', 'items': {'type': 'integer'}, 'description': '涉及知识点 id 列表'},
              },
              'required': ['seq', 'question', 'verdict', 'analysis'],
            },
          },
        },
        'required': ['summary', 'items'],
      },
    },
  };

  static const deleteTopic = {
    'type': 'function',
    'function': {
      'name': 'delete_topic',
      'description': '删除一个知识点（高危、不可逆）。关联的掌握度日志/复习调度/知识图谱边会一并清除。'
          '删除前必须先用 search_topics/get_topic 确认目标，并通过 ask_user 向用户确认后再调用。'
          '二选一传入 id（精确）或 title（精确匹配全库唯一标题）。返回 JSON {ok, deleted, msg}。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '要删除的知识点 id（与 title 二选一，优先用 id）'},
          'title': {'type': 'string', 'description': '要删除的知识点标题（精确全名，与 id 二选一）'},
        },
      },
    },
  };

  static const deleteCategory = {
    'type': 'function',
    'function': {
      'name': 'delete_category',
      'description': '删除一个分类及其整棵子树（高危、不可逆）：含其全部后代分类、各层直挂知识点，'
          '以及知识点关联的掌握度/调度/图谱边。删除前必须先用 list_topics 浏览确认范围，'
          '明确告知用户「将删除 X 及其下 N 个子分类、M 个知识点」，并通过 ask_user 确认后再调用。'
          '按 path 精确匹配到末端分类。返回 JSON {ok, deleted_categories, deleted_topics, msg}。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '分类路径，如"数学/高等数学"，删除该路径末端分类的整棵子树'},
        },
        'required': ['path'],
      },
    },
  };

  static const recommendTopics = {
    'type': 'function',
    'function': {
      'name': 'recommend_topics',
      'description': '向用户推荐知识库中与当前话题相关的知识点。回答完用户问题后,若知识库中已存在相关知识点,'
          '调用本工具把它们以可点击卡片展示给用户(复习/跳转详情)。按 keyword 在库中检索'
          '(匹配标题、引子、答案,标题命中的优先展示)。只读工具,不修改任何数据。'
          '返回省略时表示未找到相关知识点,不要在回复中编造。',
      'parameters': {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string', 'description': '与用户当前问题/话题相关的检索词,应提炼为库中可能存在的知识点概念名,如"洛必达法则"'},
        },
        'required': ['keyword'],
      },
    },
  };

  static const studyTools = [
    listTopics,
    searchTopics,
    getTopic,
    saveTopic,
    updateTopic,
    linkTopics,
    setMastery,
    getMastery,
    saveReview,
    deleteTopic,
    deleteCategory,
    recommendTopics,
  ];
}
