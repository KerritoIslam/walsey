"""File formats for the Phase 1 dataset, feature matrices and run manifests.

Everything written by this module is plain JSON/JSONL plus ``.npy`` so the
output can be inspected without importing this package. The manifest is the
reproduction contract: it records the preprocessing version, the embedding
model revision, the *verified* dimension and the library versions that produced
a matrix.
"""

from __future__ import annotations

import hashlib
import json
import platform
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from importlib import metadata
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence

import numpy as np

SCHEMA_VERSION = 1

#: Stable parser labels: every ``VoiceIntent.name`` plus the explicit
#: non-command label. The ML layer must never invent a label outside this set.
INTENT_LABELS: tuple[str, ...] = (
    "powerOn",
    "powerOff",
    "setColor",
    "setBrightness",
    "increaseBrightness",
    "decreaseBrightness",
    "applyEffect",
    "queryStatus",
    "unsupported",
)

KNOWN_INTENT_LABELS: tuple[str, ...] = tuple(
    label for label in INTENT_LABELS if label != "unsupported"
)

#: ``VoiceFailureKind.name`` values from ``walsey_voice_core``.
FAILURE_KINDS: tuple[str, ...] = (
    "emptyInput",
    "unsupported",
    "ambiguous",
    "missingParameter",
    "invalidParameter",
)


class DatasetError(ValueError):
    """The checked-in dataset does not match the documented schema."""


class ManifestError(ValueError):
    """A manifest is missing a required field or contradicts the run."""


@dataclass(frozen=True)
class DatasetRow:
    """One labeled example sentence.

    ``intent`` is the *authorized* parser outcome. A sentence the parser
    rejects is labeled ``unsupported`` even when a human would understand it;
    ``human_intent`` records that separate, non-executable reading.
    """

    id: str
    original: str
    source: str
    intent: str
    parser_accepts: bool
    parameters: tuple[str, ...]
    human_intent: str | None = None
    parser_failure_kind: str | None = None
    parser_intended_intent: str | None = None
    source_line: int | None = None
    corpus_negative: bool = False
    tags: tuple[str, ...] = ()
    notes: str | None = None

    @property
    def is_command(self) -> bool:
        return self.intent != "unsupported"

    @classmethod
    def from_dict(cls, data: dict[str, Any], *, where: str) -> "DatasetRow":
        required = (
            "id",
            "original",
            "source",
            "intent",
            "parameters",
        )
        missing = [key for key in required if key not in data]
        if missing:
            raise DatasetError(f"{where}: missing keys {missing}")

        row_id = data["id"]
        if not isinstance(row_id, str) or not row_id.strip():
            raise DatasetError(f"{where}: id must be a non-empty string")
        original = data["original"]
        if not isinstance(original, str):
            raise DatasetError(f"{where}: original must be a string")
        intent = data["intent"]
        if intent not in INTENT_LABELS:
            raise DatasetError(
                f"{where}: intent {intent!r} is not one of {INTENT_LABELS}"
            )

        parameters = data["parameters"]
        if not isinstance(parameters, list) or not all(
            isinstance(item, str) for item in parameters
        ):
            raise DatasetError(f"{where}: parameters must be a list of strings")
        if intent == "unsupported" and parameters:
            raise DatasetError(
                f"{where}: a rejected sentence cannot carry validated parameters"
            )

        human_intent = data.get("humanIntent")
        if human_intent is not None and human_intent not in KNOWN_INTENT_LABELS:
            raise DatasetError(
                f"{where}: humanIntent {human_intent!r} must be a known intent "
                "name or null"
            )

        failure_kind = data.get("parserFailureKind")
        if failure_kind is not None and failure_kind not in FAILURE_KINDS:
            raise DatasetError(
                f"{where}: parserFailureKind {failure_kind!r} is not one of "
                f"{FAILURE_KINDS}"
            )

        intended = data.get("parserIntendedIntent")
        if intended is not None and intended not in KNOWN_INTENT_LABELS:
            raise DatasetError(
                f"{where}: parserIntendedIntent {intended!r} must be a known "
                "intent name or null"
            )

        parser_accepts = intent != "unsupported"
        declared_accepts = data.get("parserAccepts", parser_accepts)
        if declared_accepts is not parser_accepts:
            raise DatasetError(
                f"{where}: parserAccepts={declared_accepts!r} contradicts "
                f"intent={intent!r}"
            )
        if parser_accepts and (failure_kind is not None or intended is not None):
            raise DatasetError(
                f"{where}: an accepted sentence cannot have a failure kind or "
                "an intended intent"
            )
        if not parser_accepts and failure_kind is None:
            raise DatasetError(
                f"{where}: a rejected sentence must record parserFailureKind"
            )

        source_line = data.get("sourceLine")
        if source_line is not None and not isinstance(source_line, int):
            raise DatasetError(f"{where}: sourceLine must be an int or null")

        tags = data.get("tags", [])
        if not isinstance(tags, list) or not all(
            isinstance(tag, str) for tag in tags
        ):
            raise DatasetError(f"{where}: tags must be a list of strings")

        corpus_negative = data.get("corpusNegative", False)
        if not isinstance(corpus_negative, bool):
            raise DatasetError(f"{where}: corpusNegative must be a boolean")

        notes = data.get("notes")
        if notes is not None and not isinstance(notes, str):
            raise DatasetError(f"{where}: notes must be a string or null")

        return cls(
            id=row_id,
            original=original,
            source=data["source"],
            intent=intent,
            parser_accepts=parser_accepts,
            parameters=tuple(parameters),
            human_intent=human_intent,
            parser_failure_kind=failure_kind,
            parser_intended_intent=intended,
            source_line=source_line,
            corpus_negative=corpus_negative,
            tags=tuple(tags),
            notes=notes,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "original": self.original,
            "source": self.source,
            "sourceLine": self.source_line,
            "corpusNegative": self.corpus_negative,
            "intent": self.intent,
            "parserAccepts": self.parser_accepts,
            "parserFailureKind": self.parser_failure_kind,
            "parserIntendedIntent": self.parser_intended_intent,
            "parameters": list(self.parameters),
            "humanIntent": self.human_intent,
            "tags": list(self.tags),
            "notes": self.notes,
        }


@dataclass(frozen=True)
class ParaphraseGroup:
    name: str
    intent: str
    sentences: tuple[str, ...]


@dataclass(frozen=True)
class ParameterPair:
    name: str
    left: str
    right: str
    expectation: str


def read_jsonl(path: Path) -> Iterator[tuple[int, dict[str, Any]]]:
    if not path.is_file():
        raise FileNotFoundError(f"no JSONL file at {path}")
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise DatasetError(
                    f"{path}:{line_number}: invalid JSON ({error.msg})"
                ) from error
            if not isinstance(value, dict):
                raise DatasetError(
                    f"{path}:{line_number}: expected a JSON object"
                )
            yield line_number, value


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False))
            handle.write("\n")
            count += 1
    return count


def load_dataset(path: Path) -> tuple[DatasetRow, ...]:
    """Load and validate the labeled example set."""

    rows: list[DatasetRow] = []
    seen: set[str] = set()
    for line_number, data in read_jsonl(path):
        row = DatasetRow.from_dict(data, where=f"{path}:{line_number}")
        if row.id in seen:
            raise DatasetError(f"{path}:{line_number}: duplicate id {row.id!r}")
        seen.add(row.id)
        rows.append(row)
    if not rows:
        raise DatasetError(f"{path}: the dataset is empty")
    return tuple(rows)


def load_paraphrase_groups(path: Path) -> tuple[ParaphraseGroup, ...]:
    if not path.is_file():
        raise FileNotFoundError(f"no paraphrase groups at {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    groups = data.get("groups")
    if not isinstance(groups, list) or not groups:
        raise DatasetError(f"{path}: expected a non-empty 'groups' list")
    loaded: list[ParaphraseGroup] = []
    for index, group in enumerate(groups):
        where = f"{path}:groups[{index}]"
        if not isinstance(group, dict):
            raise DatasetError(f"{where}: expected an object")
        name = group.get("name")
        intent = group.get("intent")
        sentences = group.get("sentences")
        if not isinstance(name, str) or not name:
            raise DatasetError(f"{where}: name must be a non-empty string")
        if intent not in KNOWN_INTENT_LABELS:
            raise DatasetError(f"{where}: intent {intent!r} is not a known intent")
        if (
            not isinstance(sentences, list)
            or len(sentences) < 2
            or not all(isinstance(sentence, str) for sentence in sentences)
        ):
            raise DatasetError(
                f"{where}: sentences must be a list of at least two strings"
            )
        loaded.append(
            ParaphraseGroup(
                name=name,
                intent=intent,
                sentences=tuple(sentences),
            )
        )
    return tuple(loaded)


def load_parameter_pairs(path: Path) -> tuple[ParameterPair, ...]:
    if not path.is_file():
        raise FileNotFoundError(f"no parameter pairs at {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    pairs = data.get("pairs")
    if not isinstance(pairs, list) or not pairs:
        raise DatasetError(f"{path}: expected a non-empty 'pairs' list")
    loaded: list[ParameterPair] = []
    for index, pair in enumerate(pairs):
        where = f"{path}:pairs[{index}]"
        if not isinstance(pair, dict):
            raise DatasetError(f"{where}: expected an object")
        name = pair.get("name")
        left = pair.get("left")
        right = pair.get("right")
        expectation = pair.get("expectation", "different")
        if not isinstance(name, str) or not name:
            raise DatasetError(f"{where}: name must be a non-empty string")
        if not isinstance(left, str) or not isinstance(right, str):
            raise DatasetError(f"{where}: left and right must be strings")
        if expectation not in {"different", "similar"}:
            raise DatasetError(
                f"{where}: expectation must be 'different' or 'similar'"
            )
        loaded.append(
            ParameterPair(
                name=name,
                left=left,
                right=right,
                expectation=expectation,
            )
        )
    return tuple(loaded)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _package_version(name: str) -> str | None:
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return None


def library_versions() -> dict[str, str | None]:
    """Record what produced a matrix, without importing the heavy packages."""

    return {
        "python": platform.python_version(),
        "implementation": platform.python_implementation(),
        "platform": platform.platform(),
        "numpy": _package_version("numpy"),
        "scipy": _package_version("scipy"),
        "scikit-learn": _package_version("scikit-learn"),
        "joblib": _package_version("joblib"),
        "torch": _package_version("torch"),
        "transformers": _package_version("transformers"),
        "sentence-transformers": _package_version("sentence-transformers"),
        "huggingface-hub": _package_version("huggingface-hub"),
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_manifest(
    *,
    preprocessing_version: str,
    extractor: dict[str, Any],
    dataset_path: Path,
    dataset_sha256: str,
    declared_rows: int,
    used_rows: int,
    skipped_rows: int,
    matrix: np.ndarray,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    manifest: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAtUtc": utc_now(),
        "preprocessing": {
            "version": preprocessing_version,
            "canonicalInput": "canonical text (see docs/voice_intent_ml.md)",
            "tokens": "exact port of walsey_voice_core normalizeCommandText",
            "wakeWordStripping": "leading hey/ok/okay then one 'walsey'",
        },
        "extractor": extractor,
        "dataset": {
            "path": dataset_path.as_posix(),
            "sha256": dataset_sha256,
            "declaredRows": declared_rows,
            "usedRows": used_rows,
            "skippedRows": skipped_rows,
            "rowOrder": (
                "dataset order; rows with an empty canonical text are skipped "
                "and recorded in skipped.jsonl"
            ),
        },
        "matrix": {
            "file": "features.npy",
            "shape": [int(matrix.shape[0]), int(matrix.shape[1])],
            "dtype": str(matrix.dtype),
            "normalization": "l2",
            "rows": "unit length except TF-IDF rows with no in-vocabulary token",
        },
        "libraryVersions": library_versions(),
    }
    if extra:
        manifest["extra"] = extra
    return manifest


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_manifest(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"no manifest at {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ManifestError(f"{path}: expected a JSON object")
    for key in ("schemaVersion", "preprocessing", "extractor", "dataset", "matrix"):
        if key not in data:
            raise ManifestError(f"{path}: missing {key!r}")
    if data["schemaVersion"] != SCHEMA_VERSION:
        raise ManifestError(
            f"{path}: schema version {data['schemaVersion']!r} is not "
            f"{SCHEMA_VERSION}"
        )
    return data


def assert_manifest_compatible(
    manifest: dict[str, Any],
    *,
    preprocessing_version: str,
    extractor_name: str,
    dimension: int,
) -> None:
    """Refuse to reuse a matrix built from a different contract."""

    from .features.base import FeatureManifestMismatch

    if manifest["preprocessing"]["version"] != preprocessing_version:
        raise FeatureManifestMismatch(
            "manifest preprocessing version "
            f"{manifest['preprocessing']['version']!r} != "
            f"{preprocessing_version!r}"
        )
    recorded_name = manifest["extractor"].get("model_id") or manifest[
        "extractor"
    ].get("name")
    if recorded_name != extractor_name:
        raise FeatureManifestMismatch(
            f"manifest extractor {recorded_name!r} != {extractor_name!r}"
        )
    recorded_dimension = manifest["extractor"].get("dimension")
    if recorded_dimension != dimension:
        raise FeatureManifestMismatch(
            f"manifest dimension {recorded_dimension!r} != {dimension!r}"
        )
    shape = manifest["matrix"]["shape"]
    if not isinstance(shape, list) or len(shape) != 2 or shape[1] != dimension:
        raise FeatureManifestMismatch(
            f"manifest matrix shape {shape!r} does not end in {dimension}"
        )


def save_matrix(path: Path, matrix: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    values = np.asarray(matrix, dtype=np.float32)
    np.save(path, values, allow_pickle=False)


def load_matrix(path: Path) -> np.ndarray:
    if not path.is_file():
        raise FileNotFoundError(f"no feature matrix at {path}")
    values = np.load(path, allow_pickle=False)
    if values.ndim != 2:
        raise ManifestError(f"{path}: expected a 2-D matrix")
    return values.astype(np.float32, copy=False)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def relative(path: Path, start: Path) -> str:
    try:
        return path.resolve().relative_to(start.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def summarise_label_counts(rows: Sequence[DatasetRow]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.intent] = counts.get(row.intent, 0) + 1
    return dict(sorted(counts.items()))


def python_environment() -> dict[str, str | None]:
    return {
        "python": sys.version.split()[0],
        "executable": sys.executable,
    }
