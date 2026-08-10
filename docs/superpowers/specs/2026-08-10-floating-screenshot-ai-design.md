# 学习伴侣 APP — 系统级截图悬浮窗 + AI 分析

- **日期**: 2026-08-10
- **项目**: study_buddy（Flutter 学习伴侣 APP）
- **阶段**: 第三阶段（MVP 子项目，重构 + 新能力）
- **状态**: 已确认，待实施计划
- **前置依赖**: 外部题库集成阶段（已交付 master，含 `ai_panel_sheet` 与 `agent_session_provider`）

## 1. 背景与目标

study_buddy 第二阶段用内嵌 WebView（`flutter_inappwebview`）加载 `study.keyky.cn`，在 WebView 内刷题并截图调 AI。本阶段**废弃内嵌浏览器方案**，改为**系统级截图悬浮窗**：用户在**任意 app / 任意界面**（系统浏览器刷 study.keyky.cn、微信、PDF 阅读器等）唤起悬浮球 → 框选题目区域 → 自动跳回 study_buddy → AI 流式分析涉及的知识点并可选入库。

核心动机：内嵌 WebView 把刷题体验限制在 study_buddy 进程内，且 WebView 截图只能截 WebView 自己的内容；系统级悬浮窗让用户在原生浏览器或任意场景刷题时都能截图分析，覆盖面更广。

完整 APP 仍有多个独立子系统（拍照识题、知识点详情、出题刷题等）不在本 spec 范围。本 spec 仅覆盖 **MVP：删 WebView + 系统悬浮球 + 区域截图 + 跳回 App 分析**。

### 1.1 MVP 交付目标

构建一个**最小可演示的端到端链路**：

1. 用户启动 study_buddy → 授予悬浮窗权限 → 原生悬浮球在任意界面常驻
2. 用户在任意 app 刷题 → 点悬浮球 → 屏幕冻结成全屏截图 → 拖拽框选题目矩形区域
3. 裁剪完成 → 跳回 study_buddy 主 App → 弹出 AI 面板（复用 `ai_panel_sheet`）→ 截图作为 vision 上下文
4. AI 流式分析（复用 `AgentSession` → `StudyScenario`）→ 用户确认 → 可选 `save_topic` 落库

### 1.2 关键约束（用户硬要求 + 技术硬约束）

| 约束 | 解读 |
|---|---|
| **删除内嵌浏览器** | 移除 `flutter_inappwebview` 依赖及全部 WebView 相关代码（见 §3.2 删除清单）。`ai_panel_sheet` 保留并改输入源。 |
| **令牌不写死** | 沿用上一阶段硬约束：源码与 git 历史不得出现任何网站鉴权凭据字面值。本阶段不接触任何网站鉴权（截图是系统级，与网站无关）。 |
| **AI 走 study_engine 原路径** | 截图 → `StudyScenario` → `save_topic` / 知识点整理。AI 输出落本地知识库，不写回任何网站。engine 零改动。 |
| **截图纯内存** | 沿用上一阶段：截图 bytes 不落盘、不缓存，仅在 AI 面板生命周期内有效。 |
| **需要 agent_session_provider** | 沿用上一阶段：AI 调用经 `agentSessionProvider`，本阶段不新增 agent 入口。 |
| **Android 14+ FGS 时序** | 必须先用户授权 MediaProjection，再 `startForeground(type=mediaProjection)`，再 `getMediaProjection()`；顺序错则 `SecurityException`。 |
| **Android 14+ 授权 token 不可缓存复用** | 每次 MediaProjection 会话必须走新授权；缓存的旧 Intent 再传 `getMediaProjection()` 会崩。 |
| **国产 ROM 兼容** | MIUI / ColorOS / OriginOS 悬浮窗权限页各异 + 「后台弹出界面」权限 + 前台服务被杀，需做厂商判断、兜底跳转、白名单引导、降级路径。 |

## 2. 设计输入（已确认决策）

| 维度 | 决策 | 依据 |
|---|---|---|
| 悬浮窗范围 | **系统级**（任意 app / 界面） | 用户确认；删除 WebView 后 app 内无内容可截 |
| 悬浮球实现 | **纯原生自研**（Service + WindowManager + ImageView） | 专家建议：避免第二 Flutter engine 的 30–50MB 常驻内存；200–300 行可控 |
| 截图技术 | **MediaProjection + VirtualDisplay + ImageReader 按需取帧** | Android 14+ 标准方案；按需挂 surface 零持续开销 |
| 授权策略 | **会话制**：授权一次 → FGS + VirtualDisplay 常驻 → 后续截图免授权；服务被杀才重新授权 | 专家建议；权衡「每次弹框打扰」vs「常驻通知」，选会话制 |
| 选区 UI 形态 | **第二个全屏悬浮窗**（`TYPE_APPLICATION_OVERLAY` 可触摸），非 Activity | 专家建议：无 Activity 启动限制、瞬时出现无闪屏、与悬浮球同体系 |
| 选区交互 | **原生自定义 View** 拖拽框选（onTouchEvent 算 Rect + Canvas 画遮罩 + 四角手柄） | 专家建议：无 Flutter 插件覆盖此语境；200–300 行可控 |
| 截图后去向 | **跳回 study_buddy 主 App**，在 App 内打开 AI 面板 | 用户确认（拉回 App 内分析） |
| 冷启动降级 | **纳入 MVP**：原生 Application 级单例暂存最近截图，App 重启时检查并自动补打开 AI 面板 | App 被回收时截图不丢；核心体验 |
| AI 面板 | **复用 `ai_panel_sheet`**，仅改 `CapturedScreenshot` 来源（WebView 截图 → 原生 channel 截图） | 9 分支事件渲染逻辑与 WebView 无关 |
| engine | **零改动** | 硬约束；22 个测试不受影响 |
| UI 框架 | 复用 Riverpod + go_router | 沿用现有 |

## 3. 顶层架构

```
┌─────────────────────────────────────────────────────────────────┐
│ Native Layer (study_buddy/android/.../kotlin, 纯原生)            │
│                                                                 │
│   OverlayService          ← 前台服务，WindowManager 增删悬浮球    │
│     └ 悬浮球 ImageView（拖拽贴边、点击触发截图）                  │
│                                                                 │
│   TrampolineActivity      ← 1px 透明 Activity，授权 + 启 FGS     │
│   ScreenCaptureService    ← FGS(mediaProjection) + 取帧          │
│   CropOverlayView         ← 全屏冻结图 + 拖拽框选 + 裁剪          │
│   ScreenshotPlugin        ← FlutterPlugin，MethodChannel 桥接    │
│   PendingScreenshotHolder ← Application 级单例，冷启动降级暂存    │
└────────────────────┬────────────────────────────────────────────┘
                     │ MethodChannel / Intent
┌────────────────────▼────────────────────────────────────────────┐
│ Flutter Layer (study_buddy/lib/)                                │
│                                                                 │
│   main.dart                ← 启动唤起 OverlayService              │
│   home_page.dart           ← 悬浮窗状态（已开/去设置）             │
│   features/overlay/permission_guide_page.dart  ← 首次权限引导    │
│   features/external_qbank/ai_panel_sheet.dart   ← 复用（改输入源）│
│   core/providers/screenshot_provider.dart       ← MethodChannel  │
│   core/providers/agent_session_provider.dart    ← 复用（零改动）  │
└────────────────────┬────────────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────────────┐
│ Engine Layer (packages/study_engine, 零改动)                     │
│   AgentSession → StudyScenario → AgentLoop → AgentEvent 流       │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 数据流（端到端时序）

```
① App 启动 → checkOverlayPermission()
   ├─ 未授权 → PermissionGuidePage（「去开启悬浮窗权限」→ 系统设置）
   └─ 已授权 → showOverlay() 唤起 OverlayService 悬浮球

② 用户在任意 app → 点悬浮球
   → OverlayService: removeView(悬浮球) 隐藏
   → 延迟 300ms（等 2–3 VSYNC + SurfaceFlinger 合成）
   → 首次：TrampolineActivity 弹 MediaProjection 授权框
       → onActivityResult 拿授权 Intent
       → startForegroundService(ScreenCaptureService) + startForeground(mediaProjection)
       → getMediaProjection() → createVirtualDisplay + ImageReader 取一帧
   → 后续（会话内存活）：直接从 ImageReader 取最新一帧

③ ScreenCaptureService 取到全屏 Bitmap
   → WindowManager 添加第二个全屏 CropOverlayView（显示冻结图）
   → 用户拖拽框选 Rect（onTouchEvent）
   → Bitmap.createBitmap(full, x, y, w, h) 裁剪（density 换算）

④ 裁剪完成
   → removeView(CropOverlayView) + 恢复悬浮球
   → PNG bytes 存入 PendingScreenshotHolder（Application 级，防冷启动丢失）
   → startActivity 拉回 study_buddy 主 App（singleTop + Intent flag）
   → Flutter App 收到拉回（onResume / new intent）→ MethodChannel takePendingScreenshot() 从 holder 取 PNG bytes
   → showAiPanel(context, screenshot: CapturedScreenshot(bytes, dataUri))
   → AgentSession.run(messages) 流式分析 → 可选 save_topic 落库
```

### 3.2 删除清单（WebView 模块）

| 文件/项 | 处理 |
|---|---|
| `lib/features/external_qbank/qbank_web_view.dart` | 删 |
| `lib/features/external_qbank/external_qbank_page.dart` | 删 |
| `lib/features/external_qbank/floating_ai_button.dart` | 删 |
| `lib/core/providers/webview_screenshot_provider.dart` | 删 |
| `lib/router.dart` 的 `/external-qbank` 路由 | 删 |
| `lib/features/home/home_page.dart` 的「进入题库」入口 | 删 |
| `pubspec.yaml` 的 `flutter_inappwebview: ^6.1.5` | 删 |
| `lib/features/external_qbank/ai_panel_sheet.dart` | **保留**，改 `CapturedScreenshot` 来源 |
| `lib/core/providers/agent_session_provider.dart` | **保留**，零改动 |

### 3.3 新增清单

| 文件 | 职责 |
|---|---|
| `android/.../kotlin/.../OverlayService.kt` | 悬浮球前台服务（WindowManager 增删、拖拽贴边、点击触发截图） |
| `android/.../kotlin/.../TrampolineActivity.kt` | 透明 Activity，MediaProjection 授权 + 启 FGS |
| `android/.../kotlin/.../ScreenCaptureService.kt` | FGS + MediaProjection + VirtualDisplay + ImageReader 取帧 |
| `android/.../kotlin/.../CropOverlayView.kt` | 全屏冻结图 + 拖拽框选 + 手柄 + 裁剪 |
| `android/.../kotlin/.../ScreenshotPlugin.kt` | FlutterPlugin + MethodChannel/EventChannel 桥接 |
| `android/.../kotlin/.../PendingScreenshotHolder.kt` | Application 级单例，冷启动降级暂存截图 |
| `android/.../AndroidManifest.xml` | 加 3 个声明（见 §4.1） |
| `lib/core/providers/screenshot_provider.dart` | MethodChannel 封装 + 权限检查 + 接收截图回调 |
| `lib/features/overlay/permission_guide_page.dart` | 首次悬浮窗权限引导页 |
| `lib/main.dart` | 改：启动时检查权限 + 唤起 OverlayService + 检查待处理截图 |
| `lib/features/home/home_page.dart` | 改：删题库入口，加悬浮窗状态显示 |
| `lib/router.dart` | 改：删 `/external-qbank`，加 `/permission-guide`（可选） |

## 4. 详细设计

### 4.1 AndroidManifest 声明（Android 14+ 强校验，缺一崩）

```xml
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />

<application ...>
  <activity android:name=".TrampolineActivity"
            android:theme="@android:style/Theme.Translucent.NoTitleBar"
            android:exported="false" />

  <service android:name=".OverlayService"
           android:exported="false"
           android:foregroundServiceType="specialUse">
    <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
              android:value="Floating screenshot assist button for study analysis" />
  </service>

  <service android:name=".ScreenCaptureService"
           android:exported="false"
           android:foregroundServiceType="mediaProjection" />
</application>
```

> 说明：`OverlayService` 用 `specialUse` FGS（悬浮球常驻需保活），`ScreenCaptureService` 用 `mediaProjection` FGS。Android 14+ 要求 `specialUse` 必须声明 `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`，否则上架被拒。

### 4.2 原生模块职责与接口

**OverlayService.kt**（约 200–300 行）
- 前台服务，`WindowManager.addView` 添加 56dp 圆形悬浮球（`TYPE_APPLICATION_OVERLAY`）
- `OnTouchListener`：短按 → 触发截图流程；长按拖拽 → 移动位置 + 贴边吸附
- `hideOverlay()` / `showOverlay()`：截图前 removeView，截图后恢复
- 点击触发：`startActivity(TrampolineActivity)`（持有 `SYSTEM_ALERT_WINDOW` 豁免后台启动 Activity 限制）

**TrampolineActivity.kt**（约 100–150 行）
- 1px 透明 `Theme.Translucent.NoTitleBar` Activity，无 UI
- `onCreate` → `MediaProjectionManager.createScreenCaptureIntent()` → `startActivityForResult` 弹系统授权框
- `onActivityResult`：授权成功 → `startForegroundService(ScreenCaptureService)` 传授权 Intent → `finish()`；授权拒绝 → `finish()` 通知 Flutter 失败
- 后续会话内截图不走此 Activity（直接从 ScreenCaptureService 取帧）

**ScreenCaptureService.kt**（约 250–350 行）
- FGS（`foregroundServiceType="mediaProjection"`），`onStartCommand` 先 `startForeground`（通知栏投屏图标，技术必然不可去除）再 `getMediaProjection()`
- `MediaProjection.createVirtualDisplay` + `ImageReader`（按需挂 surface：截图瞬间挂上取一帧，取完卸载，零持续开销）
- 取到 `Image` → 转 `Bitmap`（全屏，物理像素）→ 通知 `CropOverlayView` 显示
- 会话制：VirtualDisplay 不销毁、不调 `projection.stop()`、服务不被杀 → 后续截图免授权
- 降级：服务被杀 / 用户从通知栏停止 → 下次点击重新走 TrampolineActivity 授权

**CropOverlayView.kt**（约 250–350 行）
- `WindowManager.addView` 添加的全屏 `TYPE_APPLICATION_OVERLAY`（可触摸，`FLAG_NOT_TOUCH_MODAL` 去掉）
- `onDraw`：绘制冻结的全屏 Bitmap + 半透明遮罩 + 选区矩形 + 四角手柄
- `onTouchEvent`：DOWN 记起点 → MOVE 更新 Rect + invalidate → UP 确认
- 裁剪：`Bitmap.createBitmap(fullBitmap, x, y, w, h)`，**x/y/w/h 按 VirtualDisplay 物理像素与触摸坐标 density 换算**
- 完成回调：裁剪后 PNG bytes → `PendingScreenshotHolder.put(bytes)` → 拉回主 App

**ScreenshotPlugin.kt**（约 100 行）
- 实现 `FlutterPlugin`，在 MainActivity 注册
- `MethodChannel("study_buddy/overlay")`：
  - `checkOverlayPermission()` → `Settings.canDrawOverlays()` → bool
  - `requestOverlayPermission()` → 跳 `ACTION_MANAGE_OVERLAY_PERMISSION`（厂商判断 + 兜底应用详情页）
  - `showOverlay()` / `hideOverlay()` → 控制 OverlayService
- `takePendingScreenshot()` → 读 `PendingScreenshotHolder.take()` 返回 PNG bytes（或 null）
- 拉回主 App：`startActivity(Intent(mainActivity).addFlags(FLAG_ACTIVITY_NEW_TASK|FLAG_ACTIVITY_SINGLE_TOP))`
- 截图统一走 holder + take 模式（热/冷路径一致，不使用 EventChannel 推送，规避双进程时序问题）

**PendingScreenshotHolder.kt**（约 50 行）
- `Application` 级单例（`companion object`），`var pending: ByteArray?`
- 裁剪完成 `put(bytes)`；App 冷启动时 Flutter 调 `take()` 取出并清空
- 防冷启动丢失：App 进程被回收时，原生进程（OverlayService/ScreenCaptureService）若仍存活，截图已暂存；App 重启 `main.dart` 检查并自动 `showAiPanel`

### 4.3 Flutter 侧接口

**screenshot_provider.dart**
```dart
// MethodChannel("study_buddy/overlay") 封装
Future<bool> checkOverlayPermission();
Future<void> requestOverlayPermission();
Future<void> showOverlay();
Future<void> hideOverlay();

// 接收截图：App 启动 / 被拉回前台时检查
Future<CapturedScreenshot?> takePendingScreenshot();
```

**main.dart 启动流程**
```
App 启动
  → checkOverlayPermission()
      ├─ false → 跳 PermissionGuidePage
      └─ true  → showOverlay() + takePendingScreenshot()
                    ├─ 有 → showAiPanel(screenshot)
                    └─ 无 → 正常首页
```

**ai_panel_sheet.dart 改动**
- 仅 `showAiPanel` 的 `screenshot` 参数类型不变（`CapturedScreenshot`）
- `CapturedScreenshot` 类从 `webview_screenshot_provider.dart`（将删）迁移到 `screenshot_provider.dart`
- 构造方式：原生传回 `Uint8List pngBytes` → `base64Encode` → `CapturedScreenshot(bytes, 'data:image/png;base64,$b64')`（与原 WebView 路径构造一致）

### 4.4 错误处理与边界（专家点名的 7 个坑）

| # | 坑 | 处理策略 |
|---|---|---|
| 1 | 厂商 ROM 悬浮窗权限页差异 | `requestOverlayPermission` 内做厂商判断（MIUI/ColorOS/OriginOS），针对性跳转；兜底跳应用详情页。小米额外引导「后台弹出界面」权限，否则 TrampolineActivity 起不来。 |
| 2 | 后台被杀（息屏后国产 ROM 杀 FGS） | 引导用户加白名单（自启动 + 电池无限制）；服务死 → 下次点击重新走 TrampolineActivity 授权（降级路径，对用户表现为「再点一次 + 弹一次授权框」）。 |
| 3 | `FLAG_SECURE` 黑屏 | 银行/DRM 页面截图全黑是系统行为。CropOverlayView 检测全黑 Bitmap → 提示「该页面受保护，无法截图」而非当 bug。 |
| 4 | Android 14+ 授权 token 不可缓存 | 每次 MediaProjection 会话走新授权（TrampolineActivity 新 createScreenCaptureIntent）；**绝不**缓存旧 Intent 复用。会话制靠 VirtualDisplay 常驻，不靠 token 缓存。 |
| 5 | VirtualDisplay 物理像素 vs 触摸坐标 | 裁剪前统一换算：`physicalX = touchX * density`，`physicalY = touchY * density`；全面屏手势区/inset 在选区 UI 处理。 |
| 6 | 截图被对方 app 感知 + 状态栏投屏图标 | Android 14+ 截图检测 API 让对方 app 知道被截；FGS 期间状态栏有投屏图标。合规文案：PermissionGuidePage 说明「截图仅用于本地 AI 分析，不上传不分享」。 |
| 7 | Google Play specialUse 用途声明 | `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 写清楚用途；上架声明 `SYSTEM_ALERT_WINDOW` + 屏幕捕获用途，否则被拒。 |

### 4.5 冷启动降级路径（MVP 纳入）

```
用户点悬浮球 → 截图裁剪 → put(PendingScreenshotHolder)
  → startActivity 拉回 study_buddy
      ├─ App 进程存活（热）：App onResume / new intent → takePendingScreenshot() → showAiPanel
      └─ App 进程被回收（冷）：App 重启 → main.dart takePendingScreenshot()
                                → 有 → showAiPanel → 清空 holder
                                → 无 → 正常首页
```

边界：原生进程（OverlayService）也被杀时，holder 随进程消失，截图丢失——此场景用户表现为「点了没反应」，下次点击重新走全流程。属可接受降级（专家确认国产 ROM 杀 FGS 无法完全规避）。

## 5. 测试策略

| 层 | 策略 |
|---|---|
| **engine** | 零改动，22 个测试不受影响（硬约束验证） |
| **Dart 单元** | `screenshot_provider` 用 mock MethodChannel 测权限检查/接收逻辑 |
| **Dart widget** | `permission_guide_page`、`home_page`（悬浮窗状态显示）widget 测试 |
| **原生** | 专家骨架可跑；权限流程/冷热启动降级/选区裁剪坐标走**真机手动验收清单**（国产 ROM 自动化 ROI 低） |
| **不写** | MediaProjection 设备级集成自动化；厂商 ROM 差异化 UI 自动化 |

真机验收清单（写入实施计划 Task）：
- [ ] 首次启动 → 权限引导 → 授权 → 悬浮球出现
- [ ] 系统浏览器刷 study.keyky.cn → 点悬浮球 → 授权框 → 框选 → 跳回 App → AI 分析
- [ ] 会话内二次截图 → 免授权框
- [ ] 冷启动：杀 App 进程 → 点悬浮球 → 截图 → App 重启自动打开 AI 面板
- [ ] FLAG_SECURE 页面（银行 app）→ 黑屏提示
- [ ] MIUI 真机：悬浮窗权限 + 后台弹出界面权限引导

## 6. 范围控制（MVP 不做）

- 多账号 / 进度同步 / 错题本（沿用上一阶段）
- 选区 UI 高级功能（放大镜、尺寸标注、撤销）—— 仅基础拖拽框选 + 四角手柄
- 截图历史 / 截图落盘缓存 —— 纯内存，用完即弃
- iOS 支持 —— 本阶段仅 Android（MediaProjection 是 Android 能力）
- 悬浮球样式自定义 / 主题 —— 固定 56dp 圆形

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 原生自研工作量大（1000–1300 行 Kotlin） | 按 5 模块拆分任务，每模块独立可测；专家已给骨架方向 |
| 国产 ROM 兼容不可穷举 | 真机验收覆盖 MIUI/原生；其余走降级路径 + 用户引导 |
| Google Play 上架风险 | specialUse 声明 + 用途文案；预检阶段 review |
| MediaProjection 时序坑（Android 14+） | 严格按「授权 → startForeground → getMediaProjection」顺序；实现期对照专家时序图 |
| 双进程通信状态丢失 | PendingScreenshotHolder 兜底；holder 自身随进程消失属可接受降级 |

## 8. 硬约束自检（沿用上一阶段格式）

1. **无鉴权凭据字面值**：本阶段不接触任何网站鉴权，截图是系统级。源码扫描仍查 `ixunke`/`xkh5-token`/`Authorization.*Bearer`/`study.keyky.cn` + commit message，预期仅 `study.keyky.cn` 可能出现在用户文档/验收清单（非凭据）。
2. **engine 零改动**：`packages/study_engine` 不动，22/22 测试通过。
3. **截图纯内存**：原生 PNG bytes 经 channel 传 Flutter，不写文件系统；`CapturedScreenshot` 仅 widget 生命周期内有效。
4. **agent_session_provider 保留**：AI 调用经 `agentSessionProvider`，不新增 agent 入口。

---

**下一步**：spec 自审 → 用户审阅 → 调用 writing-plans 生成实施计划（按 5 原生模块 + Flutter 改造拆任务，SDD 执行）。
