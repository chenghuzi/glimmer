# ASD LiteRT-LM Swift CLI

这个 CLI 用于在 macOS 上加载当前 no-audio `.litertlm` 模型，并对单个视频执行行为标签推理。

## 用法

```bash
cd swift/asd-litert-cli
./run.sh /path/to/video.mp4
```

也可以直接使用 SwiftPM：

```bash
cd swift/asd-litert-cli
swift run asd-litert-cli /path/to/video.mp4
```

如果 SwiftPM 因官方 macOS binary artifact 命名打印诊断，`run.sh` 会在构建完成后直接执行生成的二进制，避免污染 CLI 输出。

默认模型路径：

```text
outputs/gemma4-asd-lora-r32-code9-zh-examples-noaudio-ep5-qlora-loftq-v1-litert-wi8-noaudio/asd-gemma4-code9-qlora-loftq-w8-noaudio.litertlm
```

覆盖模型路径：

```bash
swift run asd-litert-cli \
  --model-path /path/to/model.litertlm \
  /path/to/video.mp4
```

CLI 会读取仓库内现有的 `prompts/zh/system.md` 和 `prompts/zh/user.md`，不会在 Swift 代码里改写 prompt。
