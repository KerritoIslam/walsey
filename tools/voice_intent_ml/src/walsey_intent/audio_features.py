"""Audio-signal preprocessing and log-Mel feature extraction.

The public input is normalized mono float audio at the configured sample rate.
WAV and the app's little-endian PCM16 format are converted by the helpers below.
"""

from __future__ import annotations

import math
import wave
from dataclasses import asdict, dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.signal import resample_poly


class AudioProcessingError(ValueError):
    """Audio input or feature configuration is invalid."""


@dataclass(frozen=True)
class AudioFeatureConfig:
    """Versioned parameters for the deterministic log-Mel transform."""

    sample_rate: int = 16_000
    n_fft: int = 512
    win_length: int = 400
    hop_length: int = 160
    n_mels: int = 64
    f_min_hz: float = 0.0
    f_max_hz: float = 8_000.0
    log_floor: float = 1e-10
    version: str = "logmel-v1"

    def __post_init__(self) -> None:
        integer_fields = (
            ("sample_rate", self.sample_rate),
            ("n_fft", self.n_fft),
            ("win_length", self.win_length),
            ("hop_length", self.hop_length),
            ("n_mels", self.n_mels),
        )
        for name, value in integer_fields:
            if isinstance(value, bool) or not isinstance(value, int):
                raise AudioProcessingError(f"{name} must be an integer")
        if self.sample_rate <= 0:
            raise AudioProcessingError("sample_rate must be positive")
        if self.n_fft < self.win_length or self.win_length <= 0:
            raise AudioProcessingError("n_fft must be >= positive win_length")
        if self.hop_length <= 0 or self.hop_length > self.win_length:
            raise AudioProcessingError(
                "hop_length must be positive and no greater than win_length"
            )
        if self.n_mels <= 0:
            raise AudioProcessingError("n_mels must be positive")
        if not 0 <= self.f_min_hz < self.f_max_hz <= self.sample_rate / 2:
            raise AudioProcessingError(
                "frequency bounds must satisfy 0 <= f_min < f_max <= Nyquist"
            )
        if not math.isfinite(self.log_floor) or self.log_floor <= 0:
            raise AudioProcessingError("log_floor must be finite and positive")

    def to_dict(self) -> dict[str, int | float | str]:
        """Return the exact serializable transform configuration."""

        return asdict(self)


DEFAULT_AUDIO_CONFIG = AudioFeatureConfig()


@dataclass(frozen=True)
class AudioClip:
    """Mono float samples resampled to the configured target rate."""

    samples: np.ndarray
    source_sample_rate: int
    source_channels: int
    source_frames: int


def pcm16le_to_mono_float(
    pcm: bytes | bytearray | memoryview,
    *,
    channels: int = 1,
) -> np.ndarray:
    """Decode interleaved little-endian PCM16 and downmix channels by mean."""

    if channels <= 0:
        raise AudioProcessingError("channels must be positive")
    if len(pcm) % 2:
        raise AudioProcessingError(
            "PCM16 byte length is odd; the final sample is truncated"
        )
    values = np.frombuffer(pcm, dtype="<i2")
    if values.size == 0:
        raise AudioProcessingError("audio contains no PCM samples")
    if values.size % channels:
        raise AudioProcessingError(
            "PCM16 sample count is not divisible by the channel count"
        )
    frames = values.reshape(-1, channels).astype(np.float32) / 32768.0
    return frames.mean(axis=1, dtype=np.float32)


def _resample(
    samples: np.ndarray,
    source_rate: int,
    target_rate: int,
) -> np.ndarray:
    if source_rate <= 0:
        raise AudioProcessingError("source sample rate must be positive")
    if source_rate == target_rate:
        return np.asarray(samples, dtype=np.float32)
    divisor = math.gcd(source_rate, target_rate)
    converted = resample_poly(
        samples,
        up=target_rate // divisor,
        down=source_rate // divisor,
    )
    return np.asarray(converted, dtype=np.float32)


def load_wav(
    path: Path,
    config: AudioFeatureConfig = DEFAULT_AUDIO_CONFIG,
) -> AudioClip:
    """Read uncompressed PCM16 WAV, downmix to mono, and resample if needed."""

    try:
        with wave.open(str(path), "rb") as wav:
            channels = wav.getnchannels()
            sample_width = wav.getsampwidth()
            source_rate = wav.getframerate()
            source_frames = wav.getnframes()
            compression = wav.getcomptype()
            raw = wav.readframes(source_frames)
    except (wave.Error, EOFError) as error:
        raise AudioProcessingError(f"{path} is not a supported WAV file") from error

    if compression != "NONE":
        raise AudioProcessingError(
            f"{path} uses unsupported WAV compression {compression!r}"
        )
    if sample_width != 2:
        raise AudioProcessingError(
            f"{path} must use 16-bit PCM, got {sample_width * 8}-bit samples"
        )
    if channels <= 0 or source_rate <= 0:
        raise AudioProcessingError(f"{path} has invalid audio metadata")
    if source_frames <= 0:
        raise AudioProcessingError(f"{path} contains no audio frames")
    expected_bytes = source_frames * channels * sample_width
    if len(raw) != expected_bytes:
        raise AudioProcessingError(
            f"{path} is truncated: expected {expected_bytes} audio bytes, "
            f"got {len(raw)}"
        )

    samples = pcm16le_to_mono_float(raw, channels=channels)
    samples = _resample(samples, source_rate, config.sample_rate)
    if not np.isfinite(samples).all():
        raise AudioProcessingError(f"{path} contains non-finite audio samples")
    return AudioClip(
        samples=samples,
        source_sample_rate=source_rate,
        source_channels=channels,
        source_frames=source_frames,
    )


@lru_cache(maxsize=8)
def _mel_filterbank(config: AudioFeatureConfig) -> np.ndarray:
    """Create sum-normalized triangular filters on the HTK Mel scale."""

    def hz_to_mel(hz: np.ndarray) -> np.ndarray:
        return 2595.0 * np.log10(1.0 + hz / 700.0)

    def mel_to_hz(mel: np.ndarray) -> np.ndarray:
        return 700.0 * (np.power(10.0, mel / 2595.0) - 1.0)

    mel_edges = np.linspace(
        hz_to_mel(np.array([config.f_min_hz]))[0],
        hz_to_mel(np.array([config.f_max_hz]))[0],
        config.n_mels + 2,
    )
    hz_edges = mel_to_hz(mel_edges)
    frequencies = np.fft.rfftfreq(config.n_fft, d=1.0 / config.sample_rate)
    filters = np.zeros((config.n_mels, frequencies.size), dtype=np.float64)

    for band in range(config.n_mels):
        left, center, right = hz_edges[band : band + 3]
        rising = (frequencies - left) / (center - left)
        falling = (right - frequencies) / (right - center)
        filters[band] = np.maximum(0.0, np.minimum(rising, falling))
        total = filters[band].sum()
        if total == 0:
            raise AudioProcessingError(
                "Mel filterbank has an empty band; reduce n_mels or increase n_fft"
            )
        filters[band] /= total
    return filters


def log_mel_spectrogram(
    samples: np.ndarray,
    *,
    sample_rate: int = DEFAULT_AUDIO_CONFIG.sample_rate,
    config: AudioFeatureConfig = DEFAULT_AUDIO_CONFIG,
) -> np.ndarray:
    """Convert mono float waveform samples to ``float32 [mel_bins, frames]``.

    The operation uses a Hann window, zero-boundary padding, power spectrum,
    sum-normalized HTK Mel filters, and a fixed natural-log floor. It does not
    peak-normalize, clip, or otherwise alter the waveform amplitude.
    """

    if sample_rate != config.sample_rate:
        raise AudioProcessingError(
            f"sample rate {sample_rate} does not match configured "
            f"rate {config.sample_rate}; resample explicitly first"
        )
    values = np.asarray(samples, dtype=np.float32)
    if values.ndim != 1:
        raise AudioProcessingError(
            f"expected mono 1-D audio, got shape {values.shape}"
        )
    if values.size == 0:
        raise AudioProcessingError("audio contains no samples")
    if not np.isfinite(values).all():
        raise AudioProcessingError("audio contains NaN or infinity")
    if values.size < config.win_length:
        values = np.pad(values, (0, config.win_length - values.size))

    _, _, spectrum = signal.stft(
        values,
        fs=config.sample_rate,
        window="hann",
        nperseg=config.win_length,
        noverlap=config.win_length - config.hop_length,
        nfft=config.n_fft,
        detrend=False,
        return_onesided=True,
        boundary="zeros",
        padded=True,
        scaling="spectrum",
    )
    power = np.square(np.abs(spectrum), dtype=np.float64)
    mel_power = _mel_filterbank(config) @ power
    features = np.log(np.maximum(mel_power, config.log_floor))
    return np.asarray(features, dtype=np.float32)
