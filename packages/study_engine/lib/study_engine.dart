/// study_engine：study_buddy 的引擎层 barrel 导出。
///
/// 后续任务的模型、Repository、LLM、Agent 导出会逐步追加到此处。
library;

export 'src/models/models.dart';
export 'src/review/spaced_repetition_service.dart';
export 'src/db/database_migrations.dart' show kCurrentDbVersion, migrateDatabase;
export 'src/db/database.dart';
export 'src/repos/category_repository.dart';
export 'src/repos/topic_repository.dart';
export 'src/repos/topic_edge_repository.dart';
export 'src/repos/mastery_repository.dart';
export 'src/repos/llm_config_repository.dart';
export 'src/repos/agent_memory_repository.dart';
export 'src/repos/chat_repository.dart';
export 'src/repos/review_schedule_repository.dart';
export 'src/repos/review_queue_repository.dart';
export 'src/llm/llm_provider.dart';
export 'src/agent/agent_event.dart';
export 'src/agent/agent_scenario.dart';
export 'src/agent/context_compactor.dart';
export 'src/agent/agent_tools.dart';
export 'src/agent/agent_loop.dart';
export 'src/agent/scenarios/study_scenario.dart';
