# gemma4-screening

用 **Gemma 4 多模态（端侧）** 做自闭症**行为视频**早期信号筛查。全程在设备本地运行，健康/儿童数据不离开设备（可飞行模式运行）。

> ⚠️ 本工具仅作**早期信号提示**，不构成诊断。结论需由专业人员评估。

## 当前架构（端侧运行时：llama.cpp GGUF + mtmd）

| 项 | 说明 |
|---|---|
| 运行时 | **llama.cpp b9536 / GGUF / Metal / mtmd**（vendored 为 `ios/Vendor/llama.xcframework`） |
| 模型 | `model-Q4_K_M.gguf` + `mmproj-bf16.gguf`（主模型 + 多模态 projector，合计约 5.9GB，不入库） |
| 输入 | 视频抽帧（最多 32 帧）→ 音频 WAV（最多 30 秒）→ 中文文字指令 |
| 输出 | 模型只产出 **B01–B09 的 9 位二进制码**（`^[01]{9}$`）；最终 JSON（含 B10）由 **app 端拼装**后渲染为中文报告 |
| 设备 | iPhone 真机优先使用 Metal；模拟器/本机编译路径用于集成验证 |

> 当前不再走旧的 `.litertlm` 路径。旧文件如果还在 `ios/Model/`，不会被当前 `project.yml` 和 `ScreeningService` 引用。

## 接入规范（对齐模型侧官方文档）

抽帧、尺寸、prompt、解码参数严格复现 Mac/Linux GGUF 评估配置，详见仓库根目录的 [`docs/ios_gguf_code9_waudio_integration.md`](../docs/ios_gguf_code9_waudio_integration.md)：

- 抽帧：`frame_count = max(1, min(32, ceil(时长秒)))`；ASD-DS 文件优先使用文件名里的 `end-start` clip 时长；时间戳对齐本地 eval 的 ffmpeg `fps` 采样（`t = i*dur/frame_count`，起点锚定、顺序、覆盖整段）；每帧宽 512、保持比例、偶数高度、RGB、JPEG q95。
- 音频：单声道 16 kHz PCM WAV，最多 30 秒，并裁剪/补零到精确 PCM sample 数。
- 顺序：`frames → audio → text instruction`；每段片段**新建 conversation，无历史**。
- system / user prompt 逐字使用 `prompts/zh` 中文原文（**不让模型吐 JSON**）。
- 解码：确定性 `temperature=0 / topK=1 / topP=1`，并使用 GBNF grammar 约束正好 9 位。
- 输出：模型回 **9 位二进制码**，端上 `^[01]{9}$` 严格校验 → 拼装 JSON（`B10 = (B01..B09 全 false)`），非法码拦截。

## 状态

- ✅ SwiftPM core contract 测试通过：parser、B10 派生、prompt/media 顺序、采样参数、中文 prompt。
- ✅ iOS package simulator/device triple build 通过：`GlimmerCore` + `AsdGgufNative` + `GlimmerIOS`。
- ✅ 已生成 `ios/Vendor/llama.xcframework`，包含 `libllama`、`ggml`、`ggml-metal`、`ggml-blas`、`mtmd`。
- ✅ 已加真机 parity runner：可分别测试预构建 media 目录推理，以及 raw video → iOS preprocessing 的诊断输出。
- ⚠️ 真机运行前需要把两个 GGUF 权重复制成 `ios/Model/` 下的真实文件；下载权重流程后续再做。

## 目录

- `core/` — 跨平台 SwiftPM core，保存 GGUF 推理合约、prompt、parser 和测试。
- `ios/` — 端侧 SwiftUI app（GGUF）
  - `Package.swift` — SwiftPM package，管理 `GlimmerIOS`、`AsdGgufNative` 和 `llama.xcframework`
  - `App/` — 极薄 iOS app host，只负责 app entrypoint、Info.plist、entitlements、bundle/signing
  - `Sources/GlimmerIOS/ScreeningService.swift` — GGUF 权重定位、system prompt、9 位码解析
  - `Sources/GlimmerIOS/AsdGgufRunner.swift` — Swift runner，串行后台调用 native bridge
  - `Sources/GlimmerIOS/VideoAudioPreprocessor.swift` — 抽帧 + 音频提取（按 GGUF eval 规范）
  - `Sources/GlimmerIOS/ParityTestRunner.swift` — 预构建 media 目录的真机推理 parity runner
  - `Sources/GlimmerIOS/PreprocessParityRunner.swift` — raw video 真机预处理诊断 runner
  - `Sources/AsdGgufNative/` — Objective-C++ bridge，直接调用 llama.cpp / mtmd / grammar sampler
  - `Sources/GlimmerIOS/ReportView.swift` — B01–B10 严格校验 + 报告渲染
  - `Vendor/` — `llama.xcframework`
  - `Model/` — 放 `model-Q4_K_M.gguf` 和 `mmproj-bf16.gguf`（不入库，见「模型获取与放置」）
- `docs/ios_gguf_code9_waudio_integration.md` — GGUF 接入规范（输入/输出/问题诊断）
- `finetune/` — LoRA 微调脚本与数据格式
- `data/` — 样例数据集

## 模型获取与放置

模型权重**不入库**（`.gguf` 与 `ios/Model/` 已在 `.gitignore` 忽略）。当前真机测试先使用本地复制，后续再做下载权重：

| 项 | 值 |
|---|---|
| 主模型 | `outputs/gguf_experiments/gemma4-asd-code9-waudio-step420/model-Q4_K_M.gguf` |
| projector | `outputs/gguf_experiments/gemma4-asd-code9-waudio-step420/mmproj-bf16.gguf` |
| 放置路径 | `ios/Model/model-Q4_K_M.gguf` 和 `ios/Model/mmproj-bf16.gguf` |
| 大小 | 主模型约 4.9GB，projector 约 946MB |

```bash
cd ios
./Scripts/prepare-local-gguf-models.sh
```

> 真机构建前必须运行上面的脚本。`project.yml` 的 pre/post build script 会检查 bundle 里是非空真实文件，不允许把 symlink 打进 app。

## 构建（iOS）

```bash
cd ios
./Scripts/prepare-local-gguf-models.sh
xcodegen generate
xcodebuild -project GemmaScreen.xcodeproj -target GemmaScreen \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates build
```

本工程的核心代码和 native bridge 由 SwiftPM 管理；`GemmaScreen.xcodeproj` 只作为 iOS app host，负责 bundle、签名、entitlements 和安装运行。日常可以不打开 Xcode，直接用 `xcodegen` + `xcodebuild`。

> 当前本机 Xcode 环境可能要求 iOS 26.4 runtime；如果 `xcodebuild` 报 destination 不可用，需要先在 Xcode Components 安装对应 runtime，或切到匹配的 Xcode/设备 SDK。

## 行为标签（B01–B10）

| ID | 行为特征 |
|---|---|
| B01 | 缺乏或回避眼神接触 |
| B02 | 攻击行为 |
| B03 | 对感觉输入反应过度或不足 |
| B04 | 对言语互动缺乏回应 |
| B05 | 非典型语言 |
| B06 | 物体排列 |
| B07 | 自我击打或自伤行为 |
| B08 | 自我旋转或旋转物体 |
| B09 | 上肢刻板动作 |
| B10 | 背景（无明显目标行为） |
