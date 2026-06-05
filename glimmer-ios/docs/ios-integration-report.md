# asd-gemma4.litertlm iOS 端接入测试报告

> 结论先行：**iOS 接入已严格按官方接入文档复现，模型能加载、能编码、能输出严格 JSON；但输出的字段词表不是文档约定的 B01–B10，疑似交付的 Q4 包不是训练好的 checkpoint（或导出时 adapter 未合入）。需模型侧核对。**

---

## 1. 测试环境

| 项 | 值 |
|---|---|
| 模型包 | `asd-gemma4.litertlm`（4.0 GB，Q4） |
| 运行时 | Google LiteRT-LM（Swift，vendored xcframework） |
| 设备 | iPhone 17 Pro 模拟器 / CPU(XNNPACK) backend |
| 测试视频 | 单段儿童行为 clip，时长 24.9s，竖屏 |
| 解码 | 确定性：temperature=0.0 / topK=1 / topP=1.0 |

## 2. 模型包实测结构（从加载日志）

```
section 0  LlmMetadataProto
section 1  HF_Tokenizer_Zlib
section 2  TFLiteModel  tf_lite_embedder
section 3  TFLiteModel  tf_lite_vision_encoder
section 4  TFLiteModel  tf_lite_vision_adapter
section 5  TFLiteModel  tf_lite_per_layer_embedder
section 6  TFLiteModel  tf_lite_prefill_decode
```

> ⚠️ **没有 audio encoder**。日志显式报：
> `NOT_FOUND: TF_LITE_AUDIO_ENCODER_HW not found in the model.`
> 因此本包**无法接收音频**。接入文档第 1/4 节假设输入顺序是 `frames → audio → instruction`，但该 Q4 包没有音频编码器，音频通道已按文档第 7 节"必须实测，不要默认音频可用"的提示**关闭**。

## 3. 实际输入（已严格对齐文档）

| 文档要求 | 本次实现 | 对齐 |
|---|---|---|
| 抽帧 `frame_count = max(1, min(16, ceil(秒)))` | `ceil(24.9)=25 → min(16,25)=` **16 帧** | ✅ |
| 覆盖整段 clip，不只取开头 | 时间点 `dur*i/(n-1)`，均匀覆盖 0→24.9s | ✅ |
| 每帧宽 512、保持比例、不裁剪不拉伸、RGB | AVFoundation 抽帧 → 512×910 JPEG | ✅ |
| 多帧分开传（非拼图） | 16 个 `Content.imageFile` | ✅ |
| 顺序 frames →（audio）→ instruction | 16 帧 → text instruction（无音频） | ✅ |
| system prompt 用训练原文 | 见下，逐字一致 | ✅ |
| user instruction 用训练原文 | 见下，逐字一致 | ✅ |
| 确定性解码 | topK=1/topP=1/temp=0 | ✅ |

**system message（逐字）**
```
You are a behavioral screening assistant. Inspect the provided video and audio. Return only the structured behavior label JSON with canonical feature IDs B01 through B10. This is screening support, not a medical diagnosis.
```

**user instruction（逐字）**
```
Return the behavior label report as strict JSON. Do not add explanation.
```

**模型预处理日志（确认 16 帧都进了 vision encoder）**
```
Resize image from 512x910 to 384x720 → 1080 patches (max_num_patches: 1260)   ×16
RunPrefillAsync status: OK
RunDecodeAsync
```
> Prefill 全部 OK，**无 token 预算溢出**，16 帧全部参与推理。

## 4. 期望输出（文档第 6 节 schema）

```json
{
  "schema_version": "1.0",
  "features": { "B01": false, "B02": false, "B03": false, "B04": false,
                "B05": false, "B06": false, "B07": false, "B08": false,
                "B09": true,  "B10": false },
  "overall": "behavior_features_observed"
}
```
校验项：顶层 object；`schema_version=="1.0"`；`features` 恰好含 B01–B10 且均为 bool；`overall` 为字符串。

## 5. 实际输出（模型原始返回）

```json
{
  "schema": "strict",
  "features": {
    "bang_scribble_features": false,
    "background": false,
    "age_group_appropriate": true,
    "age_appropriate": true,
    "age_features_observed": false
  }
}
```

## 6. 问题对比

| 维度 | 期望（文档） | 实际（模型输出） | 是否符合 |
|---|---|---|---|
| 版本字段 | `"schema_version": "1.0"` | `"schema": "strict"` | ❌ 键名与值都不对 |
| 特征键 | `B01` … `B10`（固定 10 项） | `bang_scribble_features` / `age_group_appropriate` / `age_appropriate` / `age_features_observed` / `background` | ❌ 凭空生成的词表 |
| 特征数量 | 10 | 5 | ❌ |
| 值类型 | bool | bool | ✅ |
| 顶层 `overall` | 必须有，字符串 | 缺失 | ❌ |
| 是否合法 JSON | 是 | 是 | ✅ |

## 7. 诊断

- 模型**已经学会"输出 `features: {key: bool}` 形态的严格 JSON"**（说明 prompt、输入顺序、解码参数都正确生效，接入侧无误）。
- 但模型**没有 B01–B10 这套规范标签词表**，而是凭语义即兴编造标签（`age_group_appropriate` 之类是在做"年龄/场景判断"，完全跑偏目标任务）。
- 输出字段词表整套缺失，**不属于 Q4 量化的"细微差异"**，更像：
  1. 交付的 Q4 包不是训练收敛后的那个 checkpoint；或
  2. 导出 `.litertlm` 时 **LoRA adapter 没有合并**（用的是接近基座的权重）；或
  3. 该 checkpoint 训练用的标签 schema 与文档第 6 节不一致。

## 8. 已排除（接入侧已验证正确）

- ✅ 不是"传了整段 mp4 而非抽帧" —— 实传 16 张 image。
- ✅ 不是"只取开头若干帧" —— 均匀覆盖整段。
- ✅ 不是"帧数/尺寸不符" —— 16 帧、宽 512、保持比例。
- ✅ 不是"prompt 被改写" —— system/user 均逐字使用文档原文。
- ✅ 不是"解码随机" —— greedy 确定性。
- ✅ 不是"token 预算不足" —— Prefill OK。
- ✅ 不是"把无效 JSON 当有效" —— 端上做了严格 schema 校验，本次正确判定为不合法并拦截。

## 9. 需模型侧（虎子）核对

1. 交付的 `asd-gemma4.litertlm` 是否为**训练收敛后的 checkpoint**？
2. Q4 导出时 **LoRA adapter 是否已合并**进基座？
3. 该 checkpoint 真实训练的**输出 schema/标签集**是否就是文档第 6 节的 B01–B10（还是另一套）？
4. 能否提供一条**已知正确的 Python 侧 (输入→输出) 样例**做端到端对比？
5. 该包**无 audio encoder**，是否符合预期？（文档第 1/4 节的音频通道在本包不可用）

## 10. 备注：iOS 端当前状态

- 接入代码已完成且正确：抽帧、顺序、prompt、确定性解码、严格 JSON 解析 + B01–B10 中文报告渲染。
- 一旦模型侧给出对齐 B01–B10 的包，端上**无需改动**即可正常出结构化报告。

## 11. 端侧尝试：提示词锚定（已生效，可解析）

针对第 7 节"模型只学会 JSON 形态、未锁定 B01–B10 词表"，在**不改模型**的前提下做端侧尝试：把 **10 个标签定义 + 精确 schema 模板**显式写进 system prompt（user 指令同时点名 keys B01..B10/overall），其余（16 帧、顺序、确定性解码）不变。

**结果：输出结构完全合规，通过端上严格校验。**

```json
{"schema_version":"1.0",
 "features":{"B01":false,"B02":false,"B03":false,"B04":false,"B05":false,
             "B06":false,"B07":false,"B08":false,"B09":false,"B10":false},
 "overall":"behavioral_features_observed"}
```

| 维度 | 锚定前 | 锚定后 |
|---|---|---|
| `schema_version` | `"schema":"strict"` ❌ | `"1.0"` ✅ |
| 特征键 | 瞎编 5 个 ❌ | B01–B10 全 10 个 ✅ |
| `overall` | 缺失 ❌ | 有 ✅ |
| 端上能否出报告 | 解析失败 ❌ | 正常渲染 ✅ |

**结论与边界：**

- ✅ 解决了"JSON 无法解析"——结构、键、类型全部对齐，端上能稳定出报告，且全离线。
- ⚠️ 这是**提示词工程兜底**，强约束的是**结构**；features 的**真假值**仍来自模型判断。
  - 若交付包是训练收敛的 checkpoint → 真假值反映训练结果；
  - 若不是 → 真假值是 Gemma4 通用视觉的零样本推理（结构有效，但判别力未经验证）。
- 因此第 9 节对模型侧的核对仍然需要：**用一条已知正确的"输入→输出"样本，验证锚定后真假值是否与 Python 侧一致**。这是区分"checkpoint 没问题，只是格式没锚定" vs "checkpoint 本身没训好"的关键。

> LiteRT-LM 的 `enableConversationConstrainedDecoding` 仅服务于 function-calling，无法直接传任意 JSON schema；如需对结构做**硬保证**（而非提示词软约束），可定义一个参数为 B01–B10 的 tool 走约束解码，作为后续可选项。
