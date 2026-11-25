"""Phase 1 offline audio-feature pipeline for Walsey voice intent research.

The audio path maps PCM waveforms to log-Mel values without speech recognition.
The package never executes a command or touches BLE. Older transcript-text
experiments remain separate and are not used by the acoustic feature path.
"""

from __future__ import annotations

from .audio_features import (
    DEFAULT_AUDIO_CONFIG,
    AudioClip,
    AudioFeatureConfig,
    AudioProcessingError,
    load_wav,
    log_mel_spectrogram,
    pcm16le_to_mono_float,
)
from .models import CATALOGUE, DEFAULT_MODEL, EmbeddingModelSpec, get_model_spec
from .preprocessing import (
    PREPROCESSING_VERSION,
    PreprocessedText,
    normalize_for_embedding,
    normalize_parser_tokens,
    preprocess,
    strip_wake_word_tokens,
)

__all__ = [
    "DEFAULT_AUDIO_CONFIG",
    "CATALOGUE",
    "DEFAULT_MODEL",
    "PREPROCESSING_VERSION",
    "AudioClip",
    "AudioFeatureConfig",
    "AudioProcessingError",
    "EmbeddingModelSpec",
    "PreprocessedText",
    "get_model_spec",
    "load_wav",
    "log_mel_spectrogram",
    "normalize_for_embedding",
    "normalize_parser_tokens",
    "pcm16le_to_mono_float",
    "preprocess",
    "strip_wake_word_tokens",
]
