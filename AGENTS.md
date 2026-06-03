# AGENTS.md

This repository fine-tunes a local Gemma 4 E4B instruction model for ASD-DS multimodal behavior-label prediction.

## Non-Negotiable Constraints

- Use only the project virtual environment for Python:

```bash
./.venv/bin/python
```

- If adding Python dependencies, use:

```bash
uv add <package>
```

- Do not modify raw dataset files under `data/raw/ASD-DS`.
- Do not commit or expose `.env`, W&B credentials, model weights, cache files, checkpoints, or generated outputs.
- Keep generated artifacts under `outputs/`; this path is gitignored.
- This project is screening support for observable behavior labels, not an ASD diagnostic system. Do not introduce wording that claims diagnosis.
- Preserve the train/validation/test boundary. Use validation during training; use test only for final reporting.

## Important Local Paths

- Base model: `/home/huzi/Downloads/gemma-4-E4B-it`
- Raw dataset: `data/raw/ASD-DS`
- Main inference smoke script: `main.py`
- Dataset adapter: `asd_ds_dataset.py`
- Training CLI: `run_train.py`
- Prompt files: `prompts/en/*.md`, `prompts/zh/*.md`
- Chinese prompt training script: `scripts/train_zh_v2.sh`; use `SKIP_CACHE=1 ./scripts/train_zh_v2.sh` when the matching cache already exists.
- Fine-tuning plan: `docs/ft_plan.md`
- iOS deployment plan: `docs/deploy2ios.md`
- Language-agnostic plan: `docs/unfinished_lang_agnostic.md`

## Dataset Facts

`asd_ds_dataset.py` exposes a read-only Hugging Face `DatasetDict` with splits:

- `train`: 553 rows
- `validation`: 193 rows
- `test`: 182 rows

Each row includes:

- `video_path`
- `audio_path`
- `label_vector`
- `labels`
- `target_json`

Canonical labels are `B01` through `B10`:

- `B01`: Absence or Avoidance of Eye Contact
- `B02`: Aggressive Behavior
- `B03`: Hyper- or Hyporeactivity to Sensory Input
- `B04`: Non-Responsiveness to Verbal Interaction
- `B05`: Non-Typical Language
- `B06`: Object Lining-Up
- `B07`: Self-Hitting or Self-Injurious Behavior
- `B08`: Self-Spinning or Spinning Objects
- `B09`: Upper Limb Stereotypies
- `B10`: Background

The supervised output is strict JSON:

```json
{"schema_version":"1.0","features":{"B01":false,"B02":false,"B03":false,"B04":false,"B05":false,"B06":false,"B07":false,"B08":false,"B09":true,"B10":false},"overall":"behavior_features_observed"}
```

## Training Architecture

`run_train.py` provides a `click` command group:

- `smoke-test`: preprocess one multimodal sample and print tensor shapes.
- `build-cache`: precompute Gemma processor outputs so training avoids per-step ffmpeg/processor work.
- `train`: BF16 LoRA fine-tuning with validation loss, generated validation metrics, final validation metrics, and final test metrics.

Prompt language is selected with `--prompt-lang en` or `--prompt-lang zh`. Prompt text is loaded from external Markdown files:

- `prompts/en/system.md`, `prompts/en/user.md`
- `prompts/zh/system.md`, `prompts/zh/user.md`

The LoRA defaults are:

- `r=32`
- `lora_alpha=64`
- `lora_dropout=0.05`
- target modules: language model projections only
- BF16 base model
- gradient checkpointing enabled

Important audio-export note: the LoRA adapter does not modify the Gemma 4
audio encoder or audio adapter. The target-module regex is limited to
`language_model` projections:

```text
.*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$
```

Therefore audio encoder weights remain base Gemma 4. If building an
audio-capable LiteRT-LM package, grafting official base Gemma 4 audio sections
into the fine-tuned package is technically plausible, but the resulting package
must still be evaluated before trusting behavior-label metrics.

Current collator supports batch size 1 only. Keep `per-device-train-batch-size=1` and scale effective batch size with `gradient-accumulation-steps`.

## Cache Workflow

For serious runs, build cache first:

```bash
./.venv/bin/python run_train.py build-cache \
  --cache-dir outputs/asd_ds_processor_cache \
  --prompt-lang en \
  --workers 8 \
  --frame-fps 1.0 \
  --max-frames 16 \
  --max-audio-seconds 30 \
  --image-width 512 \
  --cache-kind supervised \
  --cache-kind prompt
```

Then train with:

```bash
--cache-dir outputs/asd_ds_processor_cache \
--cache-mode require
```

`require` is preferred for real training because it fails on missing cache instead of silently falling back to slow media preprocessing.

Use `--workers 8` for faster cache rebuilds on this workstation. Lower it if CPU, RAM, or disk I/O becomes saturated.

Cache keys include model path, media parameters, `--prompt-lang`, and prompt file hashes. If `--max-frames`, `--max-audio-seconds`, `--image-width`, `--frame-fps`, model path, prompt language, or prompt file contents change, rebuild cache.

The Chinese training script defaults to physical GPUs `2,3`, maps them to logical CUDA devices `0,1`, and supports `SKIP_CACHE=1` to reuse an existing cache.

## Metrics and Outputs

Adapter weights are saved to:

- `OUTPUT_DIR/checkpoint-*`
- `OUTPUT_DIR/adapter_model.safetensors`
- `OUTPUT_DIR/adapter_config.json`

Generated metrics are saved under:

```text
OUTPUT_DIR/generated_metrics/
```

Expected files:

- `*_metrics.json`
- `*_predictions.jsonl`
- `*_f1.png`

W&B logs loss, generated micro/macro F1, exact match, parse rate, per-label precision/recall/F1, and F1 figures when W&B is enabled.

## Verification Commands

Run syntax checks:

```bash
./.venv/bin/python -m py_compile run_train.py asd_ds_dataset.py main.py
```

Run one-sample preprocessing smoke:

```bash
./.venv/bin/python run_train.py smoke-test \
  --split train \
  --index 0 \
  --prompt-lang en \
  --max-frames 4 \
  --max-audio-seconds 4 \
  --image-width 256
```

Debug one-step training without W&B:

```bash
./.venv/bin/python run_train.py train \
  --cuda-devices 1,2,3 \
  --output-dir outputs/debug-train \
  --run-name debug-train \
  --prompt-lang en \
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
  --save-steps 1
```

## Editing Guidance

- Keep changes narrow and aligned with existing `click` CLI patterns.
- Keep dataset handling read-only.
- Keep model loading offline with `local_files_only=True`.
- Avoid using the test split during iterative tuning.
- If changing training parameters that affect preprocessing, update cache docs and command examples.
- If adding parent-facing explanation behavior, keep it grounded in structured labels and human-written definitions. Do not train unsupported free-form clip rationales from this dataset alone.
