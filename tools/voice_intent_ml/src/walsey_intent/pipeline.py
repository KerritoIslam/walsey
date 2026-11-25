"""The single preprocessing -> feature -> manifest path.

Training and inference must call the *same* function with the same versioned
preprocessing. This module is that function: it takes labeled sentences,
produces ``canonical`` strings, hands them to one :class:`FeatureExtractor`,
and writes a matrix plus a manifest that records exactly how it was produced.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from .features.base import (
    EmptyTextError,
    FeatureExtractionError,
    FeatureExtractor,
)
from .io import (
    DatasetRow,
    build_manifest,
    load_manifest,
    load_matrix,
    read_jsonl,
    save_matrix,
    sha256_file,
    write_jsonl,
    write_manifest,
)
from .preprocessing import PREPROCESSING_VERSION, PreprocessedText, preprocess


@dataclass(frozen=True)
class FeatureRow:
    """One sentence and the feature row produced from it."""

    id: str
    original: str
    canonical: str
    tokens: tuple[str, ...]
    intent: str
    parameters: tuple[str, ...]
    human_intent: str | None
    tags: tuple[str, ...]
    source: str

    def to_dict(self, vector: np.ndarray | None = None) -> dict[str, Any]:
        data: dict[str, Any] = {
            "id": self.id,
            "original": self.original,
            "canonical": self.canonical,
            "tokens": list(self.tokens),
            "intent": self.intent,
            "parameters": list(self.parameters),
            "humanIntent": self.human_intent,
            "tags": list(self.tags),
            "source": self.source,
        }
        if vector is not None:
            data["vector"] = [round(float(value), 6) for value in vector]
        return data


@dataclass(frozen=True)
class SkippedRow:
    id: str
    original: str
    reason: str


@dataclass(frozen=True)
class FeatureBuild:
    rows: tuple[FeatureRow, ...]
    matrix: np.ndarray
    skipped: tuple[SkippedRow, ...]
    manifest: dict[str, Any]


@dataclass(frozen=True)
class SkippedText:
    """An input that normalized to no text and therefore has no vector."""

    index: int
    original: str
    reason: str


@dataclass(frozen=True)
class TextFeatureBatch:
    """Preprocessed inputs and the corresponding feature matrix."""

    input_indices: tuple[int, ...]
    processed: tuple[PreprocessedText, ...]
    matrix: np.ndarray
    skipped: tuple[SkippedText, ...]


def _preprocess_texts(
    texts: Sequence[str],
) -> tuple[
    tuple[int, ...],
    tuple[PreprocessedText, ...],
    tuple[SkippedText, ...],
]:
    if not texts:
        raise EmptyTextError("no texts to preprocess")

    input_indices: list[int] = []
    processed: list[PreprocessedText] = []
    skipped: list[SkippedText] = []
    for index, original in enumerate(texts):
        value = preprocess(original)
        if value.is_empty:
            skipped.append(
                SkippedText(
                    index=index,
                    original=original,
                    reason="empty-canonical",
                )
            )
            continue
        input_indices.append(index)
        processed.append(value)

    if not processed:
        raise EmptyTextError(
            "every input preprocessed to an empty canonical string"
        )
    return tuple(input_indices), tuple(processed), tuple(skipped)


def prepare_rows(
    dataset: Sequence[DatasetRow],
) -> tuple[list[FeatureRow], list[SkippedRow]]:
    """Apply preprocessing and separate rows that have nothing to embed.

    A bare wake word ("walsey") or a punctuation-only transcript becomes an
    empty canonical string. Whisper would normally report
    ``SpeechNoSpeechDetected`` first, but the research dataset keeps such a row
    to prove the pipeline handles it honestly: it is skipped and recorded, not
    embedded as a zero vector.
    """

    input_indices, processed, skipped_texts = _preprocess_texts(
        [row.original for row in dataset]
    )
    rows = [
        FeatureRow(
            id=dataset[index].id,
            original=value.original,
            canonical=value.canonical,
            tokens=value.tokens,
            intent=dataset[index].intent,
            parameters=dataset[index].parameters,
            human_intent=dataset[index].human_intent,
            tags=dataset[index].tags,
            source=dataset[index].source,
        )
        for index, value in zip(input_indices, processed, strict=True)
    ]
    skipped = [
        SkippedRow(
            id=dataset[value.index].id,
            original=value.original,
            reason=value.reason,
        )
        for value in skipped_texts
    ]
    return rows, skipped


def transform_texts(
    texts: Sequence[str],
    extractor: FeatureExtractor,
) -> TextFeatureBatch:
    """Apply the shared preprocessing and feature extraction to raw text.

    Dataset construction and later inference should both enter through this
    function so that raw transcripts cannot accidentally bypass preprocessing.
    Empty canonical inputs are reported as skipped, never represented by a
    fabricated zero vector.
    """

    input_indices, processed, skipped = _preprocess_texts(texts)
    matrix = np.asarray(
        extractor.transform([value.canonical for value in processed]),
        dtype=np.float32,
    )
    expected = (len(processed), extractor.dimension)
    if matrix.shape != expected:
        raise FeatureExtractionError(
            f"extractor returned shape {matrix.shape}; expected {expected}"
        )
    if not np.isfinite(matrix).all():
        raise FeatureExtractionError("the feature matrix contains NaN or infinity")

    return TextFeatureBatch(
        input_indices=input_indices,
        processed=processed,
        matrix=matrix,
        skipped=skipped,
    )


def build(
    dataset: Sequence[DatasetRow],
    extractor: FeatureExtractor,
    *,
    dataset_path: Path,
    dataset_sha256: str | None = None,
    extra: dict[str, Any] | None = None,
) -> FeatureBuild:
    """Run preprocessing + extraction and build the run manifest."""

    batch = transform_texts(
        [row.original for row in dataset],
        extractor,
    )
    rows = [
        FeatureRow(
            id=dataset[index].id,
            original=value.original,
            canonical=value.canonical,
            tokens=value.tokens,
            intent=dataset[index].intent,
            parameters=dataset[index].parameters,
            human_intent=dataset[index].human_intent,
            tags=dataset[index].tags,
            source=dataset[index].source,
        )
        for index, value in zip(
            batch.input_indices,
            batch.processed,
            strict=True,
        )
    ]
    skipped = [
        SkippedRow(
            id=dataset[value.index].id,
            original=value.original,
            reason=value.reason,
        )
        for value in batch.skipped
    ]

    describe = getattr(extractor, "describe", None)
    if callable(describe):
        extractor_description = describe()
    else:  # pragma: no cover - both shipped extractors implement describe()
        extractor_description = {
            "name": extractor.name,
            "dimension": extractor.dimension,
        }

    manifest = build_manifest(
        preprocessing_version=PREPROCESSING_VERSION,
        extractor=extractor_description,
        dataset_path=dataset_path,
        dataset_sha256=dataset_sha256 or sha256_file(dataset_path),
        declared_rows=len(dataset),
        used_rows=len(rows),
        skipped_rows=len(skipped),
        matrix=batch.matrix,
        extra=extra,
    )
    return FeatureBuild(
        rows=tuple(rows),
        matrix=batch.matrix,
        skipped=tuple(skipped),
        manifest=manifest,
    )


def save(build_result: FeatureBuild, directory: Path) -> None:
    """Write ``features.npy``, ``features.jsonl``, ``skipped.jsonl``, manifest."""

    directory.mkdir(parents=True, exist_ok=True)
    save_matrix(directory / "features.npy", build_result.matrix)
    write_jsonl(
        directory / "features.jsonl",
        (
            row.to_dict(build_result.matrix[index])
            for index, row in enumerate(build_result.rows)
        ),
    )
    write_jsonl(
        directory / "skipped.jsonl",
        (
            {"id": row.id, "original": row.original, "reason": row.reason}
            for row in build_result.skipped
        ),
    )
    write_manifest(directory / "manifest.json", build_result.manifest)


@dataclass(frozen=True)
class LoadedBuild:
    rows: tuple[dict[str, Any], ...]
    matrix: np.ndarray
    manifest: dict[str, Any]


def load(directory: Path) -> LoadedBuild:
    """Read a saved build and check that rows and matrix agree."""

    manifest = load_manifest(directory / "manifest.json")
    matrix = load_matrix(directory / "features.npy")
    rows = tuple(
        data for _, data in read_jsonl(directory / "features.jsonl")
    )
    recorded_shape = manifest["matrix"]["shape"]
    if list(matrix.shape) != recorded_shape:
        raise FeatureExtractionError(
            f"features.npy shape {list(matrix.shape)} != manifest {recorded_shape}"
        )
    if len(rows) != matrix.shape[0]:
        raise FeatureExtractionError(
            f"features.jsonl has {len(rows)} rows but features.npy has "
            f"{matrix.shape[0]}"
        )
    return LoadedBuild(rows=rows, matrix=matrix, manifest=manifest)
