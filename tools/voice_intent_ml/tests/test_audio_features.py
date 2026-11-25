from __future__ import annotations

import wave

import numpy as np
import pytest

from walsey_intent.audio_features import (
    AudioFeatureConfig,
    AudioProcessingError,
    load_wav,
    log_mel_spectrogram,
    pcm16le_to_mono_float,
)
from walsey_intent.audio_pipeline import (
    AudioFeatureBuildError,
    build_audio_features,
)


def _sine(
    frequency: float,
    *,
    seconds: float = 1.0,
    sample_rate: int = 16_000,
    amplitude: float = 0.5,
) -> np.ndarray:
    times = np.arange(round(seconds * sample_rate)) / sample_rate
    return (amplitude * np.sin(2 * np.pi * frequency * times)).astype(
        np.float32
    )


def _write_stereo_wav(path, samples: np.ndarray, sample_rate: int) -> None:
    pcm = np.round(np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    interleaved = np.column_stack((pcm, pcm)).reshape(-1)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(interleaved.tobytes())


def test_log_mel_shape_is_time_frequency_data_and_deterministic() -> None:
    audio = _sine(440.0)

    first = log_mel_spectrogram(audio)
    second = log_mel_spectrogram(audio)

    assert first.shape[0] == 64
    assert first.shape[1] > 1
    assert first.dtype == np.float32
    assert np.isfinite(first).all()
    np.testing.assert_array_equal(first, second)


def test_different_tone_frequencies_peak_in_different_mel_bands() -> None:
    low = log_mel_spectrogram(_sine(440.0)).mean(axis=1)
    high = log_mel_spectrogram(_sine(2_500.0)).mean(axis=1)

    assert int(low.argmax()) != int(high.argmax())


def test_silence_uses_fixed_log_floor_and_amplitude_is_not_normalized() -> None:
    config = AudioFeatureConfig()
    silence = log_mel_spectrogram(
        np.zeros(16_000, dtype=np.float32),
        config=config,
    )
    quiet = log_mel_spectrogram(_sine(440.0, amplitude=0.05), config=config)
    loud = log_mel_spectrogram(_sine(440.0, amplitude=0.5), config=config)

    np.testing.assert_allclose(silence, np.log(config.log_floor), atol=1e-6)
    assert float(quiet.max()) < float(loud.max())


def test_pcm16_little_endian_decoding_and_truncation_guard() -> None:
    samples = np.array([-32768, 0, 32767], dtype="<i2")

    decoded = pcm16le_to_mono_float(samples.tobytes())

    np.testing.assert_allclose(
        decoded,
        [-1.0, 0.0, 32767 / 32768.0],
        atol=1e-7,
    )
    with pytest.raises(AudioProcessingError, match="odd"):
        pcm16le_to_mono_float(b"\x00")


def test_wav_is_downmixed_and_resampled_to_capture_rate(tmp_path) -> None:
    source_rate = 44_100
    path = tmp_path / "stereo.wav"
    _write_stereo_wav(path, _sine(440.0, sample_rate=source_rate), source_rate)

    clip = load_wav(path)

    assert clip.source_sample_rate == source_rate
    assert clip.source_channels == 2
    assert clip.samples.dtype == np.float32
    assert abs(clip.samples.size - 16_000) <= 1
    features = log_mel_spectrogram(clip.samples)
    assert features.shape[0] == 64


@pytest.mark.parametrize(
    "samples",
    [
        np.zeros((2, 8), dtype=np.float32),
        np.array([0.0, np.nan], dtype=np.float32),
        np.array([], dtype=np.float32),
    ],
)
def test_invalid_waveforms_are_rejected(samples: np.ndarray) -> None:
    with pytest.raises(AudioProcessingError):
        log_mel_spectrogram(samples)


def test_log_mel_rejects_mismatched_sample_rate() -> None:
    with pytest.raises(AudioProcessingError, match="does not match"):
        log_mel_spectrogram(_sine(440.0), sample_rate=44_100)


def test_audio_configuration_requires_integer_dimensions() -> None:
    with pytest.raises(AudioProcessingError, match="n_mels must be an integer"):
        AudioFeatureConfig(n_mels=64.5)  # type: ignore[arg-type]


def test_audio_build_saves_numeric_features_and_original_metadata(tmp_path) -> None:
    wav_path = tmp_path / "command.wav"
    _write_stereo_wav(wav_path, _sine(440.0), 16_000)

    result = build_audio_features(
        wav_path,
        tmp_path / "out",
        sample_id="sample-1",
        intent="powerOn",
        parameters=("test parameter annotation",),
    )

    saved = np.load(
        result.output_directory / "features.npy",
        allow_pickle=False,
    )
    assert saved.dtype == np.float32
    assert saved.shape == tuple(result.metadata["features"]["shape"])
    assert result.metadata["sourceAudio"]["fileName"] == "command.wav"
    assert result.metadata["label"]["intent"] == "powerOn"
    assert "transcript" not in result.metadata
    assert (result.output_directory / "metadata.json").is_file()


def test_audio_build_rejects_unsafe_sample_id(tmp_path) -> None:
    wav_path = tmp_path / "command.wav"
    _write_stereo_wav(wav_path, _sine(440.0), 16_000)

    with pytest.raises(AudioFeatureBuildError, match="sample_id"):
        build_audio_features(
            wav_path,
            tmp_path / "out",
            sample_id="..\\escape",
        )
