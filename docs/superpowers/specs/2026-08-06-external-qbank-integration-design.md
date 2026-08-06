# 学习伴侣 APP — 外部题库集成（study.keyky.cn 客户端层）

- **日期**: 2026-08-06
- **项目**: study_buddy（Flutter 学习伴侣 APP）
- **阶段**: 第二阶段（MVP 子项目）
- **状态**: 已确认，待实施计划
- **前置依赖**: 地基阶段（已交付）

## 1. 背景与目标

study_buddy 地基已就绪（Agent ReAct 循环 + LLM Provider + SQLite 数据层 + StudyScenario）。本子项目引入**外部题库集成**：让用户能在 APP 内直接登录并使用 study.keyky.cn 的题库与刷题能力，同时保留 AI 知识点整理（走 study_engine 原路径）。

完整 APP 仍有多个独立子系统（拍照识题、知识点详情、出题刷题等）不在本 spec 范围。本 spec 仅覆盖**MVP：WebView 壳 + 浮窗 AI**。

### 1.1 MVP 交付目标

构建一个**最小可演示集成**：用户从 APP 首页进入题库页 → APP 用 `flutter_inappwebview` 加载 `https://study.keyky.cn/h5/` → 用户在 WebView 内登录网站 → 正常刷题 → 用户在任意页面点浮窗按钮 → 截屏该页面 → 弹出 AI 抽屉 → 调 StudyScenario 分析题目图片 → AI 回复流式显示 → 用户确认 → save_topic 落入 study_buddy 本地 topic 表。

### 1.2 关键约束（用户硬要求）

| 约束 | 解读 |
|---|---|
| **令牌不写死在代码里** | APP 不得硬编码任何网站鉴权凭据（token / cookie / Authorization 等）；不得把这些值 commit 到 git；不得通过 JS 桥从 WebView 取 token。登录态完全由 WebView 自然管理。 |
| **AI 服务走 study_engine 原路径** | 截图 → StudyScenario → save_topic / query_topics。AI 输出落到 APP 本地知识库（topic + mastery_log），不写回网站。 |
| **MVP 控制范围** | 不实现多账号、不实现进度同步服务、不实现错题本、不实现 API 调用（即使已破译）。 |

## 2. 设计输入（已确认决策）

| 维度 | 决策 |
|---|---|
| 集成形态 | WebView 壳 + 浮窗按钮 + 截图调用 StudyScenario |
| WebView 组件 | `flutter_inappwebview`（非官方 webview_flutter） |
| 登录方式 | WebView 内由 study.keyky.cn 自有登录页处理，APP 不介入 |
| 截图能力 | `flutter_inappwebview` 的 `InAppWebViewController.takeScreenshot()` |
| AI 触发 | 截图 → base64 → ImageUrlPart → StudyScenario 多模态输入（vision 由 LLM 原生处理；不新增工具） |
| 知识库存储 | 复用 study_engine 现有 topic / mastery_log 表（不新增表） |
| UI 框架 | 复用现有 Riverpod + go_router |
| 范围控制 | MVP：只读体验 + AI 助手；不做进度同步、不做本地刷题缓存 |

## 3. 顶层架构

```
┌─────────────────────────────────────────────────────────────┐
│ UI Layer (study_buddy/lib/features/external_qbank/)        │
│                                                             │
│   ExternalQbankPage (route: /external-qbank)                │
│     ├ QbankWebView        ← flutter_inappwebview           │
│     ├ FloatingAiButton    ← 浮动按钮（右下 FAB）             │
│     └ AiPanelSheet        ← 底部抽屉（agent 对话 + 流式）    │
│                                                             │
│   HomePage: 新增「进入题库」入口                              │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────────┐
│ Application Layer (study_buddy/lib/core/providers + 本地)    │
│                                                             │
│   externalQbankControllerProvider  控制 WebView + 按钮可见性  │
│   webViewScreenshotServiceProvider 截图 → temp 文件          │
│   agentSessionProvider（已有，复用）挂载截图消息               │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────────┐
│ Engine Layer (study_engine, 完全复用，零改动)                │
│                                                             │
│   StudyScenario (已有)                                       │
│     工具：save_topic / query_topics（已有，不变）             │
│   AgentLoop / AgentEvent / ContextCompactor (已有)           │
│   Vision content (已有 ContentPart.TextPart / ImageUrlPart)  │
│   └ 图片分析是 LLM 原生能力，不需要包装成 function 工具      │
└────────────────────┬────────────────────────────────────────┘
                     │
                   SQLite（app 沙盒文件，topic/mastery_log 已建）
```

依赖方向：UI → Application → Engine → DB。**WebView 是只读容器，不参与数据流**——除「截图」这一被动输出。

## 4. 关键流程

### 4.1 启动流程

```
User 打开 APP → HomePage
  ↓ 点「进入题库」按钮
ExternalQbankPage 加载 → InAppWebView 初始化
  ├─ initialUrl: 'https://study.keyky.cn/h5/'
  ├─ settings 允许 JS / DOM storage（保证网站登录态可用）
  └─ FloatingAiButton 浮在 WebView 之上
```

### 4.2 登录流程（APP 零参与）

```
WebView 加载 https://study.keyky.cn/h5/
  ↓
用户在 WebView 内看到 study.keyky.cn 登录页
  ↓
选择登录方式：手机号+短信 / 微信 OAuth / 苹果 OAuth 等
  ↓
网站自行处理 token 颁发与 cookie 写入
  ↓
APP 不读取任何 cookie，不构造任何 Authorization
```

### 4.3 AI 触发流程

```
User 在 WebView 内任意页面 → 点 FloatingAiButton
  ↓
FloatingAiButton.onPressed()
  ↓
webViewScreenshotService.takeScreenshot()
  ├─ controller.takeScreenshot() → Uint8List? pngBytes
  ├─ 若 null（无页面 / 截图失败）：弹 toast「请稍候再试」
  └─ bytes → Image.memory 预览（仅内存，不落盘）
  ↓
AiPanelSheet 弹出（modalBottomSheet）
  ├─ 顶部：截图缩略图 + 「重拍」按钮
  ├─ 中部：可选输入框（用户可补文字，比如「解析思路」）
  ├─ 底部：「开始分析」按钮
  ↓
User 点「开始分析」
  ├─ 构造 ChatMessage(role:'user', content:[
  │     TextPart(<用户输入或默认「分析这道题涉及的知识点」>),
  │     ImageUrlPart('data:image/png;base64,...', detail:'high')
  │  ])
  ├─ agentSessionProvider.run([...])   ← 复用 StudyScenario
  └─ 监听 Stream<AgentEvent> 增量更新
  ↓
LLM 直接读图（vision 原生能力） → 流式输出分析文本
  ↓
面板流式显示：
  - TextDeltaEvent → 追加到 AI 回复 TextField
  - ToolCallStartEvent → 显示「正在调用 XXX 工具」（如 save_topic）
  - ToolCallEndEvent → 显示工具结果摘要
  - AgentDoneEvent → 关闭 loading，AI 回复显示完整
  - AgentErrorEvent → 弹错误对话框
  ↓
若 LLM 自主决定调 save_topic
  → 知识点落入 study_buddy 本地 topic 表（用户可在 APP 内「知识库」看到）
  → 面板显示「已保存到知识库」徽标
```

> **关于「图片分析」为何不包装成工具**：图像理解是 LLM 的原生能力（多模态模型直接看 `ImageUrlPart` 输出文本），属于纯认知任务；function calling 工具是为「需要执行副作用」的动作设计的（如入库、查库、HTTP 请求）。把图片分析做成工具反而增加了一次无意义的工具往返，得不偿失。

### 4.4 错误处理

| 场景 | 处理 |
|---|---|
| WebView 加载失败 | 全屏重试按钮 + Toast |
| takeScreenshot 返回 null | Toast「请等待页面加载完成」 |
| LLM 调用失败 | AgentErrorEvent → 弹错误对话框，可重试 |
| LLM 调用了不允许的工具 | scenario.executeTool 抛错 → 显示工具结果「执行失败」 |
| 图片过大（>10MB） | 截图前压缩到长边 1920px，压缩到 base64 后控制在 5MB 内 |
| 网络断开 | 截图仅在内存中保留到当前会话结束，AI 请求失败即丢弃；不缓存到磁盘、不入库（下次启动不留存） |

## 5. 数据层扩展

**MVP 不新增表**。复用现有：
- `topic`（AI 整理的知识点落地）
- `mastery_log`（可选，由 save_topic 触发）
- `chat_session` / `chat_message`（已有，agent 对话历史自动写入）

图片**不落盘、不入库、不缓存**——`takeScreenshot()` 返回的 `Uint8List` 仅在内存中持有：
- 转 base64 后直接构造 `ImageUrlPart('data:image/png;base64,...')` 喂给 LLM
- 抽屉关闭（会话结束）即随 widget 销毁释放
- `path_provider` 依赖因此**不需要**（见 §7 依赖清单已移除）

## 6. 关键文件清单

### 新增

```
study_buddy/lib/features/external_qbank/
  external_qbank_page.dart           # WebView 容器页 + 浮窗按钮 + 抽屉
  qbank_web_view.dart                # flutter_inappwebview 封装
  floating_ai_button.dart            # 浮窗 FAB widget（Stack 定位）
  ai_panel_sheet.dart                # 底部抽屉（截图预览 + agent 对话流）
  providers/
    webview_screenshot_provider.dart # 截图 service
    ai_panel_provider.dart           # 控制 sheet 状态 + agent session
```

### 修改

```
study_buddy/pubspec.yaml             # + flutter_inappwebview（无需 path_provider，截图纯内存）
study_buddy/lib/router.dart          # 新路由 /external-qbank
study_buddy/lib/features/home/home_page.dart  # 增加「进入题库」入口
```

> **engine 层零改动** —— StudyScenario、save_topic/query_topics、AgentLoop、vision content 全部直接复用。无需新增工具、无需改 migration、无需新增测试。

## 7. 依赖与初始化

### pubspec.yaml 增量

```yaml
dependencies:
  flutter_inappwebview: ^6.x     # WebView 容器（支持 takeScreenshot）
  # 不引入 path_provider：截图全程在内存中，不落盘
```

### Android 配置

- `minSdkVersion >= 21`（flutter_inappwebview 要求）
- `AndroidManifest.xml`：网络权限（已有）
- 登录方式完全由 study.keyky.cn 自处理（扫码 / 手机号 / 微信 等），APP 不介入；MVP 无需额外适配

### iOS 配置

- `ios/Runner/Info.plist`：允许 `study.keyky.cn` 域名（默认允许 https 即可）

### 初始化流程（main.dart）

```dart
// 已有不变；ProviderScope 已包裹，新增 ExternalQbank 相关 Provider 即可。
```

## 8. 验收标准

1. **静态检查**：`flutter analyze` 全绿（app + engine 两个包；engine 包零改动，回归原有规则）。
2. **引擎层单测**：`flutter test` 全部通过（验证 engine 包未破坏；无需新增测试）。
3. **APP 启动**：`flutter run -d windows` / Android / iOS 任一平台能跑。
4. **手工验收**（含敏感项验证）：
   - [ ] APP 首页有「进入题库」入口。
   - [ ] 点入口打开 ExternalQbankPage，WebView 加载 study.keyky.cn，未登录可看到首页。
   - [ ] WebView 内通过网站登录页（扫码 / 手机号等，由网站自身处理）完成登录，正常刷题。
   - [ ] 点击 FloatingAiButton → AiPanelSheet 弹出，截图预览可见。
   - [ ] 点「开始分析」→ 流式显示 AI 回复文本。
   - [ ] 若 LLM 自主调 save_topic → 知识点落入 study_buddy 本地 topic 表。
   - [ ] **代码与 git 历史中无任何 study.keyky.cn 鉴权凭据字面值**（token / cookie / Authorization 均不得出现）。
5. **平台兼容**：
   - Windows：可运行（WebView 在 Windows 表现可能与移动端不同，仅保证不崩溃）。
   - Android / iOS：核心场景全部通过。

## 9. 明确不做（YAGNI 边界）

- ❌ 任何 study.keyky.cn 的 API 调用（含已破译的 `/api/q_bank`、`/api/chapter`、AES 解密）。
- ❌ 任何 token / cookie / Authorization 的 APP 端构造或持久化。
- ❌ 进度同步服务（WebView 自带网站刷题，进度由网站记录，APP 不感知）。
- ❌ 多账号管理、收藏本地化、错题本、复习提醒。
- ❌ AI 整理结果回写到 study.keyky.cn。
- ❌ dispatch_subagent 子 agent。
- ❌ 主动拦截 WebView 网络请求读取 cookie（避免触及隐私边界）。
- ❌ JS 桥注入（不向 WebView 注入任何 JS 代码，仅作容器）。
- ❌ 题库列表本地缓存（即使只读）。
- ❌ 离线模式（题目纯在线，断网直接报错）。

## 10. 后续演进方向（不在本 spec 范围）

> 用户已明确：不考虑网站是哪个、APP 不缓存任何网站内容、不写回网站。
> 因此所有「调用网站 API」「缓存网站数据」「网站笔记同步」方向均不列入演进清单。
> 后续仅围绕 APP 自身能力（如：知识库详情 UI、掌握度看板、错题本的本地结构）扩展。

1. **知识库详情 UI** — 复用 topic 表，可视化 AI 已入库的知识点列表与详情。
2. **多 WebView 实例** — 同时打开多个题库对比刷题（复杂度高，慎入）。
3. **AI 主动模式** — APP 端检测到截图后自动触发分析（无需用户点浮窗）。

## 11. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 微信 OAuth 在 WebView 内受限 | MVP 推荐手机号登录；微信登录留作体验优化 |
| study.keyky.cn 反调试干扰 WebView | WebView 不暴露 DevTools；用户自行在浏览器调试 |
| `flutter_inappwebview` 在 Windows 表现差 | MVP 重点保证 Android / iOS；Windows 仅保证不崩溃 |
| 截图大图超 LLM 上下文 | 截图前压缩（长边 1920px，base64 ≤ 5MB） |
| 网站 UI 改版导致浮窗遮挡关键按钮 | FloatingAiButton 默认右下；后续可提供位置设置 |
| LLM 响应慢导致用户重复点击 | AiPanelSheet 在 agent 运行时禁用「开始分析」按钮 |