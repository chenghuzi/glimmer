from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import click
import numpy as np
import torch
from PIL import Image
from transformers import AutoProcessor
from transformers.video_utils import VideoMetadata

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
def train() -> None:
    """Actual LoRA training entrypoint, to be implemented after smoke-test validation."""
    raise click.ClickException("train is not implemented yet. Run `smoke-test` first.")


def find_tool(name: str) -> str:
    path = shutil.which(name)
    if path:
        return path

    brew_path = BREW_BIN / name
    if brew_path.is_file():
        return str(brew_path)

    raise click.ClickException(f"Could not find {name}. Install it or add it to PATH.")


def load_video_frames(
    *,
    ffmpeg: str,
    video_path: Path,
    fps: float,
    max_frames: int,
    image_width: int,
) -> list[Image.Image]:
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
            f"fps={fps},scale={image_width}:-2",
            "-frames:v",
            str(max_frames),
            str(out_pattern),
        ]
        run_command(command)
        frame_paths = sorted(Path(tmpdir).glob("frame_*.jpg"))
        if not frame_paths:
            raise click.ClickException(f"ffmpeg produced no frames for {video_path}")
        return [Image.open(path).convert("RGB").copy() for path in frame_paths]


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
