import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// 当前生效的 LLM 配置(默认项)。
///
/// build() 时:
/// - 读 `llm_config` 表 all();
/// - 若表为空(全新安装),种子一条占位默认配置(name="默认配置"/url=""/key=""/model=""/supportsVision=true/isDefault=true),
///   消除 [AgentSession]/[PlanSession] 的 getDefault() 返回 null 抛 StateError 的崩溃路径,
///   并让用户在设置页看到"待填写"的初始态。
/// - 返回 sort_order 最前的默认项(无默认项则返回首行)。
///
/// save() 时:id 为空走 insert,否则走 update;写库后 invalidateSelf 触发重建。
final llmConfigProvider =
    AsyncNotifierProvider<LlmConfigNotifier, LlmConfig?>(
  LlmConfigNotifier.new,
);

class LlmConfigNotifier extends AsyncNotifier<LlmConfig?> {
  @override
  Future<LlmConfig?> build() async {
    final db = await ref.watch(databaseProvider.future);
    final repo = LlmConfigRepository(db);
    var configs = await repo.all();
    if (configs.isEmpty) {
      await repo.insert(LlmConfig(
        name: '默认配置',
        apiUrl: '',
        apiKey: '',
        model: '',
        supportsVision: true,
        isDefault: true,
        createdAt: DateTime.now(),
      ));
      configs = await repo.all();
    }
    // 优先默认项;无则首行
    return configs.firstWhere(
      (c) => c.isDefault,
      orElse: () => configs.first,
    );
  }

  /// 保存配置:id 为空 insert,否则 update。返回写入后的配置(带 id)。
  Future<LlmConfig> save(LlmConfig cfg) async {
    final db = await ref.read(databaseProvider.future);
    final repo = LlmConfigRepository(db);
    if (cfg.id == null) {
      final newId = await repo.insert(cfg);
      return cfg.copyWith(id: newId);
    }
    await repo.update(cfg);
    return cfg;
  }

  /// 写库后刷新:调用方 save 后调用此方法,或直接 invalidate。
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}
