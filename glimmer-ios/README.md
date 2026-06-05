# gemma4-screening

用 **Gemma 4 多模态（端侧）** 做自闭症**行为视频**早期信号筛查。全程在设备本地运行，健康/儿童数据不离开设备（可飞行模式运行）。

> ⚠️ 本工具仅作**早期信号提示**，不构成诊断。结论需由专业人员评估。

## 当前架构（端侧运行时：Google LiteRT-LM）

| 项 | 说明 |
|---|---|
| 运行时 | **LiteRT-LM**（Swift，vendored 为 `ios/Vendor/CLiteRTLM.xcframework`） |
| 模型 | `asd-gemma4-code9.litertlm`（微调 + QLoRA/LoftQ W4 量化，纯视觉版，**约 7.8GB，不入库**） |
| 输入 | 视频抽帧（多张图）→ 中文文字指令；本模型包**无 audio encoder**，音频通道关闭 |
| 输出 | 模型只产出 **B01–B09 的 9 位二进制码**（`^[01]{9}$`）；最终 JSON（含 B10）由 **app 端拼装**后渲染为中文报告 |
| 设备 | iPhone（真机用 Metal GPU；模拟器用 CPU，自动回退）。真机实测推理峰值 **≈1.2GB**（mmap 加载，7.8GB 文件多为干净文件页，不计入 jetsam footprint） |

> LiteRT-LM 既能在**真机（GPU）**也能在**模拟器（CPU）**运行多模态；MLX 仅限真机 Metal、无法在模拟器跑，故迁移到 LiteRT-LM。

## 接入规范（对齐模型侧官方文档）

抽帧、尺寸、prompt、解码参数严格复现训练配置，详见 [`docs/ios-integration-report.md`](docs/ios-integration-report.md)：

- 抽帧：`frame_count = max(1, min(16, ceil(时长秒)))`；时间戳对齐本地 eval 的 ffmpeg `fps` 采样（`t = i*dur/frame_count`，起点锚定、顺序、覆盖整段）；每帧宽 512、保持比例、RGB、JPEG q95。
- 顺序：`frames → text instruction`（本包无 audio）；每段片段**新建 conversation，无历史**。
- system / user prompt 逐字使用 `prompts/zh` 中文原文（**不让模型吐 JSON**）。
- 解码：确定性 `temperature=0 / topK=1 / topP=1`。
- 输出：模型回 **9 位二进制码**，端上 `^[01]{9}$` 严格校验 → 拼装 JSON（`B10 = (B01..B09 全 false)`），非法码拦截。

## 状态

- ✅ iOS 接入完成：抽帧、输入顺序、中文 prompt、确定性解码、9 位码解析 + 端侧拼装 JSON、B01–B10 中文报告渲染。
- ✅ **真机跑通**：iPhone 17 Pro / Metal GPU / 离线，完整链路出报告，推理峰值 ≈1.2GB。
- ✅ **盲测有区分力**：对带真值片段盲跑，主导标签 B08 两段均正确命中（与模型侧 LiteRT W4 指标 micro-F1≈0.46 一致），不再是早期 Q4 版的全 false。
- ✅ **同模型 Mac/iOS 逐位一致**：`/tmp/litertlm-run`（Mac CLI）与 iOS 端对同一片段输出相同 9 位码，验证抽帧/prompt/解码对齐。

## 目录

- `ios/` — 端侧 SwiftUI app（LiteRT-LM）
  - `Sources/ScreeningService.swift` — 引擎加载（GPU→CPU 回退）、system prompt、确定性采样、多帧推理
  - `Sources/AnalysisView.swift` — 抽帧（按训练规范）+ 调用推理
  - `Sources/ReportView.swift` — B01–B10 严格校验 + 报告渲染
  - `Vendor/` — LiteRT-LM Swift 源码 + xcframework
  - `Model/` — 放 `asd-gemma4-code9.litertlm`（不入库，见「模型获取与放置」）
- `docs/ios-integration-report.md` — 接入测试报告（输入/输出/问题诊断）
- `finetune/` — LoRA 微调脚本与数据格式
- `data/` — 样例数据集

## 模型获取与放置

模型权重**不入库**（`.litertlm` 与 `ios/Model/` 已在 `.gitignore` 忽略；单文件 7.8GB 也超 GitHub 限制）。换机器或交接时需另行获取：

| 项 | 值 |
|---|---|
| 文件名 | `asd-gemma4-code9.litertlm` |
| 来源 | 模型侧 S3：`s3://huzi-nydata/asd-gemma4-code9-qlora-loftq-w4-noaudio.litertlm`（向模型负责人「虎子」要预签名 URL） |
| 放置路径 | `ios/Model/asd-gemma4-code9.litertlm` |
| 大小 / 校验 | ≈7.8GB（8,353,991,904 bytes）；下载后建议 `shasum -a 256` 对一次 |

```bash
# 拿到预签名 URL 后：
curl -L -o ios/Model/asd-gemma4-code9.litertlm "<S3 预签名 URL>"
```

> 文件名必须与 `ios/project.yml`（`Model/asd-gemma4-code9.litertlm`）及 `ScreeningService.modelResource`（`"asd-gemma4-code9"`）一致，否则 app 启动时找不到模型。

## 构建（iOS）

```bash
cd ios
# 1. 放入模型：Model/asd-gemma4-code9.litertlm（见上节）
# 2. 生成工程
xcodegen generate
# 3. 真机构建（需付费开发者账号 + 增大内存权限）
xcodebuild -project GemmaScreen.xcodeproj -scheme GemmaScreen \
  -destination 'id=<设备UDID>' -allowProvisioningUpdates build
```

> 需要 `increased-memory-limit` + `extended-virtual-addressing` 权限，要求**付费 Apple Developer 账号**。模型经 mmap 加载，真机推理峰值实测 ≈1.2GB（远低于 7.8GB 文件体积）。

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
