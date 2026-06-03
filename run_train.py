from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import hashlib
from pathlib import Path
from typing import Any

import click
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from transformers.trainer_callback import TrainerCallback

from asd_ds_dataset import FEATURE_ID_TO_COLUMN, FEATURE_IDS, load_asd_ds


DEFAULT_DATA_ROOT = "data/raw/ASD-DS"
DEFAULT_MODEL_DIR = "/home/huzi/Downloads/gemma-4-E4B-it"
DEFAULT_SYSTEM_PROMPT = (
    "You are a behavioral screening assistant. Inspect the provided video and audio. "
    "Return only the structured behavior label JSON with canonical feature IDs B01 through B10. "
    "This is screening support, not a medical diagnosis."
)
USER_INSTRUCTION = "Return the behavior label report as strict JSON. Do not add explanation."
BREW_BIN = Path("/home/linuxbrew/.linuxbrew/bin")
DEFAULT_OUTPUT_DIR = "outputs/gemma4-asd-lora-r32"
DEFAULT_CACHE_DIR = "outputs/asd_ds_processor_cache"
DEFAULT_WANDB_PROJECT = "gemma4-asd-ft"
DEFAULT_RUN_NAME = "gemma4-asd-lora-r32"
CACHE_VERSION = "gemma4_asd_ds_processor_cache_v1"
CACHE_KINDS = ("supervised", "prompt")
LANGUAGE_LORA_REGEX = (
    r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$"
)


@click.group()
def cli() -> None:
    """Training utilities for Gemma 4 ASD-DS fine-tuning."""


@cli.command("smoke-test")
@click.option("--data-root", default=DEFAULT_DATA_ROOT, show_default=True, type=click.Path(path_type=Path))
@click.option("--model-dir", default=DEFAULT_MODEL_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option("--split", default="train", show_default=True, type=click.Choice(["train", "validation", "test"]))
@click.option("--index", "row_index", default=0, show_default=True, type=click.IntRange(min=0))
@click.option("--frame-fps", default=1.0, show_default=True, type=click.FloatRange(min=0.1))
@click.option("--max-frames", default=8, show_default=True, type=click.IntRange(min=1))
@click.option("--max-audio-seconds", default=30.0, show_default=True, type=click.FloatRange(min=0.1))
@click.option("--image-width", default=512, show_default=True, type=click.IntRange(min=64))
@click.option("--system-prompt", default=DEFAULT_SYSTEM_PROMPT, show_default=False)
def smoke_test(
    data_root: Path,
    model_dir: Path,
    split: str,
    row_index: int,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    system_prompt: str,
) -> None:
    """Load one sample, preprocess media, and build masked training labels."""
    from transformers import AutoProcessor
    from transformers.video_utils import VideoMetadata

    ffmpeg = find_tool("ffmpeg")
    click.echo("== Smoke test: Gemma 4 multimodal training sample ==")
    click.echo(f"data_root: {data_root}")
    click.echo(f"model_dir:  {model_dir}")
    click.echo(f"ffmpeg:     {ffmpeg}")

    dataset = load_asd_ds(data_root, splits=(split,))[split]
    if row_index >= len(dataset):
        raise click.ClickException(f"--index {row_index} is out of range for {split} with {len(dataset)} rows")

    row = dataset[row_index]
    print_sample_summary(row, split, row_index)

    frames = load_video_frames(
        ffmpeg=ffmpeg,
        video_path=Path(row["video_path"]),
        fps=frame_fps,
        max_frames=max_frames,
        image_width=image_width,
        duration_sec=float(row["duration_sec"]),
    )
    audio = load_audio_mono_16k(
        ffmpeg=ffmpeg,
        audio_path=Path(row["audio_path"]),
        max_seconds=min(float(row["duration_sec"]), max_audio_seconds),
    )
    click.echo("\n== Media preprocessing ==")
    click.echo(f"frames: {len(frames)}")
    click.echo(f"first_frame_size: {frames[0].size[0]}x{frames[0].size[1]}")
    click.echo(f"audio_samples: {audio.shape[0]}")
    click.echo(f"audio_seconds_at_16k: {audio.shape[0] / 16000:.3f}")
    click.echo(f"audio_min_max: {audio.min():.4f}, {audio.max():.4f}")

    processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
    prompt_text = build_chat_text(processor, row, system_prompt=system_prompt, include_answer=False)
    full_text = build_chat_text(processor, row, system_prompt=system_prompt, include_answer=True)
    metadata = VideoMetadata(
        total_num_frames=len(frames),
        fps=frame_fps,
        duration=len(frames) / frame_fps,
        frames_indices=list(range(len(frames))),
    )

    prompt_inputs = processor(
        text=[prompt_text],
        videos=[frames],
        audio=[audio],
        return_tensors="pt",
        return_mm_token_type_ids=True,
        videos_kwargs={"video_metadata": [metadata], "do_sample_frames": False},
        audio_kwargs={"sampling_rate": 16000},
    )
    full_inputs = processor(
        text=[full_text],
        videos=[frames],
        audio=[audio],
        return_tensors="pt",
        return_mm_token_type_ids=True,
        videos_kwargs={"video_metadata": [metadata], "do_sample_frames": False},
        audio_kwargs={"sampling_rate": 16000},
    )
    labels = build_masked_labels(full_inputs, prompt_len=prompt_inputs["input_ids"].shape[-1])

    click.echo("\n== Chat text ==")
    click.echo(f"prompt_text_chars: {len(prompt_text)}")
    click.echo(f"full_text_chars:   {len(full_text)}")
    click.echo("prompt_text_preview:")
    click.echo(indent_preview(prompt_text))
    click.echo("target_json:")
    click.echo(row["target_json"])

    click.echo("\n== Processor outputs ==")
    print_tensor_summary("prompt", prompt_inputs)
    print_tensor_summary("full", full_inputs)
    click.echo(f"prompt_token_len: {prompt_inputs['input_ids'].shape[-1]}")
    click.echo(f"full_token_len:   {full_inputs['input_ids'].shape[-1]}")
    click.echo(f"label_token_count: {(labels != -100).sum().item()}")

    decoded_label_text = processor.tokenizer.decode(
        full_inputs["input_ids"][0][labels[0] != -100],
        skip_special_tokens=False,
    )
    click.echo("\n== Decoded supervised label text ==")
    click.echo(decoded_label_text)

    assert_label_payload(row["target_json"])
    click.echo("\nSMOKE TEST PASSED")


@cli.command("build-cache")
@click.option("--data-root", default=DEFAULT_DATA_ROOT, show_default=True, type=click.Path(path_type=Path))
@click.option("--model-dir", default=DEFAULT_MODEL_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option("--cache-dir", default=DEFAULT_CACHE_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option(
    "--split",
    "splits",
    multiple=True,
    default=("train", "validation", "test"),
    show_default=True,
    type=click.Choice(["train", "validation", "test"]),
)
@click.option(
    "--cache-kind",
    "cache_kinds",
    multiple=True,
    default=CACHE_KINDS,
    show_default=True,
    type=click.Choice(CACHE_KINDS),
)
@click.option("--max-samples", default=None, type=click.IntRange(min=1))
@click.option("--frame-fps", default=1.0, show_default=True, type=click.FloatRange(min=0.1))
@click.option("--max-frames", default=16, show_default=True, type=click.IntRange(min=1))
@click.option("--max-audio-seconds", default=30.0, show_default=True, type=click.FloatRange(min=0.1))
@click.option("--image-width", default=512, show_default=True, type=click.IntRange(min=64))
@click.option("--overwrite/--no-overwrite", default=False, show_default=True)
@click.option("--system-prompt", default=DEFAULT_SYSTEM_PROMPT, show_default=False)
def build_cache(
    data_root: Path,
    model_dir: Path,
    cache_dir: Path,
    splits: tuple[str, ...],
    cache_kinds: tuple[str, ...],
    max_samples: int | None,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    overwrite: bool,
    system_prompt: str,
) -> None:
    """Precompute processor batches so training does not run ffmpeg/processor per step."""
    from transformers import AutoProcessor

    ffmpeg = find_tool("ffmpeg")
    processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
    cache_store = ProcessorCache(
        cache_dir=cache_dir,
        config=build_cache_config(
            model_dir=model_dir,
            frame_fps=frame_fps,
            max_frames=max_frames,
            max_audio_seconds=max_audio_seconds,
            image_width=image_width,
            system_prompt=system_prompt,
        ),
        mode="read-write",
    )
    cache_store.write_config()

    click.echo("== Building processor cache ==")
    click.echo(f"data_root: {data_root}")
    click.echo(f"model_dir: {model_dir}")
    click.echo(f"cache_root: {cache_store.root}")
    click.echo(f"ffmpeg: {ffmpeg}")
    click.echo(f"splits: {', '.join(splits)}")
    click.echo(f"kinds: {', '.join(cache_kinds)}")

    dataset = load_asd_ds(data_root, splits=splits)
    total_written = 0
    total_existing = 0
    for split in splits:
        split_dataset = dataset[split]
        if max_samples is not None:
            split_dataset = split_dataset.select(range(min(max_samples, len(split_dataset))))

        click.echo(f"== {split}: {len(split_dataset)} samples ==")
        for index, row in enumerate(split_dataset):
            if index and index % 25 == 0:
                click.echo(
                    f"[cache] {split}: {index}/{len(split_dataset)} "
                    f"written={total_written} existing={total_existing}"
                )

            for kind in cache_kinds:
                written = cache_store.build_or_refresh(
                    kind=kind,
                    row=row,
                    overwrite=overwrite,
                    builder=lambda kind=kind, row=row: build_cached_kind(
                        kind=kind,
                        processor=processor,
                        ffmpeg=ffmpeg,
                        row=row,
                        frame_fps=frame_fps,
                        max_frames=max_frames,
                        max_audio_seconds=max_audio_seconds,
                        image_width=image_width,
                        system_prompt=system_prompt,
                    ),
                )
                if written:
                    total_written += 1
                else:
                    total_existing += 1

    click.echo(
        "CACHE BUILD DONE "
        f"written={total_written} existing={total_existing} cache_root={cache_store.root}"
    )


@cli.command("train")
@click.option("--cuda-devices", default="1,2,3", show_default=True, help="Physical CUDA device IDs.")
@click.option("--data-root", default=DEFAULT_DATA_ROOT, show_default=True, type=click.Path(path_type=Path))
@click.option("--model-dir", default=DEFAULT_MODEL_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option("--output-dir", default=DEFAULT_OUTPUT_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option("--cache-dir", default=DEFAULT_CACHE_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option(
    "--cache-mode",
    default="read-write",
    show_default=True,
    type=click.Choice(["off", "read-write", "require"]),
    help="'require' fails on missing cache; 'read-write' builds missing entries lazily.",
)
@click.option("--run-name", default=DEFAULT_RUN_NAME, show_default=True)
@click.option("--wandb-project", default=DEFAULT_WANDB_PROJECT, show_default=True)
@click.option("--wandb-entity", default="chenghuzi")
@click.option("--env-file", default=".env", show_default=True, type=click.Path(path_type=Path))
@click.option("--wandb/--no-wandb", default=True, show_default=True)
@click.option("--num-train-epochs", default=1.0, show_default=True, type=click.FloatRange(min=0))
@click.option("--max-steps", default=-1, show_default=True, type=int)
@click.option("--max-train-samples", default=None, type=click.IntRange(min=1))
@click.option("--max-eval-samples", default=None, type=click.IntRange(min=1))
@click.option("--max-test-samples", default=None, type=click.IntRange(min=1))
@click.option("--learning-rate", default=1e-4, show_default=True, type=float)
@click.option("--warmup-ratio", default=0.03, show_default=True, type=click.FloatRange(min=0, max=1))
@click.option("--weight-decay", default=0.0, show_default=True, type=click.FloatRange(min=0))
@click.option("--per-device-train-batch-size", default=1, show_default=True, type=click.IntRange(min=1))
@click.option("--per-device-eval-batch-size", default=1, show_default=True, type=click.IntRange(min=1))
@click.option("--gradient-accumulation-steps", default=8, show_default=True, type=click.IntRange(min=1))
@click.option("--logging-steps", default=5, show_default=True, type=click.IntRange(min=1))
@click.option("--eval-steps", default=50, show_default=True, type=click.IntRange(min=1))
@click.option("--save-steps", default=50, show_default=True, type=click.IntRange(min=1))
@click.option("--save-total-limit", default=3, show_default=True, type=click.IntRange(min=1))
@click.option("--frame-fps", default=1.0, show_default=True, type=click.FloatRange(min=0.1))
@click.option("--max-frames", default=16, show_default=True, type=click.IntRange(min=1))
@click.option("--max-audio-seconds", default=30.0, show_default=True, type=click.FloatRange(min=0.1))
@click.option("--image-width", default=512, show_default=True, type=click.IntRange(min=64))
@click.option("--lora-r", default=32, show_default=True, type=click.IntRange(min=1))
@click.option("--lora-alpha", default=64, show_default=True, type=click.IntRange(min=1))
@click.option("--lora-dropout", default=0.05, show_default=True, type=click.FloatRange(min=0, max=1))
@click.option(
    "--target-modules",
    default="language",
    show_default=True,
    help="'language', 'all-linear', or comma-separated PEFT target module names/regex.",
)
@click.option("--max-memory-per-gpu", default="22GiB", show_default=True)
@click.option("--prediction-max-new-tokens", default=256, show_default=True, type=click.IntRange(min=16))
@click.option("--generated-metrics/--no-generated-metrics", default=True, show_default=True)
@click.option("--bf16/--no-bf16", default=True, show_default=True)
@click.option("--gradient-checkpointing/--no-gradient-checkpointing", default=True, show_default=True)
@click.option("--resume-from-checkpoint", default=None, type=click.Path(path_type=Path))
@click.option("--system-prompt", default=DEFAULT_SYSTEM_PROMPT, show_default=False)
def train(
    cuda_devices: str,
    data_root: Path,
    model_dir: Path,
    output_dir: Path,
    cache_dir: Path,
    cache_mode: str,
    run_name: str,
    wandb_project: str,
    wandb_entity: str | None,
    env_file: Path,
    wandb: bool,
    num_train_epochs: float,
    max_steps: int,
    max_train_samples: int | None,
    max_eval_samples: int | None,
    max_test_samples: int | None,
    learning_rate: float,
    warmup_ratio: float,
    weight_decay: float,
    per_device_train_batch_size: int,
    per_device_eval_batch_size: int,
    gradient_accumulation_steps: int,
    logging_steps: int,
    eval_steps: int,
    save_steps: int,
    save_total_limit: int,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    lora_r: int,
    lora_alpha: int,
    lora_dropout: float,
    target_modules: str,
    max_memory_per_gpu: str,
    prediction_max_new_tokens: int,
    generated_metrics: bool,
    bf16: bool,
    gradient_checkpointing: bool,
    resume_from_checkpoint: Path | None,
    system_prompt: str,
) -> None:
    """Fine-tune Gemma 4 E4B with BF16 LoRA on ASD-DS."""
    if per_device_train_batch_size != 1 or per_device_eval_batch_size != 1:
        raise click.ClickException("This first training collator supports batch size 1 only.")

    configure_runtime(cuda_devices)

    import torch
    import wandb as wandb_lib
    from peft import LoraConfig, get_peft_model
    from transformers import AutoProcessor, Gemma4ForConditionalGeneration, Trainer, TrainingArguments

    ffmpeg = find_tool("ffmpeg")
    load_env_file(env_file)
    setup_wandb(
        enabled=wandb,
        wandb_lib=wandb_lib,
        project=wandb_project,
        entity=wandb_entity,
        run_name=run_name,
    )

    click.echo("== Training setup ==")
    click.echo(f"CUDA_VISIBLE_DEVICES: {os.environ['CUDA_VISIBLE_DEVICES']}")
    click.echo(f"visible_cuda_count: {torch.cuda.device_count()}")
    for idx in range(torch.cuda.device_count()):
        click.echo(f"cuda:{idx}: {torch.cuda.get_device_name(idx)}")
    click.echo(f"data_root: {data_root}")
    click.echo(f"model_dir: {model_dir}")
    click.echo(f"output_dir: {output_dir}")
    click.echo(f"cache_dir: {cache_dir}")
    click.echo(f"cache_mode: {cache_mode}")
    click.echo(f"ffmpeg: {ffmpeg}")

    dataset = load_asd_ds(data_root)
    train_dataset = dataset["train"]
    eval_dataset = dataset["validation"]
    test_dataset = dataset["test"]
    if max_train_samples is not None:
        train_dataset = train_dataset.select(range(min(max_train_samples, len(train_dataset))))
    if max_eval_samples is not None:
        eval_dataset = eval_dataset.select(range(min(max_eval_samples, len(eval_dataset))))
    if max_test_samples is not None:
        test_dataset = test_dataset.select(range(min(max_test_samples, len(test_dataset))))

    processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
    cache_store = None
    if cache_mode != "off":
        cache_store = ProcessorCache(
            cache_dir=cache_dir,
            config=build_cache_config(
                model_dir=model_dir,
                frame_fps=frame_fps,
                max_frames=max_frames,
                max_audio_seconds=max_audio_seconds,
                image_width=image_width,
                system_prompt=system_prompt,
            ),
            mode=cache_mode,
        )
        cache_store.write_config()
        click.echo(f"processor_cache_root: {cache_store.root}")

    collator = Gemma4ASDDSCollator(
        processor=processor,
        ffmpeg=ffmpeg,
        frame_fps=frame_fps,
        max_frames=max_frames,
        max_audio_seconds=max_audio_seconds,
        image_width=image_width,
        system_prompt=system_prompt,
        cache_store=cache_store,
    )

    max_memory = {idx: max_memory_per_gpu for idx in range(torch.cuda.device_count())}
    model = Gemma4ForConditionalGeneration.from_pretrained(
        model_dir,
        dtype=torch.bfloat16 if bf16 else torch.float16,
        device_map="auto",
        max_memory=max_memory,
        local_files_only=True,
    )
    model.config.use_cache = False

    if gradient_checkpointing:
        enable_gradient_checkpointing(model)

    lora_config = LoraConfig(
        r=lora_r,
        lora_alpha=lora_alpha,
        lora_dropout=lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=parse_target_modules(target_modules),
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    training_args = TrainingArguments(
        output_dir=str(output_dir),
        run_name=run_name,
        report_to=["wandb"] if wandb else [],
        num_train_epochs=num_train_epochs,
        max_steps=max_steps,
        per_device_train_batch_size=per_device_train_batch_size,
        per_device_eval_batch_size=per_device_eval_batch_size,
        gradient_accumulation_steps=gradient_accumulation_steps,
        learning_rate=learning_rate,
        warmup_ratio=warmup_ratio,
        weight_decay=weight_decay,
        bf16=bf16,
        logging_steps=logging_steps,
        eval_strategy="steps",
        eval_steps=eval_steps,
        save_strategy="steps",
        save_steps=save_steps,
        save_total_limit=save_total_limit,
        remove_unused_columns=False,
        dataloader_num_workers=0,
        dataloader_pin_memory=False,
        gradient_checkpointing=gradient_checkpointing,
        optim="adamw_torch",
    )

    metrics_evaluator = None
    callbacks = []
    if generated_metrics:
        metrics_evaluator = GeneratedMetricsEvaluator(
            processor=processor,
            ffmpeg=ffmpeg,
            frame_fps=frame_fps,
            max_frames=max_frames,
            max_audio_seconds=max_audio_seconds,
            image_width=image_width,
            system_prompt=system_prompt,
            output_dir=output_dir / "generated_metrics",
            max_new_tokens=prediction_max_new_tokens,
            wandb_enabled=wandb,
            cache_store=cache_store,
        )
        callbacks.append(
            GeneratedMetricsCallback(
                evaluator=metrics_evaluator,
                eval_dataset=eval_dataset,
            )
        )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        data_collator=collator,
        processing_class=processor,
        callbacks=callbacks,
    )

    click.echo("== Starting training ==")
    trainer.train(resume_from_checkpoint=str(resume_from_checkpoint) if resume_from_checkpoint else None)
    click.echo("== Saving adapter and processor ==")
    trainer.save_model(str(output_dir))
    processor.save_pretrained(output_dir)
    click.echo(f"Saved training artifacts to {output_dir}")

    if metrics_evaluator is not None:
        click.echo("== Running final generated validation metrics ==")
        metrics_evaluator.evaluate(
            model=trainer.model,
            dataset=eval_dataset,
            split_name="validation_final",
            step=int(trainer.state.global_step),
            epoch=trainer.state.epoch,
        )
        click.echo("== Running final generated test metrics ==")
        metrics_evaluator.evaluate(
            model=trainer.model,
            dataset=test_dataset,
            split_name="test_final",
            step=int(trainer.state.global_step),
            epoch=trainer.state.epoch,
        )


def find_tool(name: str) -> str:
    path = shutil.which(name)
    if path:
        return path

    brew_path = BREW_BIN / name
    if brew_path.is_file():
        return str(brew_path)

    raise click.ClickException(f"Could not find {name}. Install it or add it to PATH.")


class Gemma4ASDDSCollator:
    """Build one Gemma 4 multimodal SFT batch from one ASD-DS row."""

    def __init__(
        self,
        *,
        processor: Any,
        ffmpeg: str,
        frame_fps: float,
        max_frames: int,
        max_audio_seconds: float,
        image_width: int,
        system_prompt: str,
        cache_store: "ProcessorCache | None" = None,
    ) -> None:
        self.processor = processor
        self.ffmpeg = ffmpeg
        self.frame_fps = frame_fps
        self.max_frames = max_frames
        self.max_audio_seconds = max_audio_seconds
        self.image_width = image_width
        self.system_prompt = system_prompt
        self.cache_store = cache_store

    def __call__(self, examples: list[dict]) -> dict:
        if len(examples) != 1:
            raise ValueError("Gemma4ASDDSCollator currently supports batch size 1 only.")

        row = examples[0]
        builder = lambda: build_supervised_inputs(
            processor=self.processor,
            ffmpeg=self.ffmpeg,
            row=row,
            frame_fps=self.frame_fps,
            max_frames=self.max_frames,
            max_audio_seconds=self.max_audio_seconds,
            image_width=self.image_width,
            system_prompt=self.system_prompt,
        )
        if self.cache_store is None:
            return builder()
        return self.cache_store.load_or_build(kind="supervised", row=row, builder=builder)


class GeneratedMetricsCallback(TrainerCallback):
    """Run generation-based validation metrics after Trainer loss evaluation."""

    def __init__(self, *, evaluator: "GeneratedMetricsEvaluator", eval_dataset: Any) -> None:
        self.evaluator = evaluator
        self.eval_dataset = eval_dataset
        self._seen_steps: set[int] = set()

    def on_evaluate(self, args: Any, state: Any, control: Any, **kwargs: Any) -> Any:
        if not state.is_world_process_zero:
            return control

        step = int(state.global_step)
        if step in self._seen_steps:
            return control
        self._seen_steps.add(step)

        model = kwargs.get("model")
        if model is None:
            return control

        self.evaluator.evaluate(
            model=model,
            dataset=self.eval_dataset,
            split_name="validation",
            step=step,
            epoch=state.epoch,
        )
        return control


class GeneratedMetricsEvaluator:
    """Generate JSON labels and save per-label F1 metrics, plots, and predictions."""

    def __init__(
        self,
        *,
        processor: Any,
        ffmpeg: str,
        frame_fps: float,
        max_frames: int,
        max_audio_seconds: float,
        image_width: int,
        system_prompt: str,
        output_dir: Path,
        max_new_tokens: int,
        wandb_enabled: bool,
        cache_store: "ProcessorCache | None" = None,
    ) -> None:
        self.processor = processor
        self.ffmpeg = ffmpeg
        self.frame_fps = frame_fps
        self.max_frames = max_frames
        self.max_audio_seconds = max_audio_seconds
        self.image_width = image_width
        self.system_prompt = system_prompt
        self.output_dir = output_dir
        self.max_new_tokens = max_new_tokens
        self.wandb_enabled = wandb_enabled
        self.cache_store = cache_store

    def evaluate(
        self,
        *,
        model: Any,
        dataset: Any,
        split_name: str,
        step: int,
        epoch: float | None,
    ) -> dict[str, Any]:
        import torch

        self.output_dir.mkdir(parents=True, exist_ok=True)
        safe_epoch = "none" if epoch is None else f"{epoch:.4f}".replace(".", "_")
        run_id = f"{split_name}_step_{step:06d}_epoch_{safe_epoch}"
        predictions_path = self.output_dir / f"{run_id}_predictions.jsonl"
        metrics_path = self.output_dir / f"{run_id}_metrics.json"
        figure_path = self.output_dir / f"{run_id}_f1.png"

        click.echo(f"[generated-metrics] {split_name}: {len(dataset)} samples at step {step}")
        was_training = model.training
        model.eval()
        device = infer_model_input_device(model)

        y_true: list[list[int]] = []
        y_pred: list[list[int]] = []
        records = []
        with torch.inference_mode(), predictions_path.open("w") as handle:
            for index, row in enumerate(dataset):
                if index and index % 10 == 0:
                    click.echo(f"[generated-metrics] {split_name}: {index}/{len(dataset)}")

                builder = lambda row=row: build_prompt_inputs(
                    processor=self.processor,
                    ffmpeg=self.ffmpeg,
                    row=row,
                    frame_fps=self.frame_fps,
                    max_frames=self.max_frames,
                    max_audio_seconds=self.max_audio_seconds,
                    image_width=self.image_width,
                    system_prompt=self.system_prompt,
                )
                if self.cache_store is None:
                    prompt_inputs = builder()
                else:
                    prompt_inputs = self.cache_store.load_or_build(kind="prompt", row=row, builder=builder)
                model_inputs = move_tensor_dict(prompt_inputs, device=device)
                generated_ids = model.generate(
                    **model_inputs,
                    max_new_tokens=self.max_new_tokens,
                    do_sample=False,
                    pad_token_id=self.processor.tokenizer.eos_token_id,
                )
                prompt_len = int(prompt_inputs["input_ids"].shape[-1])
                generated_text = self.processor.tokenizer.decode(
                    generated_ids[0][prompt_len:],
                    skip_special_tokens=True,
                ).strip()
                parsed = parse_generated_label_vector(generated_text)
                truth = [int(value) for value in row["label_vector"]]
                y_true.append(truth)
                y_pred.append(parsed["label_vector"])

                record = {
                    "split": split_name,
                    "step": step,
                    "epoch": epoch,
                    "index": index,
                    "video_id": row["video_id"],
                    "target_label_vector": truth,
                    "predicted_label_vector": parsed["label_vector"],
                    "target_json": row["target_json"],
                    "raw_prediction": generated_text,
                    "parse_ok": parsed["parse_ok"],
                    "parse_error": parsed["parse_error"],
                }
                records.append(record)
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")

        if was_training:
            model.train()

        metrics = compute_multilabel_metrics(
            y_true=np.asarray(y_true, dtype=np.int64),
            y_pred=np.asarray(y_pred, dtype=np.int64),
            parse_ok=[bool(record["parse_ok"]) for record in records],
            split_name=split_name,
            step=step,
            epoch=epoch,
        )
        metrics["artifacts"] = {
            "predictions_jsonl": str(predictions_path),
            "metrics_json": str(metrics_path),
            "f1_png": str(figure_path),
        }
        metrics_path.write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + "\n")
        save_f1_figure(metrics=metrics, path=figure_path)
        self.log_to_wandb(metrics=metrics, figure_path=figure_path, split_name=split_name, step=step)
        click.echo(
            "[generated-metrics] "
            f"{split_name}: micro_f1={metrics['micro']['f1']:.4f} "
            f"macro_f1={metrics['macro']['f1']:.4f} "
            f"exact_match={metrics['exact_match']:.4f} "
            f"parse_rate={metrics['parse_rate']:.4f}"
        )
        click.echo(f"[generated-metrics] saved: {metrics_path}")
        return metrics

    def log_to_wandb(self, *, metrics: dict[str, Any], figure_path: Path, split_name: str, step: int) -> None:
        if not self.wandb_enabled:
            return

        try:
            import wandb
        except ImportError:
            return

        if wandb.run is None:
            return

        payload: dict[str, Any] = {
            f"generated/{split_name}/micro_f1": metrics["micro"]["f1"],
            f"generated/{split_name}/macro_f1": metrics["macro"]["f1"],
            f"generated/{split_name}/exact_match": metrics["exact_match"],
            f"generated/{split_name}/hamming_accuracy": metrics["hamming_accuracy"],
            f"generated/{split_name}/parse_rate": metrics["parse_rate"],
            f"generated/{split_name}/f1_plot": wandb.Image(str(figure_path)),
        }
        for feature_id, values in metrics["per_label"].items():
            payload[f"generated/{split_name}/f1/{feature_id}"] = values["f1"]
            payload[f"generated/{split_name}/precision/{feature_id}"] = values["precision"]
            payload[f"generated/{split_name}/recall/{feature_id}"] = values["recall"]
        wandb.log(payload, step=step)


class ProcessorCache:
    """Disk cache for CPU processor outputs keyed by preprocessing config and row."""

    def __init__(self, *, cache_dir: Path, config: dict[str, Any], mode: str) -> None:
        if mode not in {"off", "read-write", "require"}:
            raise ValueError(f"Unknown cache mode: {mode}")
        self.cache_dir = Path(cache_dir)
        self.config = config
        self.config_hash = stable_hash(config)[:16]
        self.root = self.cache_dir / self.config_hash
        self.mode = mode

    def write_config(self) -> None:
        if self.mode == "off":
            return
        self.root.mkdir(parents=True, exist_ok=True)
        config_path = self.root / "cache_config.json"
        config_path.write_text(json.dumps(self.config, indent=2, ensure_ascii=False) + "\n")

    def path_for(self, *, kind: str, row: dict) -> Path:
        if kind not in CACHE_KINDS:
            raise ValueError(f"Unknown cache kind: {kind}")
        split = str(row["split"])
        row_idx = int(row["row_idx"])
        video_id = sanitize_cache_name(str(row["video_id"]))
        row_hash = stable_hash(
            {
                "cache_version": CACHE_VERSION,
                "kind": kind,
                "split": split,
                "row_idx": row_idx,
                "video_id": row["video_id"],
                "target_json": row["target_json"] if kind == "supervised" else None,
            }
        )[:12]
        return self.root / split / kind / f"{row_idx:05d}_{video_id}_{row_hash}.pt"

    def load_or_build(self, *, kind: str, row: dict, builder: Any) -> dict[str, Any]:
        if self.mode == "off":
            return builder()

        path = self.path_for(kind=kind, row=row)
        if path.is_file():
            return self.load(path)

        if self.mode == "require":
            raise click.ClickException(
                f"Missing {kind} processor cache for {row['split']}/{row['row_idx']} "
                f"{row['video_id']}: {path}\n"
                "Run `run_train.py build-cache` with the same media/system-prompt parameters first."
            )

        batch = builder()
        self.save(path=path, kind=kind, row=row, batch=batch)
        return batch

    def build_or_refresh(self, *, kind: str, row: dict, overwrite: bool, builder: Any) -> bool:
        path = self.path_for(kind=kind, row=row)
        if path.is_file() and not overwrite:
            return False

        batch = builder()
        self.save(path=path, kind=kind, row=row, batch=batch)
        return True

    def load(self, path: Path) -> dict[str, Any]:
        import torch

        try:
            payload = torch.load(path, map_location="cpu", weights_only=False)
        except TypeError:
            payload = torch.load(path, map_location="cpu")

        if payload.get("cache_version") != CACHE_VERSION:
            raise click.ClickException(f"Unsupported cache version in {path}")
        if payload.get("config_hash") != self.config_hash:
            raise click.ClickException(f"Cache config hash mismatch in {path}")
        batch = payload.get("batch")
        if not isinstance(batch, dict):
            raise click.ClickException(f"Invalid cache payload in {path}")
        return batch

    def save(self, *, path: Path, kind: str, row: dict, batch: dict[str, Any]) -> None:
        import torch

        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "cache_version": CACHE_VERSION,
            "config_hash": self.config_hash,
            "kind": kind,
            "split": row["split"],
            "row_idx": int(row["row_idx"]),
            "video_id": row["video_id"],
            "batch": detach_tensor_dict_to_cpu(batch),
        }
        tmp_path = path.parent / f".{path.name}.{os.getpid()}.tmp"
        torch.save(payload, tmp_path)
        tmp_path.replace(path)


def build_cache_config(
    *,
    model_dir: Path,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    system_prompt: str,
) -> dict[str, Any]:
    return {
        "cache_version": CACHE_VERSION,
        "model_dir": str(Path(model_dir).expanduser().resolve()),
        "frame_fps": float(frame_fps),
        "max_frames": int(max_frames),
        "max_audio_seconds": float(max_audio_seconds),
        "image_width": int(image_width),
        "system_prompt_sha256": hashlib.sha256(system_prompt.encode("utf-8")).hexdigest(),
        "user_instruction_sha256": hashlib.sha256(USER_INSTRUCTION.encode("utf-8")).hexdigest(),
    }


def build_cached_kind(
    *,
    kind: str,
    processor: Any,
    ffmpeg: str,
    row: dict,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    system_prompt: str,
) -> dict[str, Any]:
    if kind == "supervised":
        return build_supervised_inputs(
            processor=processor,
            ffmpeg=ffmpeg,
            row=row,
            frame_fps=frame_fps,
            max_frames=max_frames,
            max_audio_seconds=max_audio_seconds,
            image_width=image_width,
            system_prompt=system_prompt,
        )
    if kind == "prompt":
        return build_prompt_inputs(
            processor=processor,
            ffmpeg=ffmpeg,
            row=row,
            frame_fps=frame_fps,
            max_frames=max_frames,
            max_audio_seconds=max_audio_seconds,
            image_width=image_width,
            system_prompt=system_prompt,
        )
    raise ValueError(f"Unknown cache kind: {kind}")


def detach_tensor_dict_to_cpu(batch: dict[str, Any]) -> dict[str, Any]:
    import torch

    detached = {}
    for key, value in batch.items():
        if torch.is_tensor(value):
            detached[key] = value.detach().cpu()
        else:
            detached[key] = value
    return detached


def stable_hash(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def sanitize_cache_name(value: str) -> str:
    sanitized = "".join(char if char.isalnum() or char in {"-", "_"} else "_" for char in value)
    return sanitized[:90] or "sample"


def configure_runtime(cuda_devices: str) -> None:
    cuda_devices = ",".join(part.strip() for part in cuda_devices.split(",") if part.strip())
    if not cuda_devices:
        raise click.ClickException("--cuda-devices must not be empty")

    os.environ["CUDA_VISIBLE_DEVICES"] = cuda_devices
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def setup_wandb(
    *,
    enabled: bool,
    wandb_lib: Any,
    project: str,
    entity: str | None,
    run_name: str,
) -> None:
    if not enabled:
        os.environ["WANDB_MODE"] = "disabled"
        return

    api_key = os.environ.get("WANDB_API_KEY")
    if not api_key:
        raise click.ClickException("WANDB_API_KEY is missing. Put it in .env or disable with --no-wandb.")

    os.environ["WANDB_PROJECT"] = project
    os.environ["WANDB_RUN_GROUP"] = project
    os.environ.setdefault("WANDB_WATCH", "false")
    os.environ.setdefault("WANDB_LOG_MODEL", "false")
    if entity:
        os.environ["WANDB_ENTITY"] = entity
    wandb_lib.login(key=api_key, relogin=True)
    click.echo(f"wandb enabled: project={project} run={run_name}")


def enable_gradient_checkpointing(model: Any) -> None:
    try:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    except TypeError:
        model.gradient_checkpointing_enable()
    if hasattr(model, "enable_input_require_grads"):
        model.enable_input_require_grads()


def parse_target_modules(value: str) -> str | list[str]:
    value = value.strip()
    if value == "language":
        return LANGUAGE_LORA_REGEX
    if value == "all-linear":
        return "all-linear"
    modules = [part.strip() for part in value.split(",") if part.strip()]
    if not modules:
        raise click.ClickException("--target-modules must not be empty")
    if len(modules) == 1:
        return modules[0]
    return modules


def load_video_frames(
    *,
    ffmpeg: str,
    video_path: Path,
    fps: float,
    max_frames: int,
    image_width: int,
    duration_sec: float,
) -> list[Image.Image]:
    frame_count = requested_frame_count(duration_sec=duration_sec, fps=fps, max_frames=max_frames)
    ffmpeg_fps = sampled_frame_fps(frame_count, duration_sec)

    with tempfile.TemporaryDirectory(prefix="asd_ds_frames_") as tmpdir:
        out_pattern = Path(tmpdir) / "frame_%04d.jpg"
        command = [
            ffmpeg,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(video_path),
            "-vf",
            f"fps={ffmpeg_fps:.8f},scale={image_width}:-2",
            "-frames:v",
            str(frame_count),
            str(out_pattern),
        ]
        run_command(command)
        frame_paths = sorted(Path(tmpdir).glob("frame_*.jpg"))
        if not frame_paths:
            raise click.ClickException(f"ffmpeg produced no frames for {video_path}")
        return [Image.open(path).convert("RGB").copy() for path in frame_paths]


def requested_frame_count(*, duration_sec: float, fps: float, max_frames: int) -> int:
    if duration_sec <= 0:
        return 1
    return max(1, min(max_frames, int(np.ceil(duration_sec * fps))))


def sampled_frame_fps(frame_count: int, duration_sec: float) -> float:
    if duration_sec <= 0:
        return float(frame_count)
    return frame_count / duration_sec


def load_audio_mono_16k(*, ffmpeg: str, audio_path: Path, max_seconds: float) -> np.ndarray:
    command = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(audio_path),
        "-t",
        f"{max_seconds:.3f}",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-f",
        "f32le",
        "pipe:1",
    ]
    completed = run_command(command, capture_stdout=True)
    audio = np.frombuffer(completed.stdout, dtype=np.float32).copy()
    if audio.size == 0:
        raise click.ClickException(f"ffmpeg produced no audio for {audio_path}")
    return audio


def build_supervised_inputs(
    *,
    processor: Any,
    ffmpeg: str,
    row: dict,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    system_prompt: str,
) -> dict[str, Any]:
    from transformers.video_utils import VideoMetadata

    frames = load_video_frames(
        ffmpeg=ffmpeg,
        video_path=Path(row["video_path"]),
        fps=frame_fps,
        max_frames=max_frames,
        image_width=image_width,
        duration_sec=float(row["duration_sec"]),
    )
    audio = load_audio_mono_16k(
        ffmpeg=ffmpeg,
        audio_path=Path(row["audio_path"]),
        max_seconds=min(float(row["duration_sec"]), max_audio_seconds),
    )
    metadata = VideoMetadata(
        total_num_frames=len(frames),
        fps=sampled_frame_fps(len(frames), float(row["duration_sec"])),
        duration=float(row["duration_sec"]),
        frames_indices=list(range(len(frames))),
    )
    prompt_text = build_chat_text(
        processor,
        row,
        system_prompt=system_prompt,
        include_answer=False,
    )
    full_text = build_chat_text(
        processor,
        row,
        system_prompt=system_prompt,
        include_answer=True,
    )
    prompt_inputs = processor(
        text=[prompt_text],
        videos=[frames],
        audio=[audio],
        return_tensors="pt",
        return_mm_token_type_ids=True,
        videos_kwargs={"video_metadata": [metadata], "do_sample_frames": False},
        audio_kwargs={"sampling_rate": 16000},
    )
    full_inputs = processor(
        text=[full_text],
        videos=[frames],
        audio=[audio],
        return_tensors="pt",
        return_mm_token_type_ids=True,
        videos_kwargs={"video_metadata": [metadata], "do_sample_frames": False},
        audio_kwargs={"sampling_rate": 16000},
    )
    full_inputs["labels"] = build_masked_labels(
        full_inputs,
        prompt_len=prompt_inputs["input_ids"].shape[-1],
    )
    return dict(full_inputs)


def build_prompt_inputs(
    *,
    processor: Any,
    ffmpeg: str,
    row: dict,
    frame_fps: float,
    max_frames: int,
    max_audio_seconds: float,
    image_width: int,
    system_prompt: str,
) -> dict[str, Any]:
    from transformers.video_utils import VideoMetadata

    frames = load_video_frames(
        ffmpeg=ffmpeg,
        video_path=Path(row["video_path"]),
        fps=frame_fps,
        max_frames=max_frames,
        image_width=image_width,
        duration_sec=float(row["duration_sec"]),
    )
    audio = load_audio_mono_16k(
        ffmpeg=ffmpeg,
        audio_path=Path(row["audio_path"]),
        max_seconds=min(float(row["duration_sec"]), max_audio_seconds),
    )
    metadata = VideoMetadata(
        total_num_frames=len(frames),
        fps=sampled_frame_fps(len(frames), float(row["duration_sec"])),
        duration=float(row["duration_sec"]),
        frames_indices=list(range(len(frames))),
    )
    prompt_text = build_chat_text(
        processor,
        row,
        system_prompt=system_prompt,
        include_answer=False,
    )
    return processor(
        text=[prompt_text],
        videos=[frames],
        audio=[audio],
        return_tensors="pt",
        return_mm_token_type_ids=True,
        videos_kwargs={"video_metadata": [metadata], "do_sample_frames": False},
        audio_kwargs={"sampling_rate": 16000},
    )


def move_tensor_dict(batch: dict[str, Any], *, device: Any) -> dict[str, Any]:
    import torch

    moved = {}
    for key, value in batch.items():
        if torch.is_tensor(value):
            moved[key] = value.to(device)
        else:
            moved[key] = value
    return moved


def infer_model_input_device(model: Any) -> Any:
    import torch

    for candidate in (model, getattr(model, "base_model", None), getattr(getattr(model, "base_model", None), "model", None)):
        device_map = getattr(candidate, "hf_device_map", None)
        if not device_map:
            continue

        preferred_keys = (
            "",
            "base_model.model.language_model.model.embed_tokens",
            "language_model.model.embed_tokens",
            "model.embed_tokens",
        )
        for key in preferred_keys:
            if key in device_map:
                return normalize_torch_device(device_map[key])

        for value in device_map.values():
            device = normalize_torch_device(value)
            if device.type == "cuda":
                return device

    try:
        return next(model.parameters()).device
    except StopIteration:
        return torch.device("cuda:0" if torch.cuda.is_available() else "cpu")


def normalize_torch_device(value: Any) -> Any:
    import torch

    if isinstance(value, torch.device):
        return value
    if isinstance(value, int):
        return torch.device(f"cuda:{value}")
    if isinstance(value, str):
        if value == "disk":
            return torch.device("cpu")
        return torch.device(value)
    return torch.device("cpu")


def parse_generated_label_vector(text: str) -> dict[str, Any]:
    try:
        payload = extract_json_payload(text)
        if "features" in payload and isinstance(payload["features"], dict):
            features = payload["features"]
        elif "labels" in payload and isinstance(payload["labels"], dict):
            features = payload["labels"]
        else:
            features = payload

        label_vector = [coerce_label_value(features[feature_id]) for feature_id in FEATURE_IDS]
        return {
            "parse_ok": True,
            "parse_error": None,
            "label_vector": label_vector,
        }
    except Exception as exc:
        return {
            "parse_ok": False,
            "parse_error": str(exc),
            "label_vector": [0 for _ in FEATURE_IDS],
        }


def extract_json_payload(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`").strip()
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:].strip()

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("No JSON object found in model output")

    payload = json.loads(cleaned[start : end + 1])
    if not isinstance(payload, dict):
        raise ValueError("Generated JSON root must be an object")
    return payload


def coerce_label_value(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return int(value != 0)
    if isinstance(value, float):
        return int(value != 0.0)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "yes", "1", "positive", "present"}:
            return 1
        if normalized in {"false", "no", "0", "negative", "absent"}:
            return 0
    raise ValueError(f"Unsupported label value: {value!r}")


def compute_multilabel_metrics(
    *,
    y_true: np.ndarray,
    y_pred: np.ndarray,
    parse_ok: list[bool],
    split_name: str,
    step: int,
    epoch: float | None,
) -> dict[str, Any]:
    if y_true.shape != y_pred.shape:
        raise ValueError(f"Prediction shape mismatch: {y_true.shape} != {y_pred.shape}")
    if y_true.ndim != 2 or y_true.shape[1] != len(FEATURE_IDS):
        raise ValueError(f"Expected label matrix with {len(FEATURE_IDS)} columns, got {y_true.shape}")

    tp = ((y_true == 1) & (y_pred == 1)).sum(axis=0)
    fp = ((y_true == 0) & (y_pred == 1)).sum(axis=0)
    fn = ((y_true == 1) & (y_pred == 0)).sum(axis=0)
    tn = ((y_true == 0) & (y_pred == 0)).sum(axis=0)
    support = y_true.sum(axis=0)

    per_label = {}
    for index, feature_id in enumerate(FEATURE_IDS):
        precision = safe_divide(tp[index], tp[index] + fp[index])
        recall = safe_divide(tp[index], tp[index] + fn[index])
        f1 = f1_from_precision_recall(precision, recall)
        per_label[feature_id] = {
            "name": FEATURE_ID_TO_COLUMN[feature_id],
            "precision": precision,
            "recall": recall,
            "f1": f1,
            "support": int(support[index]),
            "tp": int(tp[index]),
            "fp": int(fp[index]),
            "fn": int(fn[index]),
            "tn": int(tn[index]),
        }

    micro_precision = safe_divide(tp.sum(), tp.sum() + fp.sum())
    micro_recall = safe_divide(tp.sum(), tp.sum() + fn.sum())
    macro_precision = float(np.mean([values["precision"] for values in per_label.values()]))
    macro_recall = float(np.mean([values["recall"] for values in per_label.values()]))
    macro_f1 = float(np.mean([values["f1"] for values in per_label.values()]))

    return {
        "split": split_name,
        "step": step,
        "epoch": epoch,
        "num_samples": int(y_true.shape[0]),
        "num_labels": len(FEATURE_IDS),
        "parse_rate": float(np.mean(np.asarray(parse_ok, dtype=np.float32))) if parse_ok else 0.0,
        "exact_match": float(np.mean(np.all(y_true == y_pred, axis=1))) if y_true.shape[0] else 0.0,
        "hamming_accuracy": float(np.mean(y_true == y_pred)) if y_true.size else 0.0,
        "micro": {
            "precision": micro_precision,
            "recall": micro_recall,
            "f1": f1_from_precision_recall(micro_precision, micro_recall),
        },
        "macro": {
            "precision": macro_precision,
            "recall": macro_recall,
            "f1": macro_f1,
        },
        "per_label": per_label,
    }


def safe_divide(numerator: Any, denominator: Any) -> float:
    denominator = float(denominator)
    if denominator == 0.0:
        return 0.0
    return float(numerator) / denominator


def f1_from_precision_recall(precision: float, recall: float) -> float:
    if precision + recall == 0.0:
        return 0.0
    return 2.0 * precision * recall / (precision + recall)


def save_f1_figure(*, metrics: dict[str, Any], path: Path) -> None:
    width = 1400
    row_height = 58
    top = 130
    bottom = 50
    height = top + row_height * len(FEATURE_IDS) + bottom
    image = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()

    title = (
        f"{metrics['split']} step={metrics['step']} "
        f"micro-F1={metrics['micro']['f1']:.3f} "
        f"macro-F1={metrics['macro']['f1']:.3f} "
        f"exact={metrics['exact_match']:.3f}"
    )
    draw.text((40, 32), "ASD-DS Generated Label F1 by Behavior Dimension", fill=(20, 20, 20), font=font)
    draw.text((40, 62), title, fill=(60, 60, 60), font=font)
    draw.text((40, 92), f"parse_rate={metrics['parse_rate']:.3f} samples={metrics['num_samples']}", fill=(60, 60, 60), font=font)

    label_x = 40
    bar_x = 470
    bar_width = 620
    value_x = bar_x + bar_width + 28
    for index, feature_id in enumerate(FEATURE_IDS):
        values = metrics["per_label"][feature_id]
        y = top + index * row_height
        f1 = float(values["f1"])
        bar_fill = (43, 113, 181) if f1 >= 0.5 else (190, 72, 72)
        label = f"{feature_id} {values['name']}"
        summary = (
            f"F1 {f1:.3f}  P {values['precision']:.3f}  "
            f"R {values['recall']:.3f}  support {values['support']}"
        )
        draw.text((label_x, y + 8), label, fill=(30, 30, 30), font=font)
        draw.rectangle((bar_x, y + 4, bar_x + bar_width, y + 30), outline=(170, 170, 170), width=1)
        draw.rectangle((bar_x, y + 4, bar_x + int(bar_width * f1), y + 30), fill=bar_fill)
        draw.text((value_x, y + 8), summary, fill=(30, 30, 30), font=font)
        draw.line((bar_x, y + 42, value_x + 260, y + 42), fill=(235, 235, 235), width=1)

    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def run_command(command: list[str], *, capture_stdout: bool = False) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE if capture_stdout else None,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode("utf-8", errors="replace") if exc.stderr else ""
        raise click.ClickException(f"Command failed: {' '.join(command)}\n{stderr}") from exc


def build_chat_text(processor, row: dict, *, system_prompt: str, include_answer: bool) -> str:
    messages = [
        {"role": "system", "content": system_prompt},
        {
            "role": "user",
            "content": [
                {"type": "video"},
                {"type": "audio"},
                {"type": "text", "text": USER_INSTRUCTION},
            ],
        },
    ]
    if include_answer:
        messages.append({"role": "assistant", "content": row["target_json"]})
        return processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)

    return processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)


def build_masked_labels(inputs: dict[str, torch.Tensor], *, prompt_len: int) -> torch.Tensor:
    labels = inputs["input_ids"].clone()
    labels[:, :prompt_len] = -100
    if "attention_mask" in inputs:
        labels[inputs["attention_mask"] == 0] = -100
    if (labels != -100).sum().item() == 0:
        raise click.ClickException("No supervised label tokens remain after masking.")
    return labels


def print_sample_summary(row: dict, split: str, row_index: int) -> None:
    click.echo("\n== Dataset sample ==")
    click.echo(f"split/index: {split}/{row_index}")
    click.echo(f"video_id: {row['video_id']}")
    click.echo(f"source_id: {row['source_id']}")
    click.echo(f"clip_seconds: {row['start_sec']} -> {row['end_sec']} ({row['duration_sec']}s)")
    click.echo(f"video_path: {row['video_path']}")
    click.echo(f"audio_path: {row['audio_path']}")
    click.echo(f"positive_feature_ids: {row['positive_feature_ids']}")
    click.echo(f"positive_label_names: {row['positive_label_names']}")
    click.echo(f"label_vector: {row['label_vector']}")


def print_tensor_summary(prefix: str, batch: dict[str, torch.Tensor]) -> None:
    for key, value in batch.items():
        if hasattr(value, "shape"):
            click.echo(f"{prefix}.{key}: shape={tuple(value.shape)} dtype={value.dtype}")
        else:
            click.echo(f"{prefix}.{key}: {type(value).__name__}")


def indent_preview(text: str, max_chars: int = 900) -> str:
    preview = text[:max_chars]
    if len(text) > max_chars:
        preview += "...[truncated]"
    return "\n".join(f"  {line}" for line in preview.splitlines())


def assert_label_payload(target_json: str) -> None:
    payload = json.loads(target_json)
    feature_keys = tuple(payload["features"].keys())
    if feature_keys != FEATURE_IDS:
        raise click.ClickException(f"Unexpected target_json feature order: {feature_keys}")
    if not all(isinstance(value, bool) for value in payload["features"].values()):
        raise click.ClickException("target_json features must all be booleans")


if __name__ == "__main__":
    cli()
