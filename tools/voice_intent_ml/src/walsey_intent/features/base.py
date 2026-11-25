"""Feature-extraction interfaces shared by training and inference.

The pipeline always calls :meth:`FeatureExtractor.transform` with already
preprocessed ``canonical`` strings. Keeping the protocol this small is what
makes the TF-IDF baseline and a Sentence Transformer interchangeable, and what
will let Phase 5/6 swap in an ONNX Runtime backend without touching the
preprocessing contract.
"""

from __future__ import annotations

from typing import Protocol, Sequence, runtime_checkable

import numpy as np


class FeatureExtractionError(RuntimeError):
    """Feature extraction failed for a data or model reason."""


class EmptyTextError(FeatureExtractionError):
    """An empty string reached an extractor; callers must filter these."""


class ModelDimensionMismatch(FeatureExtractionError):
    """The loaded model's output width differs from the catalogue claim."""


class FeatureManifestMismatch(FeatureExtractionError):
    """A saved feature file does not match the requested pipeline."""


@runtime_checkable
class EmbeddingBackend(Protocol):
    """Low-level encoder seam (Sentence Transformers today, ONNX later)."""

    name: str
    model_id: str
    revision: str | None
    dimension: int
    max_seq_length: int

    def encode(
        self,
        texts: Sequence[str],
        *,
        batch_size: int = 32,
    ) -> np.ndarray:
        """Return one vector per text, shape ``(len(texts), dimension)``."""


@runtime_checkable
class FeatureExtractor(Protocol):
    """A deterministic text-to-matrix mapper."""

    name: str

    @property
    def dimension(self) -> int: ...

    def transform(self, texts: Sequence[str]) -> np.ndarray:
        """Return ``float32`` vectors, one row per input text."""


@runtime_checkable
class FittableFeatureExtractor(FeatureExtractor, Protocol):
    """An extractor that needs a corpus (the TF-IDF baseline)."""

    def fit(self, texts: Sequence[str]) -> None: ...


def validate_texts(texts: Sequence[str]) -> list[str]:
    """Reject non-strings and empty/whitespace-only inputs.

    Empty transcripts never reach this layer in the app: Whisper reports
    ``SpeechNoSpeechDetected`` before the parser is called. In the research
    pipeline a bare wake word also becomes empty after stripping, so the
    caller filters those rows and records them as skipped.
    """

    cleaned: list[str] = []
    for index, text in enumerate(texts):
        if not isinstance(text, str):
            raise TypeError(
                f"text at index {index} must be a str, got "
                f"{type(text).__name__}"
            )
        if not text.strip():
            raise EmptyTextError(
                f"text at index {index} is empty; filter it before extraction"
            )
        cleaned.append(text)
    if not cleaned:
        raise EmptyTextError("no texts to extract")
    return cleaned


def l2_normalize(
    matrix: np.ndarray,
    *,
    allow_zero_rows: bool = False,
) -> np.ndarray:
    """Return row-wise L2-normalized ``float32`` vectors.

    Zero rows are rejected by default: a zero vector carries no direction and
    would make cosine comparisons meaningless. The pipeline filters empty
    inputs instead of inventing a direction for them. The TF-IDF baseline is
    the one caller that opts in: a sentence whose tokens are all out of
    vocabulary legitimately has no shared word with the corpus.
    """

    values = np.asarray(matrix, dtype=np.float32)
    if values.ndim != 2:
        raise FeatureExtractionError(
            f"expected a 2-D matrix, got shape {values.shape}"
        )
    if values.shape[0] == 0:
        return values
    norms = np.linalg.norm(values, axis=1, keepdims=True)
    if not np.isfinite(norms).all():
        raise FeatureExtractionError("the model returned a non-finite vector")
    if np.any(norms == 0):
        if not allow_zero_rows:
            raise FeatureExtractionError(
                "the model returned a zero vector; refusing to normalize it"
            )
        safe = np.where(norms == 0, 1.0, norms)
        return (values / safe).astype(np.float32, copy=False)
    return (values / norms).astype(np.float32, copy=False)


def validate_matrix(
    matrix: np.ndarray,
    *,
    rows: int,
    dimension: int,
    allow_zero_rows: bool = False,
) -> np.ndarray:
    """Validate shape/dtype/finiteness and return a normalized ``float32`` copy."""

    values = np.asarray(matrix)
    if values.shape != (rows, dimension):
        raise FeatureExtractionError(
            f"expected shape ({rows}, {dimension}), got {values.shape}"
        )
    if not np.issubdtype(values.dtype, np.floating):
        raise FeatureExtractionError(
            f"expected a floating-point matrix, got {values.dtype}"
        )
    values = values.astype(np.float32, copy=False)
    if not np.isfinite(values).all():
        raise FeatureExtractionError("the matrix contains NaN or infinity")
    normalized = l2_normalize(values, allow_zero_rows=allow_zero_rows)
    norms = np.linalg.norm(normalized, axis=1)
    if allow_zero_rows:
        nonzero = norms[norms > 0]
        ok = np.allclose(nonzero, 1.0, atol=1e-5) if nonzero.size else True
    else:
        ok = np.allclose(norms, 1.0, atol=1e-5)
    if not ok:
        raise FeatureExtractionError(
            "the matrix could not be L2-normalized to unit rows"
        )
    return normalized
