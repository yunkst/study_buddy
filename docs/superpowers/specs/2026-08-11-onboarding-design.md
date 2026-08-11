# 新手引导页设计稿

> 日期：2026-08-11
> 状态：待审

## 目标

为 study_buddy App 增加"新手引导页"：首次冷启动自动进入，5 节纸感分页介绍核心功能并在末页内嵌 LLM 配置表单，用户当场填好 URL/Key/模型名后写库进首页。引导走完写 `onboarding_done=true` 标记，后续冷启动直进首页，不可重看。

顺带根治一个既有缺陷：当前 App 首次进入若问 AI，因 `llm_config` 表空会抛 "未配置默认 LLM" 错误，且无任何配置入口。引导页第 5 节内嵌表单让用户首次就配好，避免该错误。

## 范围

**包含**：
- 首次启动判定（SharedPreferences `onboarding_done` 标记）
- go_router redirect 双向拦截
- 5 节纸感水平分页引导页（PageView + 圆点指示器）
- 第 5 节内嵌 LLM 配置表单，写 `llm_config` 表
- 抽公共纸感零件到 `core/theme/paper_widgets.dart`，首页/权限引导页/引导页共用
- 跳过降级（不写 llm_config，回首页后问 AI 按现状报错）

**不包含**：
- 设置页 / LLM 配置页（跳过后的补救入口留后续迭代，本次不加）
- 引导页重看入口（用户选择"仅首次启动自动，不可重看"）
- 纸感视觉回归测试

## 决策记录

| 决策点 | 选择 | 理由 |
|---|---|---|
| 内容范围 | 核心 5 节（悬浮球+AI+计划+专注+LLM 配置） | 覆盖全部核心功能，顺带补配置缺口 |
| 触发时机 | 仅首次启动自动，不可重看 | 最简方案，零重看入口 |
| LLM 配置形式 | 引导页内嵌表单当场填 | 引导与配置一体，用户不用再找设置页 |
| 翻页形态 | 水平分页 + 圆点指示器 | 与纸感"书页横翻"隐喻契合 |
| 结束动作 | 表单 + 「完成，开始使用」 | 填完当场写库进首页 |
| 纸感零件 | 抽公共 paper_widgets.dart | 已被 3 页面用，到抽公共临界点 |
| 跳过后补救 | 不加设置页，跳过即跳过 | 本次最小闭环，补救入口留后续 |

## 架构

### 启动流程

```
main() async
  └─ WidgetsFlutterBinding.ensureInitialized()
  └─ prefs = await SharedPreferences.getInstance()
  └─ done = prefs.getBool('onboarding_done') ?? false
  └─ runApp(ProviderScope(child: StudyBuddyApp(showOnboarding: !done)))
       └─ buildRouter(showOnboarding: !done)
            └─ GoRouter.redirect:
                 showOnboarding && loc != '/onboarding' → '/onboarding'
                 !showOnboarding && loc == '/onboarding' → '/'
                 else → null（放行）
```

`main` 从同步变 async、加 `ensureInitialized()`——这是首启判定的标准写法（Flutter 官方推荐），prefs 读取毫秒级可忽略。

### 路由 redirect 双向拦截

| 当前路径 | showOnboarding=true | showOnboarding=false |
|---|---|---|
| `/onboarding` | 放行 | → `/`（防回退） |
| `/` 或其他 | → `/onboarding` | 放行 |

只拦单向会漏：用户在引导页按系统返回键会漏到首页。双向都拦才闭环。

### bootstrapOverlay 时序

`bootstrapOverlay`（悬浮球初始化）仍在 `app.dart` 首帧触发。首屏是引导页不是首页，引导页不依赖悬浮球，悬浮球在后台静默初始化，用户进首页时已就绪。无时序冲突。

### LLM 配置写入

```
OnboardingPage 第5页「完成，开始使用」
  └─ 校验 url/key 非空（按钮置灰保证）
  └─ db = await databaseProvider.future
  └─ repo = LlmConfigRepository(db)
  └─ repo.insert(LlmConfig(
       name: '默认',
       apiUrl: url, apiKey: key, model: model.isEmpty ? 'gpt-4o-mini' : model,
       supportsVision: false, isDefault: true, sortOrder: 0,
       createdAt: DateTime.now(),
     ))
  └─ prefs.setBool('onboarding_done', true)
  └─ context.go('/')
```

## 引导页结构

`OnboardingPage`（`ConsumerStatefulWidget`，`PaperScaffold` 底座 + `PageView`）：

- 顶部：刊头复用 `home_page._Masthead`（"Study Buddy" 纸感刊头，保持品牌一致）
- 中部：`PageView` 横向 5 页，每页一个 `_OnboardingStep` 文章块
- 底部固定区：圆点指示器（5 个） + 「跳过」TextButton（左） + 「下一步」/「完成」FilledButton（右）

### 5 页内容

| 页 | 序号 | 标题 | 图标 | 说明 |
|---|---|---|---|---|
| 1 | 一 | 截图悬浮球 | `Icons.screenshot_monitor` | 任意界面点悬浮球，框选题目，AI 拆知识点 |
| 2 | 二 | 拍照问 AI | `Icons.camera_alt_outlined` | 相册选图或拍照，AI 分析解题思路 |
| 3 | 三 | 学习计划 | `Icons.event_note` | 报考试日期目标，AI 拆里程碑节点，手动录测评看进步曲线 |
| 4 | 四 | 专注与日报 | `Icons.timer_outlined` | 专注计时锁定，结束生成学习日报 |
| 5 | 五 | 配置 AI | `Icons.key` | 填 URL/Key/模型名，让 AI 真正可用（含表单） |

### 单页结构（前 4 页通用）

```
_Article（纸白底+边+暖阴影+四角订书钉角标）
  ├─ _ArticleLabel（朱砂斜体下划线小标题：如「截图悬浮球」）
  ├─ 印章式序号（Transform.rotate(-3°) + DashedBorder 外环 + 实线框 + 中文序号「一/二/三/四」）
  ├─ 居中 Icon（40px，primary 色）
  └─ 说明正文（bodyMedium + onSurfaceVariant，居中）
```

### 第 5 页结构（表单）

```
_Article
  ├─ _ArticleLabel（「配置 AI」）
  ├─ 印章式序号「五」
  ├─ 说明正文（简述：填好以下信息，AI 才能真正可用）
  ├─ TextField：API 地址（如 https://api.openai.com/v1）
  ├─ TextField：API Key（obscureText: true）
  ├─ TextField：模型名（占位 gpt-4o-mini，可空，空则用占位值）
  ├─ Row：Switch「设为默认」+ 说明（默认开，is_default=1）
  └─ （「完成，开始使用」按钮在页面底部固定区，与前4页「下一步」同位）
```

## 纸感零件抽取

新建 `study_buddy/lib/core/theme/paper_widgets.dart`，把以下私有 widget 从原文件抽出为公共（去掉下划线）：

| widget | 原位置 | 公开名 |
|---|---|---|
| `_Article` | home_page.dart | `PaperArticle` |
| `_ArticleLabel` | home_page.dart | `PaperArticleLabel` |
| `_CornerMarkPainter` + `_CornerMark` | home_page.dart | `CornerMarkPainter` + `CornerMark` |
| `_StampIcon` | permission_guide_page.dart | `PaperStampIcon` |
| `_TipCard`（home 版） | home_page.dart | `PaperTipCard` |

**注意**：`_Stamp`（home_page 的状态印章）和 `_StampIcon`（permission_guide 的图标印章）是两个不同 widget——前者显示「已就绪/未开启」文字，后者显示 icon。引导页序号印章是新形态（显示中文序号），不复用任一，但参考其 `Transform.rotate(-3°) + DashedBorder` 范式新写 `_OnboardingSeal`（引导页私有）。

`_TipCard`（permission_guide 版，带「提示：」前缀）与 home 版（带「注」标签）文案不同——抽公共时做成可配 `label` 参数，两处原调用点各传自己的 label。

抽取后 `home_page.dart` 和 `permission_guide_page.dart` 改为 import 公共 widget，删除各自的私有定义。视觉零变化（纯重构）。

## 数据流

### 首次启动标记

- key：`onboarding_done`，bool，默认 false
- 写入时机：引导页「完成」或「跳过」时都写 true
- 读取：`main()` 预取一次，传给 router（不存 Riverpod，避免 router 依赖 provider）

### LLM 配置

引导页第 5 页「完成」时写 `llm_config` 表一条 `is_default=1` 记录。跳过时不写。

## 错误处理

| 场景 | 处理 |
|---|---|
| 第5页 URL 或 Key 为空 | 「完成」按钮置灰（onPressed: null），不弹错误 |
| db 未就绪就点完成 | 按钮 loading 态，await databaseProvider.future |
| insert 抛异常 | SnackBar「保存失败：$e」，不写 onboarding_done，留在引导页重试 |
| 跳过 | 直接写 onboarding_done=true，不触 db |
| 跳过后用户问 AI | getDefault() 返回 null → 抛现有"未配置默认 LLM"错误（已知降级，本次不补入口） |

## 测试策略

### engine 层（packages/study_engine）

`llm_config_repository_test.dart`（补或新建）：
- insert 一条 is_default=1 → getDefault() 返回它
- insert 两条不同 is_default → getDefault 返回 is_default=1 那条
- getDefault(vision: true) 无 supports_vision=1 的默认项时回退到普通默认

用 `sqflite_common_ffi` + `inMemoryDatabasePath`（已有基建）。

### app 层（study_buddy）

`test/features/onboarding/onboarding_page_test.dart`：
1. 渲染 OnboardingPage，第 1 页可见「截图悬浮球」标题
2. 点「下一步」→ PageView 跳第 2 页
3. 翻到第 5 页，URL/Key 留空 → 「完成」按钮置灰
4. 填齐 URL/Key → 点「完成」→ 验证 llm_config 表写入一条 is_default=1 + onboarding_done=true + 路由跳 `/`
5. 点「跳过」→ 验证 onboarding_done=true + 不写 llm_config + 跳 `/`

`test/router_test.dart`（新建）：
1. showOnboarding=true + 路径 `/` → redirect 到 `/onboarding`
2. showOnboarding=false + 路径 `/onboarding` → redirect 到 `/`
3. showOnboarding=false + 路径 `/` → 放行

**测试基建**：app widget test 用 `sqflite_common_ffi` in-memory db（`focus_session_provider_test.dart` 范例）+ `SharedPreferences.setMockInitialValues` mock prefs。

### 不测的

- 纸感视觉（颜色/字号/阴影）——人眼验
- SharedPreferences 持久化本身——框架保证

## 文件清单

| 文件 | 操作 | 职责 |
|---|---|---|
| `study_buddy/lib/main.dart` | 改 | main 变 async，预取 prefs，传 showOnboarding |
| `study_buddy/lib/app.dart` | 改 | StudyBuddyApp 接收 showOnboarding，传给 router |
| `study_buddy/lib/router.dart` | 改 | buildRouter 接收 showOnboarding，加 /onboarding 路由 + redirect |
| `study_buddy/lib/core/theme/paper_widgets.dart` | 新建 | 公共纸感零件 |
| `study_buddy/lib/features/home/home_page.dart` | 改 | 删私有纸感 widget，改 import 公共 |
| `study_buddy/lib/features/overlay/permission_guide_page.dart` | 改 | 删私有纸感 widget，改 import 公共 |
| `study_buddy/lib/features/onboarding/onboarding_page.dart` | 新建 | 引导页主体 + PageView + 5 步 + LLM 表单 |
| `packages/study_engine/test/llm_config_repository_test.dart` | 新建/改 | repo 路径测试 |
| `study_buddy/test/features/onboarding/onboarding_page_test.dart` | 新建 | 引导页 widget test |
| `study_buddy/test/router_test.dart` | 新建 | redirect 测试 |

## 依赖

零新依赖。`shared_preferences`（pubspec:52）、`study_engine` 的 `LlmConfigRepository`、`sqflite_common_ffi`（test）均已存在。
