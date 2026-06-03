# Gemma 4 ASD-DS Fine-Tuning

This repo fine-tunes a local Gemma 4 E4B instruction model on ASD-DS video/audio clips to predict structured behavior-feature labels.

The model output is a canonical JSON label report with `B01` through `B10`. This system is behavioral screening support only. It is not a medical diagnosis tool.

## Repository Layout

```text
.
|-- asd_ds_dataset.py        # Read-only Hugging Face DatasetDict adapter for ASD-DS
|-- main.py                  # Simple local Gemma text inference smoke script
|-- run_train.py             # Training CLI: smoke-test, build-cache, train
|-- data/raw/ASD-DS          # Raw ASD-DS dataset, not modified by code
|-- docs/
|   |-- ft_plan.md
|   |-- deploy2ios.md
|   `-- unfinished_lang_agnostic.md
`-- outputs/                 # Checkpoints, metrics, processor cache, ignored by git
```

## Requirements

Use the project virtual environment for every Python command:

```bash
./.venv/bin/python
```

Python dependencies are managed with `uv` and declared in `pyproject.toml`.

Core dependencies include:

- PyTorch CUDA build
- Transformers
- Datasets
- PEFT
- W&B
- Click
- NumPy

External tools:

- `ffmpeg`
- `ffprobe`

The code also checks the Homebrew path `/home/linuxbrew/.linuxbrew/bin` when tools are not on `PATH`.

## Local Assets

Expected base model:

```text
/home/huzi/Downloads/gemma-4-E4B-it
```

Expected dataset:

```text
data/raw/ASD-DS
```

The raw dataset is read-only for this project.

## Dataset Schema

`asd_ds_dataset.py` loads:

- `train`: 553 samples
- `validation`: 193 samples
- `test`: 182 samples

Each sample includes media paths and structured labels:

- `video_path`
- `audio_path`
- `label_vector`
- `labels`
- `target_json`

Canonical label IDs:

| ID | Behavior Feature |
| --- | --- |
| B01 | Absence or Avoidance of Eye Contact |
| B02 | Aggressive Behavior |
| B03 | Hyper- or Hyporeactivity to Sensory Input |
| B04 | Non-Responsiveness to Verbal Interaction |
| B05 | Non-Typical Language |
| B06 | Object Lining-Up |
| B07 | Self-Hitting or Self-Injurious Behavior |
| B08 | Self-Spinning or Spinning Objects |
| B09 | Upper Limb Stereotypies |
| B10 | Background |

Target JSON shape:

```json
{
  "schema_version": "1.0",
  "features": {
    "B01": false,
    "B02": false,
    "B03": false,
    "B04": false,
    "B05": false,
    "B06": false,
    "B07": false,
    "B08": false,
    "B09": true,
    "B10": false
  },
  "overall": "behavior_features_observed"
}
```

## Quick Checks

Compile the Python files:

```bash
./.venv/bin/python -m py_compile run_train.py asd_ds_dataset.py main.py
```

Run a single-sample preprocessing smoke test:

```bash
./.venv/bin/python run_train.py smoke-test \
  --split train \
  --index 0 \
  --max-frames 4 \
  --max-audio-seconds 4 \
  --image-width 256
```

Run a text-only Gemma inference smoke:

```bash
./.venv/bin/python main.py \
  --prompt "Say hello in five words." \
  --max-new-tokens 16 \
  --temperature 0
```

## Cache First

Training directly from media is slow because each step must decode video/audio and run `Gemma4Processor`. Build the processor cache before serious training:

```bash
./.venv/bin/python run_train.py build-cache \
  --cache-dir outputs/asd_ds_processor_cache \
  --frame-fps 1.0 \
  --max-frames 16 \
  --max-audio-seconds 30 \
  --image-width 512 \
  --cache-kind supervised \
  --cache-kind prompt
```

This writes processor-ready tensors under `outputs/asd_ds_processor_cache/`.

Cache contains:

- supervised training/eval batches with labels
- prompt-only batches for generated validation/test F1

If any preprocessing parameter changes, rebuild the cache:

- `--frame-fps`
- `--max-frames`
- `--max-audio-seconds`
- `--image-width`
- `--system-prompt`
- `--model-dir`

## Full Training Command

Use physical CUDA GPUs `1,2,3`:

```bash
./.venv/bin/python run_train.py train \
  --cuda-devices 1,2,3 \
  --model-dir /home/huzi/Downloads/gemma-4-E4B-it \
  --data-root data/raw/ASD-DS \
  --output-dir outputs/gemma4-asd-lora-r32-full-v1 \
  --cache-dir outputs/asd_ds_processor_cache \
  --cache-mode require \
  --run-name gemma4-asd-lora-r32-full-v1 \
  --wandb \
  --env-file .env \
  --wandb-project gemma4-asd-ft \
  --wandb-entity chenghuzi \
  --num-train-epochs 3 \
  --learning-rate 5e-5 \
  --warmup-ratio 0.03 \
  --weight-decay 0.0 \
  --per-device-train-batch-size 1 \
  --per-device-eval-batch-size 1 \
  --gradient-accumulation-steps 8 \
  --logging-steps 5 \
  --eval-steps 70 \
  --save-steps 70 \
  --save-total-limit 3 \
  --frame-fps 1.0 \
  --max-frames 16 \
  --max-audio-seconds 30 \
  --image-width 512 \
  --lora-r 32 \
  --lora-alpha 64 \
  --lora-dropout 0.05 \
  --target-modules language \
  --max-memory-per-gpu 22GiB \
  --prediction-max-new-tokens 256 \
  --generated-metrics \
  --bf16 \
  --gradient-checkpointing
```

Why `eval-steps 70`: the train split has 553 samples and the effective optimizer step count is roughly `553 / 8 = 69.1`, so this evaluates about once per epoch.

Use validation during training. Use test only at the final evaluation stage.

## Outputs

Training saves LoRA adapter weights, not a duplicate full base model:

```text
outputs/gemma4-asd-lora-r32-full-v1/
|-- adapter_config.json
|-- adapter_model.safetensors
|-- checkpoint-*/
`-- generated_metrics/
```

Generated metrics include:

```text
generated_metrics/
|-- *_metrics.json
|-- *_predictions.jsonl
`-- *_f1.png
```

W&B logs:

- training loss
- validation loss
- generated micro/macro F1
- exact match
- parse rate
- per-label precision, recall, and F1
- F1 plots

The W&B API key is expected in `.env` as:

```text
WANDB_API_KEY=...
```

## Debug Training

Small one-step run without W&B:

```bash
./.venv/bin/python run_train.py train \
  --cuda-devices 1,2,3 \
  --output-dir outputs/debug-train \
  --run-name debug-train \
  --no-wandb \
  --max-steps 1 \
  --max-train-samples 1 \
  --max-eval-samples 1 \
  --max-test-samples 1 \
  --max-frames 1 \
  --max-audio-seconds 1 \
  --image-width 256 \
  --gradient-accumulation-steps 1 \
  --eval-steps 1 \
  --save-steps 1 \
  --prediction-max-new-tokens 96
```

## Performance Notes

For speed:

- Build cache before training.
- Train with `--cache-mode require`.
- Keep generated metrics at epoch frequency, not every few steps.
- Try fewer frames if needed, for example `--max-frames 8`.
- Test `2 GPU vs 3 GPU` if model parallel communication becomes the bottleneck.

For memory:

- Keep batch size at 1.
- Use gradient accumulation for effective batch size.
- Keep gradient checkpointing enabled unless you have enough headroom and want to trade memory for speed.

## Safety and Explanation Strategy

The first fine-tuning round should produce structured labels only.

Parent-facing explanations should be generated from:

- validated structured labels
- human-written behavior definitions
- safety and limitation text
- optional confidence values

Do not ask this model to invent timestamped clip-specific rationales unless the dataset later includes timestamped evidence or a separately evaluated evidence method is added.

Relevant docs:

- `docs/ft_plan.md`
- `docs/unfinished_lang_agnostic.md`
- `docs/deploy2ios.md`
