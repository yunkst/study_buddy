# 新手引导页实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** study_buddy App 首次冷启动自动进入 5 节纸感新手引导页，第 5 节内嵌 LLM 配置表单当场填写写库，完成后写 `onboarding_done=true` 标记并跳首页。

**Architecture:** main 预取 SharedPreferences → router redirect 双向拦截 → OnboardingPage (PageView + 圆点 + 5 节) → 第 5 节表单写 `llm_config` 表。纸感零件（`_Article`/`_ArticleLabel`/`_StampIcon`/`_TipCard`/`_CornerMark`）抽公共到 `core/theme/paper_widgets.dart`，首页/权限引导页/引导页共用。

**Tech Stack:** Flutter + Riverpod 3 + go_router + SharedPreferences + sqflite_common_ffi (test) + study_engine (engine path: ../packages/study_engine)

## Global Constraints

- **零新依赖**：`shared_preferences` ^2.2.2、`LlmConfigRepository`、`sqflite_common_ffi` 均已存在；不新增 pubspec 依赖
- **纸感风格统一**：所有抽公共的 widget 视觉与原版零差异（纯重构）；引导页新写的 `_OnboardingSeal` 序号印章继承 `_StampIcon` 的 `Transform.rotate(-3°) + DashedBorder` 范式
- **首次启动判定**：SharedPreferences key 必须是字面量字符串 `onboarding_done`，bool，默认 false
- **redirect 同步**：router redirect 闭包要求同步返回 String?，`SharedPreferences` 必须在 `runApp` 之前的 `main()` async 里预取，不在 redirect 里 await
- **router redirect 双向拦截**：showOnboarding=true 且 loc≠/onboarding → /onboarding；showOnboarding=false 且 loc=/onboarding → /
- **LLM 配置写库字段**：`is_default=1`、`supports_vision=0`、`sort_order=0`、`name='默认'`、`model` 为空时用占位 `gpt-4o-mini`
- **错误降级**：跳过后回首页问 AI 会抛 "未配置默认 LLM" 错误（已知，本次不补入口）
- **测试基建**：app widget test 用 `sqflite_common_ffi` in-memory db + `SharedPreferences.setMockInitialValues` mock prefs
- **不测**：纸感视觉（颜色/字号/阴影）——人眼验；SharedPreferences 持久化本身——框架保证
- **执行约定**：所有 Dart 测试在 `packages/study_engine` 跑 `dart test`，在 `study_buddy` 跑 `flutter test`；`dart analyze` 全程绿

---

## Task Structure 概览

11 个任务，按依赖顺序串行（每个任务内部 TDD）：

| # | 任务 | 关键文件 |
|---|---|---|
| 1 | engine repo 测试 | `packages/study_engine/test/llm_config_repository_test.dart` |
| 2 | 抽公共 widget（_Article + _ArticleLabel） | `study_buddy/lib/core/theme/paper_widgets.dart` 新建 |
| 3 | 抽公共 widget（_StampIcon + _TipCard + _CornerMark） | 同上 |
| 4 | home_page 改用公共 widget | `home_page.dart` |
| 5 | permission_guide_page 改用公共 widget | `permission_guide_page.dart` |
| 6 | router 加 /onboarding 路由 + showOnboarding 参数（无 redirect） | `router.dart` |
| 7 | router redirect 双向拦截 + 测试 | `router.dart` + `test/router_test.dart` |
| 8 | main.dart async + app.dart 透传 | `main.dart` + `app.dart` |
| 9 | OnboardingPage 主体（PageView + 圆点 + 5 节占位） | `features/onboarding/onboarding_page.dart` |
| 10 | OnboardingPage 第 5 节 LLM 表单 | 同上 |
| 11 | OnboardingPage widget 测试 | `test/features/onboarding/onboarding_page_test.dart` |

---

### Task 1: LlmConfigRepository 路径测试

**Files:**
- Create: `packages/study_engine/test/llm_config_repository_test.dart`
- (Reference) `packages/study_engine/lib/src/repos/llm_config_repository.dart`
- (Reference) `packages/study_engine/lib/src/models/models.dart` (LlmConfig class)

**Interfaces:**
- Consumes: `StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath)`（已有基建，参见 `db_test.dart`）
- Consumes: `LlmConfigRepository(StudyDatabase)` 构造器
- Consumes: `LlmConfigRepository.insert(LlmConfig) → Future<int>`、`getDefault({bool vision}) → Future<LlmConfig?>`
- Produces: 测试覆盖 `insert + getDefault` 组合路径，后续任务 10 写入时可直接复用

- [ ] **Step 1: 写失败测试（已存在的 LlmConfigRepository.insert + getDefault 默认行为）**

```dart
// packages/study_engine/test/llm_config_repository_test.dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  late StudyDatabase sdb;
  late LlmConfigRepository repo;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = LlmConfigRepository(sdb);
  });

  tearDown(() async => sdb.close());

  LlmConfig makeConfig({
    String name = '默认',
    String apiUrl = 'https://api.openai.com/v1',
    String apiKey = 'sk-test',
    String model = 'gpt-4o-mini',
    bool supportsVision = false,
    bool isDefault = false,
    int sortOrder = 0,
  }) =>
      LlmConfig(
        name: name,
        apiUrl: apiUrl,
        apiKey: apiKey,
        model: model,
        supportsVision: supportsVision,
        isDefault: isDefault,
        sortOrder: sortOrder,
        createdAt: DateTime.now(),
      );

  group('LlmConfigRepository', () {
    test('insert 一条 is_default=1 → getDefault 返回它', () async {
      await repo.insert(makeConfig(isDefault: true));
      final got = await repo.getDefault();
      expect(got, isNotNull);
      expect(got!.isDefault, isTrue);
      expect(got.apiKey, 'sk-test');
    });

    test('insert 两条，第二条 is_default=1 → getDefault 返回 is_default=1 那条', () async {
      await repo.insert(makeConfig(name: 'A', apiKey: 'sk-a', isDefault: false, sortOrder: 0));
      await repo.insert(makeConfig(name: 'B', apiKey: 'sk-b', isDefault: true, sortOrder: 1));
      final got = await repo.getDefault();
      expect(got, isNotNull);
      expect(got!.apiKey, 'sk-b');
    });

    test('getDefault(vision:true) 在 supports_vision=0 的默认下回退到普通默认', () async {
      await repo.insert(makeConfig(supportsVision: false, isDefault: true));
      final got = await repo.getDefault(vision: true);
      expect(got, isNotNull);
      expect(got!.supportsVision, isFalse);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认全绿（覆盖现有实现）**

Run: `cd packages/study_engine && dart test test/llm_config_repository_test.dart`
Expected: 3 passed

- [ ] **Step 3: 提交**

```bash
git add packages/study_engine/test/llm_config_repository_test.dart
git commit -m "test: LlmConfigRepository insert+getDefault 组合路径"
```

---

### Task 2: 抽公共 _Article + _ArticleLabel（第一步：最小可验证单元）

**Files:**
- Create: `study_buddy/lib/core/theme/paper_widgets.dart`
- Modify: `study_buddy/lib/features/home/home_page.dart`（本任务**先不改**，仅准备公共 widget；改写在 Task 4）

**Interfaces:**
- Consumes: 已有 `_Article`/`_ArticleLabel` 私有 widget 代码（从 `home_page.dart` 第 203-225、331-357 行复制）
- Consumes: 已有 `_CornerMark` enum + `_CornerMarkPainter`（Task 3 抽，本任务**仅依赖 DashedBorder + BoxDecoration 即可**，因为 Painter 是 Article 内部细节）
- Produces: 公共 `PaperArticle`（无下划线）、`PaperArticleLabel`（无下划线）

- [ ] **Step 1: 在 home_page.dart 定位 _Article 和 _ArticleLabel**

Read `study_buddy/lib/features/home/home_page.dart` 第 203-225 行（`_Article`）和第 331-357 行（`_ArticleLabel`）。

- [ ] **Step 2: 创建 paper_widgets.dart，复制 _Article（公开为 PaperArticle）+ _ArticleLabel（公开为 PaperArticleLabel）**

```dart
// study_buddy/lib/core/theme/paper_widgets.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'paper_extension.dart';

/// 纸感文章块通用容器：纸白底 + 边 + 暖阴影 + 四角订书钉 L 形角标。
/// 还原 design-preview/02-paper.html `.article`。
class PaperArticle extends StatelessWidget {
  const PaperArticle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>()!;
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(color: paper.warmShadow, blurRadius: 24, offset: const Offset(0, 8)),
        ],
      ),
      // Stack 叠四角 L 形订书钉角标。本任务先保留 home_page 原 Painter 内联，
      // Task 3 抽到 CornerMark 后改 import。
      child: Stack(
        children: [
          child,
          Positioned(
            top: 8,
            left: 8,
            child: CustomPaint(
              size: const Size(18, 18),
              painter: _CornerMarkPainter(
                color: theme.colorScheme.outlineVariant,
                corner: _Corner.topLeft,
              ),
            ),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: CustomPaint(
              size: const Size(18, 18),
              painter: _CornerMarkPainter(
                color: theme.colorScheme.outlineVariant,
                corner: _Corner.bottomRight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 订书钉角标位置。公开给本文件 _CornerMarkPainter 使用。
enum _Corner { topLeft, bottomRight }

class _CornerMarkPainter extends CustomPainter {
  const _CornerMarkPainter({required this.color, required this.corner});

  final Color color;
  final _Corner corner;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    switch (corner) {
      case _Corner.topLeft:
        canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
        canvas.drawLine(Offset.zero, Offset(0, size.height), paint);
      case _Corner.bottomRight:
        canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), paint);
        canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CornerMarkPainter oldDelegate) =>
      color != oldDelegate.color || corner != oldDelegate.corner;
}

/// 文章块小标题：朱砂斜体下划线。
/// 还原 design-preview/02-paper.html `.article-label`。
class PaperArticleLabel extends StatelessWidget {
  const PaperArticleLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.primary, width: 1),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontFamily: 'NotoSerifSC',
          fontStyle: FontStyle.italic,
          fontSize: 13,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 跑 analyze 确认无问题**

Run: `cd study_buddy && dart analyze lib/core/theme/paper_widgets.dart`
Expected: No issues found

- [ ] **Step 4: 提交**

```bash
git add study_buddy/lib/core/theme/paper_widgets.dart
git commit -m "refactor: 抽 PaperArticle + PaperArticleLabel 公共纸感 widget（第一步）"
```

---

### Task 3: 抽公共 _StampIcon + PaperTipCard + 暴露 CornerMark

**Files:**
- Modify: `study_buddy/lib/core/theme/paper_widgets.dart`（追加 PaperStampIcon、PaperTipCard、公开 CornerMark enum + CornerMarkPainter）
- (Reference) `study_buddy/lib/features/overlay/permission_guide_page.dart` 第 81-119 行（_StampIcon 模板）
- (Reference) `study_buddy/lib/features/home/home_page.dart` 第 492-535 行（_TipCard 注标签版）

**Interfaces:**
- Consumes: 已有 `_StampIcon`（permission_guide_page）结构：`Transform.rotate(-3°) + 外层 DashedBorder + 内层实线边 + Icon`
- Consumes: 已有 `_TipCard`（home_page）：金底 + gold 左 3px 边 + 标签文本 + 提示正文
- Produces:
  - `PaperStampIcon({required IconData icon, double iconSize = 40})` — 公开 icon 印章，供 permission_guide_page 和引导页复用
  - `PaperTipCard({required String label, required String text})` — 抽公共，label 参数化（home_page 用「注」，permission_guide 用「提示」或自定义）
  - `CornerMark` + `CornerMarkPainter`（公开 Task 2 里仍私有的）

- [ ] **Step 1: 在 paper_widgets.dart 暴露 CornerMark + CornerMarkPainter（Task 2 改公开）**

```dart
// 替换 Task 2 里 enum _Corner + class _CornerMarkPainter 为公开名
enum CornerMark { topLeft, bottomRight }

class CornerMarkPainter extends CustomPainter {
  const CornerMarkPainter({required this.color, required this.corner});

  final Color color;
  final CornerMark corner;

  @override
  void paint(Canvas canvas, Size size) { /* 同 Task 2 实现 */ }

  @override
  bool shouldRepaint(covariant CornerMarkPainter oldDelegate) =>
      color != oldDelegate.color || corner != oldDelegate.corner;
}
```

并把 `PaperArticle.build` 里两处 `painter: _CornerMarkPainter(corner: _Corner.topLeft)` 改为 `painter: CornerMarkPainter(corner: CornerMark.topLeft)`。

- [ ] **Step 2: 追加 PaperStampIcon 到 paper_widgets.dart**

```dart
/// 印章式 Icon：外层 DashedBorder 虚线环 + 内层实线边 + 居中 Icon，整体 -3° 倾斜。
/// 还原 design-preview/02-paper.html `.stamp`。
class PaperStampIcon extends StatelessWidget {
  const PaperStampIcon({super.key, required this.icon, this.iconSize = 40});

  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Transform.rotate(
      angle: -3 * math.pi / 180,
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: DashedBorder(
            radius: 0,
            dash: 4,
            gap: 3,
            color: color.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            color: theme.colorScheme.surfaceContainerLowest,
          ),
          child: Icon(icon, size: iconSize, color: color),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 追加 PaperTipCard 到 paper_widgets.dart**

```dart
/// 金边提示卡：goldContainer 底 + gold 左 3px 边 + 标签 + 提示正文。
/// 还原 design-preview/02-paper.html `.tip-card`。
class PaperTipCard extends StatelessWidget {
  const PaperTipCard({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: paper.goldContainer,
        border: Border(
          left: BorderSide(color: paper.gold, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'NotoSerifSC',
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: paper.gold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                height: 1.7,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: 顶部加 import**

在 paper_widgets.dart 顶部追加：

```dart
import 'dashed_border.dart';
```

- [ ] **Step 5: 跑 analyze**

Run: `cd study_buddy && dart analyze lib/core/theme/paper_widgets.dart`
Expected: No issues found

- [ ] **Step 6: 提交**

```bash
git add study_buddy/lib/core/theme/paper_widgets.dart
git commit -m "refactor: 抽 PaperStampIcon + PaperTipCard + 公开 CornerMark"
```

---

### Task 4: home_page 改用公共 widget（视觉零回归）

**Files:**
- Modify: `study_buddy/lib/features/home/home_page.dart`（删除 `_Article`/`_ArticleLabel`/`_CornerMarkPainter`/`_CornerMark`/`_TipCard` 私有定义，全部改用公共 widget；`_Stamp` 状态印章**保留**私有，本任务不动）

**Interfaces:**
- Consumes: `paper_widgets.dart` 的 `PaperArticle`、`PaperArticleLabel`、`PaperTipCard`
- Produces: `home_page.dart` 内引用从 `_Article(...)` → `PaperArticle(...)`、`_ArticleLabel(text:...)` → `PaperArticleLabel(text:...)`、`_TipCard()` → `PaperTipCard(label: '注', text: '部分小米机型需额外开启「后台弹出界面」权限,方可在应用外唤起截图框选。')`

- [ ] **Step 1: 加 import**

在 `home_page.dart` 顶部 import 区追加：

```dart
import '../../core/theme/paper_widgets.dart';
```

- [ ] **Step 2: 删除私有 _Article + _ArticleLabel + _CornerMark + _CornerMarkPainter + _TipCard**

删除 `home_page.dart` 第 203-287 行（`_Article` + `_CornerMark` + `_CornerMarkPainter`）、第 331-357 行（`_ArticleLabel`）、第 492-535 行（`_TipCard`）。

- [ ] **Step 3: 全局替换引用**

- `_Article(` → `PaperArticle(`（共 5 处：`_StatusArticle` / `_UpdateArticle` / `_FocusArticle` / `_PlansArticle` 各一处）
- `_ArticleLabel(text:` → `PaperArticleLabel(text:`
- `_TipCard()` → `PaperTipCard(label: '注', text: '部分小米机型需额外开启「后台弹出界面」权限,方可在应用外唤起截图框选。')`

- [ ] **Step 4: 删未用 import**

删 `home_page.dart` 顶部 `import 'dart:math' as math;`（如果仅 `_CornerMarkPainter.paint` 和 `_Stamp` 用过 math，`_CornerMarkPainter` 删了，math 可能仍给 `_Stamp` 用——保留；用 grep `math\\.` 检查）

Run: `cd study_buddy && grep -n "math\\." lib/features/home/home_page.dart`
若只剩 `_Stamp` 用，保留 import。

- [ ] **Step 5: 跑全 app analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 6: 跑现有 home_page 相关测试（如有）**

Run: `cd study_buddy && flutter test test/features/home/`
Expected: passed（若有失败，对照原视觉检查：核心纸感件是纯重构，行为不变）

- [ ] **Step 7: 提交**

```bash
git add study_buddy/lib/features/home/home_page.dart
git commit -m "refactor(home): 改用公共 PaperArticle/PaperArticleLabel/PaperTipCard"
```

---

### Task 5: permission_guide_page 改用公共 widget（视觉零回归）

**Files:**
- Modify: `study_buddy/lib/features/overlay/permission_guide_page.dart`（删除 `_StampIcon` 和 `_TipCard` 私有定义，改用公共 widget）

**Interfaces:**
- Consumes: `PaperStampIcon`、`PaperTipCard`
- Produces: 原 `_StampIcon()`（直接显示 `Icons.screenshot_monitor`）→ `PaperStampIcon(icon: Icons.screenshot_monitor)`；原 `_TipCard()`（显示「提示：部分小米机型需额外开启「后台弹出界面」权限。」）→ `PaperTipCard(label: '提示', text: '部分小米机型需额外开启「后台弹出界面」权限。')`

- [ ] **Step 1: 加 import**

```dart
import '../../core/theme/paper_widgets.dart';
```

- [ ] **Step 2: 删私有 _StampIcon 和 _TipCard**

删除 `permission_guide_page.dart` 第 81-155 行（两个 widget 整体）。

- [ ] **Step 3: 替换 build 里的引用**

`Center(child: const _StampIcon())` → `Center(child: const PaperStampIcon(icon: Icons.screenshot_monitor))`
`const _TipCard()` → `const PaperTipCard(label: '提示', text: '部分小米机型需额外开启「后台弹出界面」权限。')`

- [ ] **Step 4: 检查顶部 import 是否仍要 `dashed_border.dart`**

`PaperStampIcon` 内部用了 DashedBorder，但已在 paper_widgets.dart 里 import，本文件不需直接用。删除 `import '../../core/theme/dashed_border.dart';`。

`math` 同理，`PaperStampIcon` 用了 `dart:math`，本文件不需直接 import。删除 `import 'dart:math' as math;`。

- [ ] **Step 5: 跑 analyze**

Run: `cd study_buddy && dart analyze lib/features/overlay/permission_guide_page.dart`
Expected: No issues found

- [ ] **Step 6: 跑全 app analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 7: 提交**

```bash
git add study_buddy/lib/features/overlay/permission_guide_page.dart
git commit -m "refactor(permission_guide): 改用公共 PaperStampIcon + PaperTipCard"
```

---

### Task 6: router 加 /onboarding 路由 + buildRouter 接收 showOnboarding（先无 redirect）

**Files:**
- Modify: `study_buddy/lib/router.dart`（buildRouter 接收 `bool showOnboarding`，加 /onboarding 路由，**先不加 redirect**，确保编译通过 + 路由注册成功）

**Interfaces:**
- Consumes: `OnboardingPage`（尚未实现，本任务用占位 `Scaffold(body: Center(child: Text('Onboarding')))` 占位，Task 9 替换）
- Produces: `buildRouter(bool showOnboarding)` 签名变更；所有调用方（`app.dart`）需传参

- [ ] **Step 1: 修改 router.dart 签名 + 加路由占位**

```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'features/focus/daily_report_page.dart';
import 'features/focus/focus_page.dart';
import 'features/home/home_page.dart';
import 'features/onboarding/onboarding_page.dart'; // 本步先注释掉,Task 9 引入
import 'features/overlay/permission_guide_page.dart';
import 'features/plan/plan_detail_page.dart';

GoRouter buildRouter({bool showOnboarding = false}) {
  return GoRouter(
    routes: [
      // Onboarding 在最前:若需要且当前是 /onboarding,放行;否则由 redirect 接管(Task 7 加)。
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const _OnboardingPlaceholder(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
      // ... 既有 /permission-guide /plan/:id /focus /daily-report 路由不变
    ],
  );
}

/// 临时占位,Task 9 替换为真实 OnboardingPage。
class _OnboardingPlaceholder extends StatelessWidget {
  const _OnboardingPlaceholder();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Onboarding (placeholder)')));
}
```

**注意**：`features/onboarding/onboarding_page.dart` 还不存在，先**注释掉**那行 import，`_OnboardingPlaceholder` 不依赖 OnboardingPage。Task 9 再 uncomment。

- [ ] **Step 2: 改 app.dart 传 showOnboarding: false（默认值，避免破坏现有 build）**

`study_buddy/lib/app.dart` 第 57 行 `routerConfig: buildRouter()` → `routerConfig: buildRouter(showOnboarding: false)`。

- [ ] **Step 3: 跑 analyze**

Run: `cd study_buddy && dart analyze lib/router.dart lib/app.dart`
Expected: No issues found

- [ ] **Step 4: 启动应用验证路由注册成功**

Run: `cd study_buddy && flutter run -d <device>`

手动访问 `/onboarding` 应看到占位页（需临时改首页跳转，或用 `--route /onboarding` 启动参数验证）。

Run: `cd study_buddy && flutter run -d <device> --route /onboarding`
Expected: 显示 "Onboarding (placeholder)"

- [ ] **Step 5: 提交**

```bash
git add study_buddy/lib/router.dart study_buddy/lib/app.dart
git commit -m "feat(router): 加 /onboarding 路由占位 + buildRouter 接收 showOnboarding"
```

---

### Task 7: router redirect 双向拦截 + 测试

**Files:**
- Modify: `study_buddy/lib/router.dart`（加 `redirect` 回调）
- Create: `study_buddy/test/router_test.dart`

**Interfaces:**
- Consumes: `showOnboarding` 参数
- Produces: redirect 逻辑：
  - `showOnboarding && loc != '/onboarding'` → `/onboarding`
  - `!showOnboarding && loc == '/onboarding'` → `/`
  - else `null`

- [ ] **Step 1: 在 router.dart 加 redirect**

```dart
GoRouter buildRouter({bool showOnboarding = false}) {
  return GoRouter(
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (showOnboarding && loc != '/onboarding') return '/onboarding';
      if (!showOnboarding && loc == '/onboarding') return '/';
      return null;
    },
    routes: [ /* 同 Task 6 */ ],
  );
}
```

- [ ] **Step 2: 写失败测试 `test/router_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:study_buddy/router.dart';

Future<String?> _resolve(String loc, {required bool showOnboarding}) async {
  final router = buildRouter(showOnboarding: showOnboarding);
  router.go(loc);
  // pump 让 redirect 完成
  await Future<void>.delayed(Duration.zero);
  final resolved = router.routerDelegate.currentConfiguration.uri.toString();
  router.dispose();
  return resolved;
}

void main() {
  test('showOnboarding=true, 访问 / → redirect 到 /onboarding', () async {
    final loc = await _resolve('/', showOnboarding: true);
    expect(loc, '/onboarding');
  });

  test('showOnboarding=false, 访问 /onboarding → redirect 到 /', () async {
    final loc = await _resolve('/onboarding', showOnboarding: false);
    expect(loc, '/');
  });

  test('showOnboarding=false, 访问 / → 放行（null）', () async {
    final loc = await _resolve('/', showOnboarding: false);
    expect(loc, '/');
  });

  test('showOnboarding=true, 访问 /onboarding → 放行', () async {
    final loc = await _resolve('/onboarding', showOnboarding: true);
    expect(loc, '/onboarding');
  });
}
```

- [ ] **Step 3: 跑测试**

Run: `cd study_buddy && flutter test test/router_test.dart`
Expected: 4 passed

- [ ] **Step 4: 跑全 app analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 5: 提交**

```bash
git add study_buddy/lib/router.dart study_buddy/test/router_test.dart
git commit -m "feat(router): redirect 双向拦截首启引导+测试"
```

---

### Task 8: main.dart async + app.dart 透传 showOnboarding

**Files:**
- Modify: `study_buddy/lib/main.dart`（main 变 async，加 ensureInitialized + 预取 prefs，传 showOnboarding）
- Modify: `study_buddy/lib/app.dart`（StudyBuddyApp 接收 showOnboarding 传给 buildRouter）

**Interfaces:**
- Consumes: `SharedPreferences.getInstance()`、`SharedPreferences.getBool(String)`
- Produces:
  - `main() async` 函数
  - `StudyBuddyApp({super.key, required this.showOnboarding})`
  - `buildRouter(showOnboarding: widget.showOnboarding)`

- [ ] **Step 1: 改 main.dart**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'core/providers/screenshot_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final onboardingDone = prefs.getBool('onboarding_done') ?? false;
  runApp(ProviderScope(child: StudyBuddyApp(showOnboarding: !onboardingDone)));
}

// bootstrapOverlay + PendingScreenshotStore 保持不变
```

- [ ] **Step 2: 改 app.dart**

`class StudyBuddyApp extends ConsumerStatefulWidget` 加字段：

```dart
class StudyBuddyApp extends ConsumerStatefulWidget {
  const StudyBuddyApp({super.key, required this.showOnboarding});
  final bool showOnboarding;
  @override
  ConsumerState<StudyBuddyApp> createState() => _StudyBuddyAppState();
}
```

`build` 方法里：

```dart
routerConfig: buildRouter(showOnboarding: widget.showOnboarding),
```

- [ ] **Step 3: 跑 analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 4: 手动验证首启判定**

Run: `cd study_buddy && flutter run -d <device>`

首次启动 → 自动跳 `/onboarding` 占位页。手动 `flutter run` 之前确保 app data 干净（卸载重装）。

设置 `prefs.setBool('onboarding_done', true)` 后（可用 `adb shell` 或在引导页完成时自动写——Task 9 接入）→ 直进首页。

- [ ] **Step 5: 提交**

```bash
git add study_buddy/lib/main.dart study_buddy/lib/app.dart
git commit -m "feat(boot): main 预取 prefs 透传 showOnboarding"
```

---

### Task 9: OnboardingPage 主体（PageView + 圆点 + 5 节占位 + 跳过/下一步）

**Files:**
- Create: `study_buddy/lib/features/onboarding/onboarding_page.dart`（含 _OnboardingSeal 私有印章序号 widget）
- Modify: `study_buddy/lib/router.dart`（uncomment `import 'features/onboarding/onboarding_page.dart'`，替换 `_OnboardingPlaceholder` 为 `OnboardingPage`）

**Interfaces:**
- Consumes: `PaperArticle`、`PaperArticleLabel`、`PaperStampIcon`（Task 2/3 抽出的公共 widget）
- Consumes: 复刻 home_page `_Masthead`（用户决策"刊头复用"，但 home_page 的 `_Masthead` 是私有。本任务**新写一个简版刊头** `OnboardingMasthead` 放在 onboarding_page.dart 私有，因为抽到公共会扩大 diff；视觉对齐 home_page 即可）
- Produces:
  - `OnboardingPage` (ConsumerStatefulWidget)
  - `_OnboardingStep({required int ordinal, required IconData icon, required String title, required String body})` ——前 4 节通用
  - `_OnboardingSeal({required String ordinal})` ——私有印章序号（继承 `_StampIcon` 范式）
  - `_OnboardingDots` 圆点指示器
  - 第 5 节**先放占位**（Task 10 替换为真实表单）

- [ ] **Step 1: 创建 onboarding_page.dart 框架**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/paper_scaffold.dart';
import '../../core/theme/paper_widgets.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final PageController _pc = PageController();
  int _index = 0;
  static const _total = 5;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _next() {
    if (_index < _total - 1) {
      _pc.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _OnboardingMasthead(),
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (i) => setState(() => _index = i),
                children: const [
                  _OnboardingStep(
                    ordinal: '一', icon: Icons.screenshot_monitor,
                    title: '截图悬浮球',
                    body: '任意界面点悬浮球，框选题目，AI 拆知识点。',
                  ),
                  _OnboardingStep(
                    ordinal: '二', icon: Icons.camera_alt_outlined,
                    title: '拍照问 AI',
                    body: '相册选图或拍照，AI 分析解题思路。',
                  ),
                  _OnboardingStep(
                    ordinal: '三', icon: Icons.event_note,
                    title: '学习计划',
                    body: '报考试日期目标，AI 拆里程碑节点，手动录测评看进步曲线。',
                  ),
                  _OnboardingStep(
                    ordinal: '四', icon: Icons.timer_outlined,
                    title: '专注与日报',
                    body: '专注计时锁定，结束生成学习日报。',
                  ),
                  _OnboardingStep(
                    ordinal: '五', icon: Icons.key,
                    title: '配置 AI',
                    body: '占位 — Task 10 替换为表单',
                    showForm: true, // 标记本步非通用结构
                  ),
                ],
              ),
            ),
            _BottomBar(
              index: _index,
              total: _total,
              onSkip: () => _finish(skipped: true),
              onNext: _next,
              onDone: () => _finish(skipped: false),
            ),
          ],
        ),
      ),
    );
  }

  void _finish({required bool skipped}) {
    // Task 10 完整实现:写 prefs + (可选)写 llm_config + context.go('/')
    debugPrint('[onboarding] finish skipped=$skipped');
  }
}

/// 简版刊头:与 home_page._Masthead 视觉对齐,本期不抽公共。
class _OnboardingMasthead extends StatelessWidget {
  const _OnboardingMasthead();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(width: 2, color: theme.colorScheme.outlineVariant)),
      ),
      child: Center(
        child: Text('Study Buddy · 欢迎',
            style: theme.textTheme.displayLarge?.copyWith(fontSize: 22)),
      ),
    );
  }
}

/// 单页（前 4 页通用），第 5 页用 _OnboardingStepForm 替换。
class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.ordinal,
    required this.icon,
    required this.title,
    required this.body,
    this.showForm = false,
  });
  final String ordinal;
  final IconData icon;
  final String title;
  final String body;
  final bool showForm;

  @override
  Widget build(BuildContext context) {
    if (showForm) {
      // Task 10 替换为真实 _OnboardingStepForm
      return const _FormPlaceholder();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: PaperArticle(
        child: Column(
          children: [
            PaperArticleLabel(text: title),
            const SizedBox(height: 16),
            Center(child: _OnboardingSeal(ordinal: ordinal)),
            const SizedBox(height: 16),
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _FormPlaceholder extends StatelessWidget {
  const _FormPlaceholder();
  @override
  Widget build(BuildContext context) => const Center(child: Text('Form 占位 (Task 10)'));
}

/// 印章式序号：-3° 倾斜 + DashedBorder 外环 + 实线框 + 中文序号。
class _OnboardingSeal extends StatelessWidget {
  const _OnboardingSeal({required this.ordinal});
  final String ordinal;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Transform.rotate(
      angle: -3 * 3.1415926 / 180,
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: DashedBorder(
            radius: 0, dash: 4, gap: 3,
            color: color.withValues(alpha: 0.3), width: 1,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            color: theme.colorScheme.surfaceContainerLowest,
          ),
          child: Text(ordinal,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'NotoSerifSC',
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: 3,
                color: color,
              )),
        ),
      ),
    );
  }
}

/// 底部固定区：圆点 + 跳过 + 下一步/完成。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.index, required this.total,
    required this.onSkip, required this.onNext, required this.onDone,
  });
  final int index;
  final int total;
  final VoidCallback onSkip;
  final VoidCallback onNext;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        children: [
          TextButton(onPressed: onSkip, child: const Text('跳过')),
          Expanded(child: _Dots(index: index, total: total)),
          if (index < total - 1)
            FilledButton(onPressed: onNext, child: const Text('下一步'))
          else
            FilledButton(onPressed: onDone, child: const Text('完成，开始使用')),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.total});
  final int index;
  final int total;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final active = i == index;
        return Container(
          width: active ? 8 : 6, height: active ? 8 : 6,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
          ),
        );
      }),
    );
  }
}
```

**注意**：`_OnboardingStepForm` 用 `_FormPlaceholder` 占位，需要 import `DashedBorder`（在 paper_widgets.dart 已用，但 onboarding_page 直接用也需 import）：

```dart
import '../../core/theme/dashed_border.dart';
```

- [ ] **Step 2: uncomment router.dart 的 OnboardingPage import + 替换占位**

`study_buddy/lib/router.dart`：
- uncomment `import 'features/onboarding/onboarding_page.dart';`
- `/onboarding` 路由的 `builder` 返回 `const OnboardingPage()`，删除 `_OnboardingPlaceholder` 类

- [ ] **Step 3: 跑 analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 4: 手动验证**

Run: `cd study_buddy && flutter run -d <device>`（首启且 prefs 无 onboarding_done=true）

Expected:
- 自动跳 /onboarding
- 看到 5 节可滑动，前 4 节显示「一/二/三/四」印章 + icon + 说明，第 5 节显示 "Form 占位"
- 底部圆点跟随 PageView 切换
- 「下一步」「跳过」「完成，开始使用」三个按钮可见

- [ ] **Step 5: 提交**

```bash
git add study_buddy/lib/features/onboarding/onboarding_page.dart study_buddy/lib/router.dart
git commit -m "feat(onboarding): 5节纸感分页+圆点+底部按钮（占位）"
```

---

### Task 10: OnboardingPage 第 5 节 LLM 表单 + 完成逻辑

**Files:**
- Modify: `study_buddy/lib/features/onboarding/onboarding_page.dart`（替换 `_FormPlaceholder` 为 `_OnboardingStepForm`；完成逻辑写 prefs + llm_config + 跳转）

**Interfaces:**
- Consumes: `databaseProvider`、`LlmConfigRepository`、`SharedPreferences.getInstance()`
- Produces:
  - `_OnboardingStepForm` ——表单 UI + 校验（URL/Key 非空）
  - `_finish(skipped: false)` ——写 llm_config + prefs + context.go('/')
  - `_finish(skipped: true)` ——只写 prefs + context.go('/')

- [ ] **Step 1: 替换 _FormPlaceholder 为真实 _OnboardingStepForm**

```dart
class _OnboardingStepForm extends ConsumerStatefulWidget {
  const _OnboardingStepForm();
  @override
  ConsumerState<_OnboardingStepForm> createState() => _OnboardingStepFormState();
}

class _OnboardingStepFormState extends ConsumerState<_OnboardingStepForm> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _setAsDefault = true;
  bool _saving = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _urlCtrl.text.trim().isNotEmpty && _keyCtrl.text.trim().isNotEmpty;

  Future<bool> _submit() async {
    final db = await ref.read(databaseProvider.future);
    final repo = LlmConfigRepository(db);
    final model = _modelCtrl.text.trim().isEmpty ? 'gpt-4o-mini' : _modelCtrl.text.trim();
    await repo.insert(LlmConfig(
      name: '默认',
      apiUrl: _urlCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
      model: model,
      supportsVision: false,
      isDefault: _setAsDefault,
      sortOrder: 0,
      createdAt: DateTime.now(),
    ));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: PaperArticle(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PaperArticleLabel(text: '配置 AI'),
            const SizedBox(height: 16),
            const Center(child: _OnboardingSeal(ordinal: '五')),
            const SizedBox(height: 16),
            Text('填好以下信息，AI 才能真正可用。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'API 地址',
                hintText: 'https://api.openai.com/v1',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keyCtrl,
              onChanged: (_) => setState(() {}),
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _modelCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '模型名（可空，默认 gpt-4o-mini）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _setAsDefault,
              onChanged: (v) => setState(() => _setAsDefault = v),
              title: const Text('设为默认'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}
```

`OnboardingPage` 的第 5 个 child 改为 `const _OnboardingStepForm()`。

- [ ] **Step 2: 实现完成逻辑（_finish）**

替换 `_finish` 方法：

```dart
Future<void> _finish({required bool skipped}) async {
  if (!skipped) {
    // 用户点了"完成，开始使用"，先尝试写库
    setState(() => _saving = true); // _saving 字段加到 _OnboardingPageState
    try {
      // 通过 key 找到 _OnboardingStepFormState 调 _submit
      final formKey = _formKey.currentState;
      if (formKey != null) {
        await formKey.submit();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
      return; // 不写 prefs,留在引导页
    }
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('onboarding_done', true);
  if (mounted) context.go('/');
}
```

在 `_OnboardingPageState` 加：

```dart
final GlobalKey<_OnboardingStepFormState> _formKey = GlobalKey<_OnboardingStepFormState>();
bool _saving = false;
```

`_OnboardingStepFormState` 加 `submit()` 公开方法返回 `Future<bool>`：

```dart
Future<bool> submit() async {
  if (!_canSubmit) return false;
  return _submit();
}
```

`_BottomBar.onDone` 改为 `() => _finish(skipped: false)`，按钮 `onPressed: _saving ? null : onDone`。

- [ ] **Step 3: 加 imports**

```dart
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:study_engine/study_engine.dart';
import '../../core/providers/database_provider.dart';
```

- [ ] **Step 4: 跑 analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 5: 手动验证**

Run: `cd study_buddy && flutter run -d <device>`（卸载重装，确保 onboarding_done=false）

验证：
- 第 5 节显示表单，URL/Key 留空时「完成，开始使用」按钮置灰（onPressed: null）
- 填齐 URL/Key，点完成 → 写库成功 → context.go('/') → 进首页
- 重启 App → 直进首页（prefs 持久化生效）

- [ ] **Step 6: 提交**

```bash
git add study_buddy/lib/features/onboarding/onboarding_page.dart
git commit -m "feat(onboarding): 第5节 LLM 表单 + 写库 + 完成跳转"
```

---

### Task 11: OnboardingPage widget 测试（5 场景）

**Files:**
- Create: `study_buddy/test/features/onboarding/onboarding_page_test.dart`

**Interfaces:**
- Consumes: `ProviderScope` 覆盖 `databaseProvider`（in-memory ffi）+ `SharedPreferences.setMockInitialValues({})` mock prefs
- Produces: 5 个测试场景覆盖 spec "测试策略"

- [ ] **Step 1: 创建测试文件**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/features/onboarding/onboarding_page.dart';
import 'package:study_engine/study_engine.dart';

Future<void> _pumpPage(WidgetTester tester, {List<Override> overrides = const []}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: OnboardingPage()),
    ),
  );
  await tester.pumpAndSettle();
}

ProviderScope _withInMemoryDb(List<Override> extra) {
  // 覆盖 databaseProvider 为 in-memory ffi 数据库
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async {
        final sdb = await StudyDatabase.open(
          factory: databaseFactoryFfi, path: inMemoryDatabasePath);
        ref.onDispose(() => sdb.close());
        return sdb;
      }),
      ...extra,
    ],
    child: const MaterialApp(home: OnboardingPage()),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  testWidgets('第 1 页可见「截图悬浮球」标题', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_withInMemoryDb([]));
    await tester.pumpAndSettle();
    expect(find.text('截图悬浮球'), findsOneWidget);
  });

  testWidgets('点「下一步」翻到第 2 页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_withInMemoryDb([]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('拍照问 AI'), findsOneWidget);
  });

  testWidgets('第 5 页 URL/Key 留空 → 「完成，开始使用」按钮置灰', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_withInMemoryDb([]));
    await tester.pumpAndSettle();
    // 翻到第 5 页
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    expect(find.text('配置 AI'), findsOneWidget);
    final doneBtn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '完成，开始使用'));
    expect(doneBtn.onPressed, isNull);
  });

  testWidgets('填齐 URL/Key → 点完成 → 写 llm_config + onboarding_done + 跳首页',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late StudyDatabase testDb;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async {
            testDb = await StudyDatabase.open(
              factory: databaseFactoryFfi, path: inMemoryDatabasePath);
            ref.onDispose(() => testDb.close());
            return testDb;
          }),
        ],
        child: const MaterialApp(home: OnboardingPage()),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.widgetWithText(TextField, 'API 地址'), 'https://api.openai.com/v1');
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'sk-test');
    await tester.pump();
    await tester.tap(find.text('完成，开始使用'));
    await tester.pumpAndSettle();
    // 验证库写入
    final repo = LlmConfigRepository(testDb);
    final cfg = await repo.getDefault();
    expect(cfg, isNotNull);
    expect(cfg!.apiKey, 'sk-test');
    // 验证 prefs 写入
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_done'), isTrue);
  });

  testWidgets('点「跳过」→ 写 onboarding_done + 不写 llm_config', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late StudyDatabase testDb;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async {
            testDb = await StudyDatabase.open(
              factory: databaseFactoryFfi, path: inMemoryDatabasePath);
            ref.onDispose(() => testDb.close());
            return testDb;
          }),
        ],
        child: const MaterialApp(home: OnboardingPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_done'), isTrue);
    // llm_config 表应为空
    final repo = LlmConfigRepository(testDb);
    final cfg = await repo.getDefault();
    expect(cfg, isNull);
  });
}
```

- [ ] **Step 2: 跑测试**

Run: `cd study_buddy && flutter test test/features/onboarding/onboarding_page_test.dart`
Expected: 5 passed（若失败，按错误信息调整：可能是 _withInMemoryDb helper 与 _pumpPage 重复，可删 _pumpPage；或 `find.widgetWithText(TextField, 'API 地址')` 找不到——可能需先 ensureVisible）

- [ ] **Step 3: 跑全 app 测试**

Run: `cd study_buddy && flutter test`
Expected: 全部 passed（router_test 4 个 + onboarding 5 个 + 既有测试）

- [ ] **Step 4: 跑全 analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues found

- [ ] **Step 5: 提交**

```bash
git add study_buddy/test/features/onboarding/onboarding_page_test.dart
git commit -m "test(onboarding): 5 场景 widget test（首屏/翻页/校验/完成/跳过）"
```

---

## 完成定义

- [ ] `dart analyze` 全 app 零警告
- [ ] `flutter test` 全 app 零失败
- [ ] `dart test` engine 全绿
- [ ] 手动验证：卸载重装 → 首启跳引导 → 填 LLM 配置 → 进首页 → 重启直进首页
- [ ] 手动验证：手动跳过 → 重启直进首页 → 问 AI 抛 "未配置默认 LLM"（已知降级）
- [ ] 纸感视觉与重构前零差异（首页 + 权限引导页）
