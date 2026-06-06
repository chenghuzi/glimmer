# Glimmer 新版 UI 重做 — 接手文档

> 本文档记录的是「新版 8 屏全流程重做」这一轮工作的现状。
> 计划原文：`~/.claude/plans/purrfect-jingling-kite.md`
> Figma：`https://www.figma.com/design/VP12dmteNhyEKeKmh4Hp3r/ASD?node-id=66-468`（**底部一排**是新版，顶部一排是旧版）
> 当前分支：`newcodec`（已 `git reset --hard origin/master`，所有改动都是 uncommitted 的）

## 已完成的视觉屏（按 visual loop 收敛）

| # | 屏 | 文件 | 状态 |
|---|---|---|---|
| 1 | 启动页 | `Screens/SplashView.swift` | ✅ 收敛 mean diff 2.83 |
| 2 | 模型加载 | `Screens/ModelLoadingView.swift` | ✅ 收敛 mean diff 3.86 |
| 3 | 首页 | `Screens/HomeView.swift` | ✅ 收敛 mean diff 7.04 |
| 4 | 拍摄相机 | — | ⏭ **不复刻**，用系统原生（详见下） |
| 5 | 拍摄完成弹窗 | `Screens/CaptureDoneDialog.swift` | ✅ 结构对齐 |
| 6 | 分析中 | `Screens/AnalyzingView.swift` | ✅ 收敛 mean diff 4.63；流式 SSE 已接 |
| 7 | 报告结论 | — | ❌ **未做** |
| 8 | 追问对话 | — | ❌ **未做** |

## 已搭好的基础设施

### Gallery 可视化壳（核心迭代工具）
- 新增 `GlimmerGallery` target（**仅模拟器**，不打包 GGUF 模型，无校验脚本）
- 入口：`Gallery/GlimmerGalleryApp.swift` + `Sources/GlimmerIOS/Gallery/GalleryRoot.swift`
- 用环境变量 `GLIMMER_SCREEN=splash|loading|home|capture_done|analyzing|flow|...` 深链单屏
- 工作流脚本：
  - `/tmp/glimmer_build.sh` — 构建 + 装到模拟器
  - `/tmp/glimmer_shot.sh <screen> <out>` — 启动屏 + 截图 + 缩放到 375×812
- 模拟器 UDID 写在 `/tmp/glimmer_sim_udid.txt`（iPhone 13 mini，iOS 26.5，逻辑 375×812 与 Figma 一致）

### 设计 tokens
- `Theme.swift` 里新增 `GTheme`（`splashBg #EDE9DF`、`bg #F2F2EC`、`blueCard #EEF2F5`、`ink #29291F`、`subtle rgba(.6)`、圆角/字号常量等）
- 老 `ASDTheme` 保留（旧 ContentView/AnalysisView 还在用，没退役）
- 字体：中文用系统 PingFang SC（默认），标题 Semibold；"Glimmer" 字标是图片资源不是字体

### 流程协调器
- `AppRootView.swift`：`splash → (检查模型) → loading?/home`
  - **已实现按需 loading**：splash 后检查 `ModelCatalog.items.allSatisfy(isDownloaded || bundled)`，已就绪直接进 home，不显示 loading 屏
- `MainFlow` 子视图：home → action sheet → VideoPicker → CaptureDoneDialog → AnalysisFlowView

### 模型下载
- `ModelCatalog.swift`：模型清单 + 本地落盘（`Application Support/GlimmerModels/`）+ 运行时优先用下载的
- `ModelDownloadManager.swift`：URLSession.download 真实下载，按文件粒度推进 progress
- ⚠️ **占位 URL**：`https://models.example.com/glimmer/...`（标了 TODO，替换为真实 CDN 即生效）
- 占位时走「模拟进度」模式，2.4 秒走完，方便联调 UI
- `ScreeningService.ensureLoaded()` 已改成 `ModelCatalog.resolvedURL(...)`，优先下载好的，回退随包

### 真实流式（SSE）
- `ASDGgufNativeRunner.h/.mm` 新增 `generateStreamWithSystemPrompt:userPrompt:mediaPaths:onToken:error:`
  - 复用同一 token loop，每解一个 token piece 就调用 `onToken(piece)`
  - 旧的 `generateWithSystemPrompt:...` 现在内部转调 stream 版（onToken=nil），向后兼容
- `AsdGgufRunner.swift` 新增 `generateStream(systemPrompt:request:onToken:)` async API，回调到 @MainActor
- `ScreeningService.swift` 新增 `analyzeStream(...)`，按位累加到 `output`
- `AnalyzingView` 订阅 `partialCode`，每来一位（'0'/'1'）就揭示一个 B 标签（B01-B09），observed='1' 用 medium 字重，未观察用 light
- Grammar 已保证每个 token = 1 bit，9 个 token 出齐就是完整 9 位 code
- `AnalyzingDemoContainer` 用 demo code `"101100010"` 每 500ms 揭示一位，gallery 路由 `analyzing` 用它演示效果（已验证视觉 SSE 流式正确）

### 星星素材去方块（重要）
- Figma 导出的星星都带烘焙好的方形底色（image-fill 节点）
- 用 PIL flood-fill 从边角扫描扣掉底色：见 `Resources/star_*.png` 都已处理
- 关键技巧：
  - 启动大星 thresh=18
  - 首页探头星 thresh=16
  - 加载滑块星 thresh=12（小图边缘陡）
- 重新生成需要原始 Figma 渲染（用 `get_screenshot` 而不是 `get_design_context` 给的 image-fill URL，前者带正确 alpha）

### FigmaCanvas（绝对定位辅助）
- `Components/FigmaCanvas.swift` — 固定 375×812 坐标空间居中放
- `.figmaFrame(x:y:w:h:align:)` — 按 Figma 左上角原点放置任意子视图
- 配合 375 宽的 mini 模拟器即为像素级精确对齐

## 当前的接线问题（这是中断时的状态）

### 1. `confirmationDialog` 样式（已修复并验证）
- 修复后：
  ```swift
  .confirmationDialog("", isPresented: $showSourceDialog, titleVisibility: .hidden) {
      Button("拍摄") { startPicker(.camera) }
      Button("从相册选择") { startPicker(.photoLibrary) }
      Button("取消", role: .cancel) {}
  }
  ```
- iOS 26 渲染：**Liquid Glass 居中浮动卡片**，只显示「拍摄/从相册选择」两个圆角按钮，无标题/副文案。
- ⚠️ Cancel 按钮 **iOS 26 默认不在卡片里显示**，靠点击卡片外取消（系统行为）。如果产品强要"取消"在卡片里可见，要自建底部 sheet（不用 confirmationDialog）。当前接受 iOS 26 原生默认行为。
- 测试路径：Gallery 用 `GLIMMER_SCREEN=source_sheet` 启动验证。

### 2. HomeView 视频诊断卡的 hit-test（已验证）
- 用 `Button { videoCardBody }` 包裹，已通过 `source_sheet` gallery 路由验证：sheet 能正常弹出。
- ⚠️ `simctl io tap` 不存在（之前用错了）。要测交互只能：(a) 加 `onAppear` 自动触发的 demo gallery 路由 (b) 人手在模拟器里点 (c) Xcode UI Test。

### 3. 分析完之后的报告屏是占位
- `AnalysisFlowView` 完成分析后跳到 `ReportPlaceholder`
- `ReportPlaceholder` 套了一层新 NavBar/PlayerBar/Tab，里面塞的是**旧 ReportView**（B01-B10 勾选清单）
- **要做的**：实现新的 `ReportConversationView`（屏 7+8），替换掉这个占位

## 还没做的事

### A. 屏 7+8 报告结论 + 追问对话（**最大缺口**）
- Figma：53:751（报告结论）+ 53:994（追问对话）
- 规格已用 `get_design_context` 拉好（参看 plan 文档）
- 关键元素：
  - 大灰卡（#f6f6f5）+ 「报告结论」标题 + 散文 + 底部「本工具仅作早期信号提示」白条
  - PlayerBar 复用
  - 底部「可以和我聊聊」输入框（玻璃感半透明，黄色光标，深色发送圆按钮）
  - 屏 8 是滚到下面：用户气泡 + 助手要点回复
- 后端：用户定**先用 mock 文案搭视觉壳**（散文报告 + 追问对话先 mock）；真实接入是后续轮次
- 真模型只出 B01-B09 9 位码，没有散文，没有 chat 能力。Mock 数据可以放在 `MockData.swift`

### B. action sheet 文案调整（看上面 #1）

### C. HomeView 点击触发验证（看上面 #2）

### D. 把新 `ReportConversationView` 接到 `AnalysisFlowView` 替换 `ReportPlaceholder`

### E. （可选）退役旧文件
- 现在还在仓库里且没用上的：`ContentView.swift`、`AnalysisView.swift`、`ReportView.swift`（被 ReportPlaceholder 临时复用）
- `GlimmerRootView` 现在指向 `AppRootView()`，旧的 ContentView 实际不会被实例化
- 等屏 7/8 做完可以删旧的；当前保留有助于回滚

## 关键文件清单

### 新增
```
ios/Gallery/GlimmerGalleryApp.swift               # gallery target 入口
ios/Sources/GlimmerIOS/AppRootView.swift          # 流程协调器
ios/Sources/GlimmerIOS/ModelCatalog.swift         # 模型清单 + 本地路径
ios/Sources/GlimmerIOS/ModelDownloadManager.swift # 下载机
ios/Sources/GlimmerIOS/Gallery/GalleryRoot.swift  # 深链路由
ios/Sources/GlimmerIOS/Components/FigmaCanvas.swift
ios/Sources/GlimmerIOS/Components/GlimmerTabBar.swift
ios/Sources/GlimmerIOS/Components/GlimmerNavBar.swift
ios/Sources/GlimmerIOS/Components/PlayerBar.swift
ios/Sources/GlimmerIOS/Screens/SplashView.swift
ios/Sources/GlimmerIOS/Screens/ModelLoadingView.swift
ios/Sources/GlimmerIOS/Screens/HomeView.swift
ios/Sources/GlimmerIOS/Screens/CaptureDoneDialog.swift
ios/Sources/GlimmerIOS/Screens/AnalyzingView.swift
ios/Sources/GlimmerIOS/Screens/AnalysisFlowView.swift   # 包含临时 ReportPlaceholder
ios/Resources/star_splash.png  star_peek.png  star_knob.png   # 去方块的星星
ios/Resources/glimmer_wordmark.png  light_beam.png
ios/Resources/phone_rec.png  icon_menu.png  icon_play.png
ios/Resources/icon_ai_small.png  icon_chevron_back.png
ios/Resources/tab_analyze.png  tab_report.png
```

### 修改
```
ios/Sources/GlimmerIOS/Theme.swift                 # 加 GTheme + Font.gRounded
ios/Sources/GlimmerIOS/GlimmerRootView.swift       # 改为渲染 AppRootView
ios/Sources/GlimmerIOS/ScreeningService.swift      # 加 analyzeStream + 模型路径走 ModelCatalog
ios/Sources/GlimmerIOS/AsdGgufRunner.swift         # 加 generateStream
ios/Sources/AsdGgufNative/include/ASDGgufNativeRunner.h
ios/Sources/AsdGgufNative/ASDGgufNativeRunner.mm   # 加 generateStream，旧 API 转调
ios/project.yml                                    # 加 GlimmerGallery target + scheme
```

### 不动
- `ContentView.swift`、`AnalysisView.swift`、`ReportView.swift`（旧的，待退役）
- `VideoPicker.swift`（复用了）
- `VideoAudioPreprocessor.swift`、`MediaDiagnostics.swift`、`ParityTestRunner.swift`、`PreprocessParityRunner.swift`、`AudioExtractor.swift`
- `core/Sources/GlimmerCore/*`

## 怎么继续

### 构建 & 截图
```bash
# 修改代码后
cd /Users/damon/code/asdgemma/glimmer-ios/ios
xcodegen generate    # 仅当 project.yml 改了或加了资源
/tmp/glimmer_build.sh                            # build + install
/tmp/glimmer_shot.sh <screen> /tmp/glimmer_<x>   # 启动 + 截图 + 缩到 375×812
```

可用的 `<screen>` 值：`splash`、`loading`、`home`、`capture_done`、`analyzing`、`flow`（含完整流程）

### visual loop 单屏还原模板
```bash
# 1. Figma 参考已在 /tmp/asd_*.png 里（或重新 get_screenshot）
# 2. 改 SwiftUI 代码
# 3. /tmp/glimmer_build.sh && /tmp/glimmer_shot.sh <screen> /tmp/glimmer_<x>
# 4. 用 PIL 做 Phase A (结构) + Phase B (几何/颜色精校)：
PY=/Users/damon/code/asdgemma/.venv/bin/python
$PY -c "
from PIL import Image; import numpy as np
def load(p): return np.asarray(Image.open(p).convert('RGB').resize((375,812)),dtype=np.int16)
ref=load('asd_<x>.png'); mine=load('glimmer_<x>.png')
print('mean|diff|(excl statusbar)=%.2f'%float(np.abs(ref[54:]-mine[54:]).mean()))
"
```

### 接屏 7/8 的入口
1. 用 Figma MCP 重新拉 `get_design_context` for 53:751 和 53:994
2. 下载需要的新素材（输入框背景、send 图标已下到 `Resources/icon_send.png`）
3. 写 `Screens/ReportConversationView.swift`，参考 `AnalyzingView` 同样的 FigmaCanvas + 绝对定位结构
4. 在 `Gallery/GalleryRoot.swift` 里把 `case "report"` 和 `case "qa"` 接上
5. 在 `Screens/AnalysisFlowView.swift` 里把 `ReportPlaceholder` 换成 `ReportConversationView`

### 真模型接入
- 占位 URL 改成真实 CDN：`ModelCatalog.swift` 里 `Item(...)` 的 `remoteURL`
- 自动失效 `ModelDownloadManager.usesPlaceholderURLs`，走真实下载路径
- 真机首启会下载 ~5.9GB 到 Application Support，后续启动 splash 后直接进 home

## 重要约束 & 陷阱

1. **模拟器没有相机**：`startPicker(.camera)` 会自动回退到 `.photoLibrary`，逻辑在 `MainFlow.startPicker`
2. **`simctl io tap` 不存在**：之前用错了。要在模拟器里测交互只能：(a) 人手鼠标点击 (b) 用 AppleScript 控制模拟器 (c) 在 app 里加调试入口
3. **GGUF 模型不入库**（5.9GB）：`GlimmerGallery` target 故意不打包模型，秒级构建；`GemmaScreen` 主 target 的 pre/post-build script 会校验模型存在，跑前要 `Scripts/prepare-local-gguf-models.sh`
4. **状态栏不画**：模拟器自己有真实状态栏，之前用 `simctl status_bar override` 改 9:41 已撤销
5. **Origin force-pushed**：`newcodec` 已 reset 到 `origin/master`，所有当前改动都是 uncommitted。提交时注意 git status 里有哪些是真要的（不要把 .build/.derivedData 这些带进去）
6. **PingFang SC 字体**：直接用 `.system(size:)`，iOS 系统中文字体即是 PingFang SC
7. **图片资源路径**：所有 PNG 都直接放在 `ios/Resources/` 目录（loose PNG，`UIImage(named:)` 直接找）；不用 asset catalog
8. **流式 token 性质**：grammar `bit ::= "0" | "1"` 保证每个 token 就是 "0" 或 "1"；`onToken(piece)` 每次回调的 `piece` 长度通常是 1
9. **`ScreeningService.analyze` vs `analyzeStream`**：前者是一次性，后者是 SSE；旧 `AnalysisView` 调的是 `analyze`，新 `AnalysisFlowView` 调的是 `analyzeStream`

## 已确认的设计决策（用户拍板）

- ✅ 范围：8 屏全做（不只是部分）
- ✅ 后端策略：报告/对话先用 mock 文案搭壳，真实推理接入留后续轮次
- ✅ 屏 4 拍摄相机：不复刻 53:351，用系统原生（`UIImagePickerController`）
- ✅ 选择器：原生底部 action sheet（拍摄/选相册/取消）—— 但 iOS 26 上 confirmationDialog 默认有 title+message 时样式不对，要去标题和副文案
- ✅ 拍摄完成弹窗：保留中间确认（不要选完直接走推理）
- ✅ Loading 屏按需：splash 后检查模型已就绪则跳过 loading 直接 home
- ✅ 状态栏不画

## 进度速览

```
✅ 启动页（visual + 模型预检逻辑）
✅ 模型加载页（visual + 真实下载机 + 占位 URL）
✅ 首页（visual + Button 入口）
⏭ 拍摄相机（用系统原生，不复刻）
✅ 拍摄完成弹窗（visual）
✅ 分析中（visual + 真实流式 SSE）
❌ 报告结论（屏 7）
❌ 追问对话（屏 8）
🟡 主流程接线（基本通了，但 action sheet 样式 + HomeView Button 触发未验证）
```
