/// study_engine：study_buddy 的引擎层 barrel 导出。
///
/// 后续任务的模型、Repository、LLM、Agent 导出会逐步追加到此处。
library study_engine;

export 'src/models/models.dart';
export 'src/db/database_migrations.dart' show kCurrentDbVersion, migrateDatabase;
export 'src/db/database.dart';
export 'src/repos/subject_repository.dart';
export 'src/repos/topic_repository.dart';
export 'src/repos/mastery_repository.dart';
export 'src/repos/topic_domain_repository.dart';
export 'src/repos/llm_config_repository.dart';
export 'src/repos/agent_memory_repository.dart';
export 'src/repos/chat_repository.dart';
export 'src/llm/llm_provider.dart';
