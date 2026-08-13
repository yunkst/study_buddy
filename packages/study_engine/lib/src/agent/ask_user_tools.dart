/// ask_user 工具 schema：让 agent 主动向用户提问并等待结构化回答。
///
/// 挂到 study 与 plan 两个场景的工具列表末尾（见 [studyToolsWithAsk]、
/// [planToolsWithAsk]）。工具 schema 共享同一个 [askUser] 实例，零复制。
library;

import 'agent_tools.dart';
import 'plan_tools.dart';

class AskUserTools {
  AskUserTools._();

  static const askUser = {
    'type': 'function',
    'function': {
      'name': 'ask_user',
      'description': '当执行任务需要用户做出选择或补充信息（如确认字段、决定方向）时，调用本工具暂停并向用户提问。'
          '传入 question（给用户看的提问）、options（1-4 个选项，每个含 label 按钮文案 / value 实际值 / description 可省说明）。'
          'multi_select=true 时用户可勾选多个；options 不传或传空数组时退化为必答自由输入（用户键入文本作为答案）。'
          '工具返回的 result 就是用户选中的 value（多选用", "分隔拼接），请直接据此继续后续动作，不要再重复提问。'
          '一次只问一件事，不要把多个问题塞进同一个 question；能推断的字段不要问，只问真正需要用户决定的。',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string', 'description': '给用户看的提问文案'},
          'header': {'type': 'string', 'description': '卡片左上角小标题（可省，默认截取 question 前 12 字）'},
          'options': {
            'type': 'array',
            'description': '选项列表（1-4 个）。不传或空数组=退化为必答自由输入。value 应简短且避免含逗号。',
            'items': {
              'type': 'object',
              'properties': {
                'label': {'type': 'string', 'description': '按钮显示文案'},
                'value': {'type': 'string', 'description': '实际值，会作为工具结果回灌给 LLM'},
                'description': {'type': 'string', 'description': '选项下方的补充说明（可省）'},
              },
              'required': ['label', 'value'],
            },
          },
          'multi_select': {'type': 'boolean', 'description': '是否允许多选，默认 false（单选）'},
        },
        'required': ['question'],
      },
    },
  };

  /// study 场景工具集：知识点 9 工具 + ask_user。
  static const studyToolsWithAsk = [
    ...AgentTools.studyTools,
    askUser,
  ];

  /// plan 场景工具集：计划 7 工具 + ask_user。
  static const planToolsWithAsk = [
    ...PlanTools.planTools,
    askUser,
  ];
}