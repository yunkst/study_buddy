/// study_engine：study_buddy 的引擎层 barrel 导出。
///
/// 后续任务的模型、Repository、LLM、Agent 导出会逐步追加到此处。
library;

export 'src/models/models.dart';
export 'src/db/database_migrations.dart' show kCurrentDbVersion, migrateDatabase;
export 'src/db/database.dart';
export 'src/repos/category_repository.dart';
export 'src/repos/topic_repository.dart';
export 'src/repos/topic_edge_repository.dart';
export 'src/repos/mastery_repository.dart';
export 'src/repos/llm_config_repository.dart';
export 'src/repos/agent_memory_repository.dart';
export 'src/repos/prompt_override_repository.dart';
export 'src/repos/review_repository.dart';
export 'src/repos/chat_repository.dart';
export 'src/repos/plan_repository.dart';
export 'src/repos/plan_day_task_repository.dart';
export 'src/repos/focus_session_repository.dart';
export 'src/repos/topic_schedule_repository.dart';
export 'src/aggregations/daily_report.dart';
export 'src/aggregations/study_stats.dart';
export 'src/llm/llm_provider.dart';
export 'src/llm/complete_text.dart';
export 'src/review_scheduler/params.dart';
export 'src/review_scheduler/review_scheduler.dart';
export 'src/review_scheduler/mastery_x.dart';
export 'src/agent/agent_event.dart';
export 'src/agent/agent_scenario.dart';
export 'src/agent/prompt_resolver.dart';
export 'src/agent/prompts/study_plan_prompt.dart';
export 'src/agent/context_compactor.dart';
export 'src/agent/agent_tools.dart';
export 'src/agent/plan_tools.dart';
export 'src/agent/agent_loop.dart';
export 'src/agent/ask_user.dart';
export 'src/agent/ask_user_tools.dart';
export 'src/agent/scenarios/study_plan_scenario.dart';
export 'src/logging/logger_sink.dart';
export 'src/logging/llm_call_sink.dart';
