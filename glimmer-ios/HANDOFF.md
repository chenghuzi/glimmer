# Glimmer iOS 重设计 —— 交接文档（Handoff）

> 分支：`feat/glimmer-redesign`　|　仓库：`asdgemma/glimmer-ios`
> 更新时间：2026-06-06
> Figma：`https://www.figma.com/design/VP12dmteNhyEKeKmh4Hp3r/ASD?node-id=66-468`（**底部一排**是新版）
> 计划原文：`~/.claude/plans/purrfect-jingling-kite.md`

## 0. 一句话现状

新版 8 屏 UI 已全部搭好并接通真后端（chenghuzi 的 9-code 分类 + 本地解释对话）。**自适应布局重构（固定 375×812 绝对定位 → 安全区 + VStack/HStack/Spacer）已完成**：代码改完、`xcodebuild` 编译通过、并在模拟器 iPhone 16 + iPhone 17 Pro Max 两档屏逐屏目测确认铺满无黑边（大屏黑边 bug 已解）。**仅剩真机复跑确认**（见 §1 TODO 4）。另有一个**模型侧阻塞问题**（见 `MODEL_ISSUE.md`）等 chenghuzi 处理。

---

## 1. 本轮正在做的：自适应布局重构（进行中）

### 起因
用户在 iPhone 17 Pro（402×874pt）真机上发现：内容上下留黑边、"没顶到头"（分析页最明显）、左右没铺满、返回按钮位置不对。

根因：`Components/FigmaCanvas.swift` 把整个 375×812 设计画布**居中、不缩放**地贴屏，大屏四周留边；所有 `figmaFrame(x:y:w:h:)` 都是相对这个居中画布的绝对坐标。

### 方向（用户拍板，重要）
> 不要做缩放 / 按宽高比硬怼坐标的"奇怪做法"。直接用正常画页面的逻辑摆素材：导航左按钮放左边、logo/文案居中，用真实约束撑开，让元素自然落在安全区里。

### 统一骨架
```swift
ZStack {
    背景色.ignoresSafeArea()          // 只有背景铺满全屏
    VStack/HStack { …内容… }          // 内容默认落在安全区内
        .padding(.horizontal, 16)
}
```
- 顶部导航：VStack 首项 `GlimmerNavBar` + `.padding(.top, 8)`（安全区已让出状态栏/灵动岛）
- 底部 Tab：VStack 末项 `GlimmerTabBar`（安全区已让出 Home Indicator）
- 卡片/进度条：`.frame(maxWidth: .infinity)` 或 `GeometryReader` 撑开，不再写死宽度

### 已改文件（本轮）
**组件（去掉写死的 375/343 宽）**
- `Components/GlimmerNavBar.swift`：`.frame(width:375…)` → `maxWidth:.infinity, minHeight:54`
- `Components/GlimmerTabBar.swift`：→ `maxWidth:.infinity, minHeight:52`
- `Components/PlayerBar.swift`：`.frame(width:343…)` → `maxWidth:.infinity, minHeight:48`

**屏幕（从 FigmaCanvas/figmaFrame 重写为正常布局）**
- `Screens/SplashView.swift`：吉祥物+字标垂直成组居中、光束贴底全宽、tagline 贴底
- `Screens/ModelLoadingView.swift`：字标居中、进度条用 `GeometryReader`（最大 300 宽，星星滑块随进度 `offset`）、隐私脚注贴底
- `Screens/HomeView.swift`：标题靠左 + 探头星星右上 `offset` 探出、视频卡 `maxWidth:.infinity` 撑满、Tab 贴底
- `Screens/AnalyzingView.swift`：`body` 改成 `ZStack+VStack`（Nav→卡片→Player→Tab）；分析卡 `maxHeight:.infinity` 填满；流式列表 `StreamingBehaviorList`、动态省略号 `AnimatedEllipsis`、节奏推进 `.task` **逻辑全部保留未动**

> `Components/FigmaCanvas.swift` 重构后已无人引用（可后续删除，本轮先留着）。

### 本轮剩余 TODO 进度（2026-06-06 收敛）
1. ✅ **编译验证**：`xcodegen generate` + `xcodebuild -scheme GlimmerGallery -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build` → **BUILD SUCCEEDED**。
   - 注意 destination 只写 `name=iPhone 16` 会因多 OS 版本歧义而静默列出设备不构建；带上 `OS=18.6`（或用确定存在的机型）。
   - 编辑器里的 `Cannot find 'GTheme'/'bundleImage' in scope` 全是 **SourceKit 单文件索引误报**，以 `xcodebuild` 为准。
2. ✅ **逐屏目测**（模拟器，无 SE 可用 → 用 iPhone 16 标准屏 + iPhone 17 Pro Max 大屏夹逼）：splash / loading / home / analyzing(动画) / report 全部铺满、无黑边、nav 贴安全区顶、tab 贴 Home Indicator。大屏上「上下黑边 / 没顶到头 / 返回按钮位置」**已解**。
3. ✅ **`ReportConversationView.swift` 收尾**：`.padding(.top, 54)` → `.padding(.top, 8)`、滚动内容 `.padding(.top, 120)` → `76`；已在 iPhone 16 + 17 Pro Max 上目测确认 nav 与卡片无重叠、无黑边。
4. ⬜ **真机复跑**：模拟器跑不了真模型（见下），布局已在模拟器两档屏验证；返回按钮 / 顶到头的真机复核仍待在 iPhone 17 Pro 真机上跑一次确认。

> ⚠️ **Gallery 选屏：`analyzing` ≠ `analyze`**（`GalleryRoot.swift`）
> - `analyzing`（带 ing）→ `AnalyzingDemoContainer`，**纯 UI mock，不碰模型**，动画跑完自动转到 `ReportConversationView`。**模拟器目测分析中动画 / 报告页用这个。**
> - `analyze`（无 ing）→ `AnalysisFlowView(test_clip.mov)`，跑**真模型**，在模拟器上加载 mmproj 时 **Metal 崩溃**（`ggml_metal_buffer_set_tensor` → `_xpc_api_misuse`，见 §3/§4），只能真机。
> - `report` / `qa` 这两个 `GLIMMER_SCREEN` 值目前是 placeholder「未实现」，报告页要经 `analyzing` 流程才能看到。

---

## 2. 项目整体状态

### 流程（8 屏）
`AppRootView`（`splash → loading → main`）→ `MainFlow`：
首页 → 系统来源选择器(confirmationDialog：拍摄/相册) → 相机拍完弹 `CaptureDoneDialog`（相册选的直接进分析）→ `AnalysisFlowView` → `AnalyzingView`（流式 9-code 动画）→ `ReportConversationView`（结论 SSE 逐字 + 本地追问对话）。

| # | 屏 | 文件 |
|---|---|---|
| 1 | 启动页 | `Screens/SplashView.swift` |
| 2 | 模型加载 | `Screens/ModelLoadingView.swift` |
| 3 | 首页 | `Screens/HomeView.swift` |
| 4 | 拍摄 | 用系统原生（不复刻） |
| 5 | 拍摄完成弹窗 | `Screens/CaptureDoneDialog.swift` |
| 6 | 分析中 | `Screens/AnalyzingView.swift` |
| 7+8 | 报告结论 + 追问对话 | `Screens/ReportConversationView.swift` |

### 后端接线（已完成，真模型）
- `ScreeningService`：`analyze`（出 9 位 code → `AsdBehaviorReport`）+ `beginExplanationChat`/`sendChatMessage`（chenghuzi 的 KV-cache 多轮解释对话）
- 报告结论文案 = app 端按 9 位码模板拼接（确定性，不走模型 NL）；底部追问 = 真模型自然语言
- 模型随包进 `GlimmerGallery`（`project.yml` 已配 device 签名 + bundled gguf），首页之前不再触发下载权限弹窗

### 纯视觉兜底（未提交）
`mtmd_support_audio` 为 false 时跳过音频、不再硬失败。涉及：
`AsdGgufNative/ASDGgufNativeRunner.mm` + `.h`、`AsdGgufRunner.swift`（`supportsAudio`）、`ScreeningService.swift`（`audioURL: runner.supportsAudio ? … : nil`）。

---

## 3. ⚠️ 模型侧阻塞（非本端问题）—— 详见 `MODEL_ISSUE.md`

HF `chenghuzi/glimmer-e4b-asd9-gguf` 当前两份 GGUF：
1. **mmproj 是纯视觉导出**（`mtmd_support_audio`=false），但模型按 `waudio`（带音频）训练 → 原版真机加载即报 `GGUF projector does not support audio input`。
2. 强制纯视觉后能跑，但**对任意图片恒定输出 `100000001`**（分类塌缩，与画面无关）。

相比"之前能跑通的版本"是回归。已就绪的纯视觉兜底会在 chenghuzi 重新导出带音频塔的 GGUF mmproj 后，由 `supportsAudio` 自动切回音频链路，无需再改代码。litertlm 那份格式与 llama.cpp 不兼容。

---

## 4. 构建 / 跑模拟器

```bash
cd glimmer-ios/ios
xcodegen generate
xcodebuild -project GemmaScreen.xcodeproj -scheme GlimmerGallery \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build   # 不带 OS 会因多版本歧义不构建
# 选屏：环境变量 GLIMMER_SCREEN = splash|loading|home|analyzing|analyze|report|qa
# 纯 UI 目测（分析中动画→报告页）：用 analyzing（带 ing），不碰模型
SIMCTL_CHILD_GLIMMER_SCREEN=analyzing xcrun simctl launch booted cn.youyou.glimmergallery
xcrun simctl io booted screenshot /tmp/shot.png
```
> 模拟器**跑不了真模型**（Metal 加载 mmproj 崩溃：`mtmd_init_from_file` → `ggml_metal_buffer_set_tensor` → `_xpc_api_misuse` SIGTRAP）。
> - `analyzing`（带 ing）= 纯 UI mock，模拟器目测专用；`analyze`（无 ing）= 真模型流程，**模拟器必崩**，只能真机（`devicectl`）。
> - `report` / `qa` 目前是「未实现」placeholder，报告页经 `analyzing` 流程查看。

旧的辅助脚本（如还在）：`/tmp/glimmer_build.sh`、`/tmp/glimmer_shot.sh <screen> <out>`；模拟器 UDID 在 `/tmp/glimmer_sim_udid.txt`。

---

## 5. 关键路径速查

| 用途 | 文件 |
|---|---|
| 设计 tokens / 颜色 / `bundleImage` | `Sources/GlimmerIOS/Theme.swift`（`GTheme`） |
| 流程协调器 + 来源选择器 | `Sources/GlimmerIOS/AppRootView.swift` |
| 分析流程驱动（analyze→动画→报告→startChat） | `Sources/GlimmerIOS/Screens/AnalysisFlowView.swift` |
| 真后端服务 | `Sources/GlimmerIOS/ScreeningService.swift` |
| native 桥（mtmd/llama.cpp） | `Sources/AsdGgufNative/ASDGgufNativeRunner.mm` |
| 9-code 解析/结论模板 | `core/Sources/GlimmerCore/AsdBehaviorParser.swift` |
| 模型清单 + 下载 | `Sources/GlimmerIOS/ModelCatalog.swift` / `ModelDownloadManager.swift` |
| Gallery 选屏 harness | `Sources/GlimmerIOS/Gallery/` + `project.yml` 的 `GlimmerGallery` target |

### 星星素材去方块（重生成时用）
Figma 导出的星星带烘焙的方形底色，用 PIL flood-fill 从边角扣底：启动大星 thresh=18 / 首页探头星 16 / 加载滑块星 12。重新生成需用 `get_screenshot`（带正确 alpha）而非 `get_design_context` 的 image-fill URL。`Resources/star_*.png` 都已处理。

---

## 6. 未提交改动清单（`git status`）
```
M  AsdGgufNative/ASDGgufNativeRunner.mm        # 纯视觉兜底
M  AsdGgufNative/include/ASDGgufNativeRunner.h # supportsAudio
M  GlimmerIOS/AsdGgufRunner.swift              # supportsAudio
M  GlimmerIOS/ScreeningService.swift           # audioURL 可选
M  GlimmerIOS/Components/GlimmerNavBar.swift    # ← 本轮自适应
M  GlimmerIOS/Components/GlimmerTabBar.swift    # ← 本轮自适应
M  GlimmerIOS/Components/PlayerBar.swift        # ← 本轮自适应
M  GlimmerIOS/Screens/AnalyzingView.swift       # ← 本轮自适应
M  GlimmerIOS/Screens/HomeView.swift            # ← 本轮自适应
M  GlimmerIOS/Screens/ModelLoadingView.swift    # ← 本轮自适应
M  GlimmerIOS/Screens/SplashView.swift          # ← 本轮自适应
M  GlimmerIOS/Screens/ReportConversationView.swift # ← 自适应收尾（top 54→8 / 120→76）
M  ios/project.yml                              # ← 两 target 加 ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
?? ios/Resources/Assets.xcassets/                # ← app icon（Figma 76-294 毛绒星星，2048 源合成 1024）
?? glimmer-ios/MODEL_ISSUE.md                    # 模型问题报告（给 chenghuzi）
?? glimmer-ios/HANDOFF.md                        # 本文档
```
均**未提交**。提交前先按 §1 的 TODO 编译 + 目测收敛。
