"""Build and save log-Mel features for one original audio recording."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from .audio_features import (
    DEFAULT_AUDIO_CONFIG,
    AudioFeatureConfig,
    log_mel_spectrogram,
    load_wav,
)
from .io import INTENT_LABELS, sha256_file, write_json

AUDIO_FEATURE_SCHEMA_VERSION = 1
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class AudioFeatureBuildError(ValueError):
    """The audio feature build request is inconsistent or unsafe."""


@dataclass(frozen=True)
class AudioFeatureBuild:
    metadata: dict[str, Any]
    matrix: np.ndarray
    output_directory: Path


def build_audio_features(
    audio_path: Path,
    output_directory: Path,
    *,
    sample_id: str | None = None,
    intent: str | None = None,
    parameters: Sequence[str] = (),
    config: AudioFeatureConfig = DEFAULT_AUDIO_CONFIG,
) -> AudioFeatureBuild:
    """Extract and save one clip without converting it to text."""

    source = Path(audio_path)
    identifier = sample_id or source.stem
    if not _SAFE_ID.fullmatch(identifier):
        raise AudioFeatureBuildError(
            "sample_id may contain only letters, digits, dot, underscore, "
            "and hyphen, and must start with a letter or digit"
        )
    if intent is not None and intent not in INTENT_LABELS:
        raise AudioFeatureBuildError(
            f"intent must be one of {INTENT_LABELS}, got {intent!r}"
        )
    if not all(isinstance(parameter, str) for parameter in parameters):
        raise AudioFeatureBuildError("parameters must contain only strings")

    clip = load_wav(source, config)
    matrix = log_mel_spectrogram(
        clip.samples,
        sample_rate=config.sample_rate,
        config=config,
    )
    sample_directory = Path(output_directory) / identifier
    sample_directory.mkdir(parents=True, exist_ok=True)
    np.save(sample_directory / "features.npy", matrix, allow_pickle=False)

    metadata: dict[str, Any] = {
        "schemaVersion": AUDIO_FEATURE_SCHEMA_VERSION,
        "id": identifier,
        "sourceAudio": {
            "fileName": source.name,
            "sha256": sha256_file(source),
            "sourceSampleRate": clip.source_sample_rate,
            "sourceChannels": clip.source_channels,
            "sourceFrames": clip.source_frames,
            "durationSeconds": clip.source_frames / clip.source_sample_rate,
            "targetSampleRate": config.sample_rate,
        },
        "label": {
            "intent": intent,
            "parameters": list(parameters),
        },
        "features": {
            "file": "features.npy",
            "shape": [int(matrix.shape[0]), int(matrix.shape[1])],
            "dtype": str(matrix.dtype),
            "axes": ["mel_bin", "frame"],
            "config": config.to_dict(),
        },
    }
    write_json(sample_directory / "metadata.json", metadata)
    return AudioFeatureBuild(
        metadata=metadata,
        matrix=matrix,
        output_directory=sample_directory,
    )
