from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import click
import numpy as np
from PIL import Image

from asd_ds_dataset import FEATURE_IDS, load_asd_ds


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
DEFAULT_WANDB_PROJECT = "gemma4-asd-ft"
DEFAULT_RUN_NAME = "gemma4-asd-lora-r32"
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


@cli.command("train")
@click.option("--cuda-devices", default="1,2,3", show_default=True, help="Physical CUDA device IDs.")
@click.option("--data-root", default=DEFAULT_DATA_ROOT, show_default=True, type=click.Path(path_type=Path))
@click.option("--model-dir", default=DEFAULT_MODEL_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option("--output-dir", default=DEFAULT_OUTPUT_DIR, show_default=True, type=click.Path(path_type=Path))
@click.option("--run-name", default=DEFAULT_RUN_NAME, show_default=True)
@click.option("--wandb-project", default=DEFAULT_WANDB_PROJECT, show_default=True)
@click.option("--wandb-entity", default=None)
@click.option("--env-file", default=".env", show_default=True, type=click.Path(path_type=Path))
@click.option("--wandb/--no-wandb", default=True, show_default=True)
@click.option("--num-train-epochs", default=1.0, show_default=True, type=click.FloatRange(min=0))
@click.option("--max-steps", default=-1, show_default=True, type=int)
@click.option("--max-train-samples", default=None, type=click.IntRange(min=1))
@click.option("--max-eval-samples", default=None, type=click.IntRange(min=1))
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
@click.option("--bf16/--no-bf16", default=True, show_default=True)
@click.option("--gradient-checkpointing/--no-gradient-checkpointing", default=True, show_default=True)
@click.option("--resume-from-checkpoint", default=None, type=click.Path(path_type=Path))
@click.option("--system-prompt", default=DEFAULT_SYSTEM_PROMPT, show_default=False)
def train(
    cuda_devices: str,
    data_root: Path,
    model_dir: Path,
    output_dir: Path,
    run_name: str,
    wandb_project: str,
    wandb_entity: str | None,
    env_file: Path,
    wandb: bool,
    num_train_epochs: float,
    max_steps: int,
    max_train_samples: int | None,
    max_eval_samples: int | None,
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
    click.echo(f"ffmpeg: {ffmpeg}")

    dataset = load_asd_ds(data_root)
    train_dataset = dataset["train"]
    eval_dataset = dataset["validation"]
    if max_train_samples is not None:
        train_dataset = train_dataset.select(range(min(max_train_samples, len(train_dataset))))
    if max_eval_samples is not None:
        eval_dataset = eval_dataset.select(range(min(max_eval_samples, len(eval_dataset))))

    processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
    collator = Gemma4ASDDSCollator(
        processor=processor,
        ffmpeg=ffmpeg,
        frame_fps=frame_fps,
        max_frames=max_frames,
        max_audio_seconds=max_audio_seconds,
        image_width=image_width,
        system_prompt=system_prompt,
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

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        data_collator=collator,
        processing_class=processor,
    )

    click.echo("== Starting training ==")
    trainer.train(resume_from_checkpoint=str(resume_from_checkpoint) if resume_from_checkpoint else None)
    click.echo("== Saving adapter and processor ==")
    trainer.save_model(str(output_dir))
    processor.save_pretrained(output_dir)
    click.echo(f"Saved training artifacts to {output_dir}")


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
    ) -> None:
        self.processor = processor
        self.ffmpeg = ffmpeg
        self.frame_fps = frame_fps
        self.max_frames = max_frames
        self.max_audio_seconds = max_audio_seconds
        self.image_width = image_width
        self.system_prompt = system_prompt

    def __call__(self, examples: list[dict]) -> dict:
        if len(examples) != 1:
            raise ValueError("Gemma4ASDDSCollator currently supports batch size 1 only.")

        from transformers.video_utils import VideoMetadata

        row = examples[0]
        frames = load_video_frames(
            ffmpeg=self.ffmpeg,
            video_path=Path(row["video_path"]),
            fps=self.frame_fps,
            max_frames=self.max_frames,
            image_width=self.image_width,
            duration_sec=float(row["duration_sec"]),
        )
        audio = load_audio_mono_16k(
            ffmpeg=self.ffmpeg,
            audio_path=Path(row["audio_path"]),
            max_seconds=min(float(row["duration_sec"]), self.max_audio_seconds),
        )
        metadata = VideoMetadata(
            total_num_frames=len(frames),
            fps=sampled_frame_fps(len(frames), float(row["duration_sec"])),
            duration=float(row["duration_sec"]),
            frames_indices=list(range(len(frames))),
        )

        prompt_text = build_chat_text(
            self.processor,
            row,
            system_prompt=self.system_prompt,
            include_answer=False,
        )
        full_text = build_chat_text(
            self.processor,
            row,
            system_prompt=self.system_prompt,
            include_answer=True,
        )
        prompt_inputs = self.processor(
            text=[prompt_text],
            videos=[frames],
            audio=[audio],
            return_tensors="pt",
            return_mm_token_type_ids=True,
            videos_kwargs={"video_metadata": [metadata], "do_sample_frames": False},
            audio_kwargs={"sampling_rate": 16000},
        )
        full_inputs = self.processor(
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
