# 模型问题报告：HF GGUF 版分类塌缩 + mmproj 缺音频

> 面向模型侧（chenghuzi）。iOS App 集成与 UI 已就绪，本文记录的是**模型/权重**层面的两个阻塞问题，以及可直接复现的步骤。

## TL;DR

当前 HF `chenghuzi/glimmer-e4b-asd9-gguf` 的两份 GGUF 在 iOS（llama.cpp / mtmd 运行时）上有两个问题：

1. **mmproj 是纯视觉导出**（`mtmd_support_audio` = false），但模型是 `waudio`（带音频）训练的 → 真机加载即报 `GGUF projector does not support audio input`。
2. 强制走纯视觉后能跑，但**对任意图片都恒定输出 `100000001`**，分类不再区分内容（疑似分布外输入导致塌缩）。

相比"之前能跑通的版本"这是一次**回归**。

---

## 复现环境

- macOS，`brew install llama.cpp`（build 9430）
- 权重：HF `chenghuzi/glimmer-e4b-asd9-gguf`
  - `model-Q4_K_M.gguf`（≈4.9 GiB）
  - `mmproj-bf16.gguf`（≈946 MiB）
  - = 本机 `glimmer-ios/ios/Model/` 下两份
- Prompt：仓库 `prompts/zh/system.md` + `prompts/zh/user.md`（训练原配，未改）
- 解码：`temperature=0 / topK=1`，GBNF 约束正好 9 位（与 eval 一致）

## 复现命令

```bash
cd glimmer-ios/ios/Model
printf 'root ::= [01] [01] [01] [01] [01] [01] [01] [01] [01]\n' > /tmp/code9.gbnf
SYS=$(cat ../../../prompts/zh/system.md)
USER=$(cat ../../../prompts/zh/user.md)

# 换不同图片，重复跑
llama-mtmd-cli -m model-Q4_K_M.gguf --mmproj mmproj-bf16.gguf \
  --image <任意图>.jpg -sys "$SYS" -p "$USER" \
  --grammar-file /tmp/code9.gbnf --temp 0 -n 12 -ngl 99
```

---

## 问题 1：mmproj 不支持音频

真机 App 加载即失败：

```
结果解析失败
出错：GGUF projector does not support audio input.
```

- 来源：native runner 加载时调用 `mtmd_support_audio(mtmd_)` 返回 false。
- 这份 `mmproj-bf16.gguf` 是**纯视觉**导出（不含音频塔）。
- 但模型按 `frames → audio → text` 训练（实验名 `gemma4-asd-code9-waudio-step420`，`waudio` = with audio）。
- 原版 runner 把音频作为硬性要求，缺失即 `model load` 失败。

> chenghuzi 自己未改动的原版 App（master `8e13821`）真机上也报同样的错 → 与 iOS 集成无关。

## 问题 2：分类塌缩，输出与视觉输入无关

把音频改为可选、强制纯视觉后能加载并出码，但**任意图片输出同一个码**：

| 输入 | 9 位码 |
|---|---|
| 孩子堆罐头（B06 排列物品场景） | `100000001` |
| 另一张样本图 | `100000001` |
| 纯灰图 512×512 | `100000001` |

补充观察：

- 自由描述（去掉 grammar，prompt 改成"用一句话描述图里有什么"）→
  `"The brand of the food in the fridge is not specified."`
  视觉**勉强在工作**（识别到食物/罐头），但分类头不区分内容。
- 喂 16 / 32 帧（同图重复）→ 变成 `000000001`。
  即模型对**输入结构**（帧数 / 有无音频）敏感，对**画面内容**不敏感。

---

## 判断

当前 HF 这版（纯视觉 mmproj + 该量化 checkpoint）相比"之前能跑通的版本"**回归了**。最可能的链路：

- 导出 mmproj 时丢了音频塔 →
  - ① 真机报 audio 错；
  - ② 强行纯视觉后，推理输入（纯视觉）与训练分布（带音频）不一致 → 分类塌缩成恒定码。

## 请 chenghuzi 确认 / 提供

1. **重新导出带音频塔的 mmproj**（之前能跑通的那版），保持 GGUF 格式。
2. 或确认是否有**专门的 noaudio checkpoint**：
   - 注意你发的 `asd-gemma4-code9-qlora-loftq-w4-noaudio.litertlm` 是 **LiteRT-LM 格式**，与当前 App 的 **GGUF / llama.cpp** 运行时**不兼容**。
   - 若要纯视觉路线，需要对应的 **noaudio GGUF 导出**（model + mmproj），而不是 litertlm。
3. 提供能复现"正常区分内容"的最小样例（视频/帧 + 期望码），便于对齐。

---

## iOS 客户端这边的状态（已就绪，无需等模型）

- UI 全流程已接好：splash → 加载 → 首页 → 选/拍视频 → 分析动画 → 报告结论（模板化）→ 本地追问对话。
- 已加**纯视觉兜底**：`mtmd_support_audio` 为 false 时跳过音频、不再硬失败；
  等带音频的 GGUF mmproj 到位后，`supportsAudio` 会自动转 true、走回音频链路，**不需再改代码**。
- 报告结论文案 = app 端按 9 位码模板拼接（`AsdBehaviorReport.conclusionText`），确定性、不走模型 NL；
  底部追问对话 = 真模型自然语言（`ScreeningService.sendChatMessage`）。

> 因此结论"每次一样"的根因是**模型恒定输出同一码**，模板层本身正确。
