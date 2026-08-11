/// 学习计划 Agent 工具 schema（OpenAI function calling）。7 个工具管理计划全生命周期。
class PlanTools {
  PlanTools._();

  static const createPlan = {
    'type': 'function',
    'function': {
      'name': 'create_plan',
      'description': '创建一个学习计划。必须收齐 name/exam_date/exam_content/target/daily_minutes/current_level 六项，缺任何一项要先追问用户补齐。创建后会自动把 current_level 解析成分数生成第一条测评记录作为起点。',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '计划名，如"考研冲刺"'},
          'exam_date': {'type': 'string', 'description': '考试日期，YYYY-MM-DD'},
          'exam_content': {'type': 'string', 'description': '考试内容/范围，如"政治、英语一、数学一、408"'},
          'target': {'type': 'string', 'description': '目标，如"总分 380"或"过六级"'},
          'daily_minutes': {'type': 'integer', 'description': '每日可学习时长（分钟）'},
          'current_level': {'type': 'string', 'description': '当前自评水平，如"做真题估 300 分，数学最弱"'},
        },
        'required': ['name', 'exam_date', 'exam_content', 'target', 'daily_minutes', 'current_level'],
      },
    },
  };

  static const getPlan = {
    'type': 'function',
    'function': {
      'name': 'get_plan',
      'description': '获取计划完整结构：元信息 + 所有里程碑节点 + 所有测评记录。用于了解当前计划全貌、为调整做判断。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
        },
        'required': ['plan_id'],
      },
    },
  };

  static const updatePlan = {
    'type': 'function',
    'function': {
      'name': 'update_plan',
      'description': '更新计划元信息（名称/考试日期/内容/目标/每日时长）。只传需要改的字段。改目标时建议联动调整节点分数预期。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
          'name': {'type': 'string', 'description': '新计划名（可选）'},
          'exam_date': {'type': 'string', 'description': '新考试日期 YYYY-MM-DD（可选）'},
          'exam_content': {'type': 'string', 'description': '新考试内容（可选）'},
          'target': {'type': 'string', 'description': '新目标（可选）'},
          'daily_minutes': {'type': 'integer', 'description': '新每日时长分钟（可选）'},
        },
        'required': ['plan_id'],
      },
    },
  };

  static const addMilestone = {
    'type': 'function',
    'function': {
      'name': 'add_milestone',
      'description': '给计划新增一个里程碑节点。description 要写清达到什么程度算完成。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
          'title': {'type': 'string', 'description': '节点名，如"数学基础过完"'},
          'description': {'type': 'string', 'description': '完成标志，如"高数+线代基础课听完，能独立做基础题"'},
          'target_date': {'type': 'string', 'description': '目标完成日期 YYYY-MM-DD'},
          'sort_order': {'type': 'integer', 'description': '顺序，默认0'},
        },
        'required': ['plan_id', 'title', 'description', 'target_date'],
      },
    },
  };

  static const updateMilestone = {
    'type': 'function',
    'function': {
      'name': 'update_milestone',
      'description': '更新里程碑节点（标题/描述/日期/顺序/状态）。status 只能是 pending 或 done。只传需要改的字段。',
      'parameters': {
        'type': 'object',
        'properties': {
          'milestone_id': {'type': 'integer', 'description': '节点 id'},
          'title': {'type': 'string', 'description': '新标题（可选）'},
          'description': {'type': 'string', 'description': '新描述（可选）'},
          'target_date': {'type': 'string', 'description': '新目标日期 YYYY-MM-DD（可选）'},
          'sort_order': {'type': 'integer', 'description': '新顺序（可选）'},
          'status': {'type': 'string', 'enum': ['pending', 'done'], 'description': '新状态（可选）'},
        },
        'required': ['milestone_id'],
      },
    },
  };

  static const deleteMilestone = {
    'type': 'function',
    'function': {
      'name': 'delete_milestone',
      'description': '删除一个里程碑节点。删除前应向用户确认一句。',
      'parameters': {
        'type': 'object',
        'properties': {
          'milestone_id': {'type': 'integer', 'description': '节点 id'},
        },
        'required': ['milestone_id'],
      },
    },
  };

  static const addAssessment = {
    'type': 'function',
    'function': {
      'name': 'add_assessment',
      'description': '记录一次测评（用户做真题/模考后报分时调用）。score 为分数，note 为备注（可选）。assessed_at 不传默认今天。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
          'score': {'type': 'integer', 'description': '分数。无法量化时传 null 并在 note 里记录定性进展'},
          'note': {'type': 'string', 'description': '备注（可选），如"线代大题崩了"'},
          'assessed_at': {'type': 'string', 'description': '测评日期 YYYY-MM-DD，不传默认今天（可选）'},
        },
        'required': ['plan_id', 'score'],
      },
    },
  };

  static const planTools = [
    createPlan, getPlan, updatePlan, addMilestone, updateMilestone, deleteMilestone, addAssessment,
  ];
}
