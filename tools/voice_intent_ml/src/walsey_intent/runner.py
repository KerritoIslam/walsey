"""Build and verify one Phase 1 feature run.

The runner is the only place that knows about the tool's directory layout. It
keeps the CLI and the wrapper scripts thin and makes every step callable from a
test without spawning a process.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from . import pipeline
from .features.base import FeatureExtractionError, FeatureExtractor
from .features.sentence_transformer import (
    SentenceTransformerBackend,
    SentenceTransformerExtractor,
)
from .features.tfidf import TfidfExtractor
from .io import (
    DatasetRow,
    load_dataset,
    load_matrix,
    load_paraphrase_groups,
    load_parameter_pairs,
    write_json,
    write_text,
)
from .models import CATALOGUE, DEFAULT_MODEL, EmbeddingModelSpec, get_model_spec
from .preprocessing import PREPROCESSING_VERSION
from .verify import VerificationReport, compare_reports, summarise_timings, verify

TOOL_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = TOOL_ROOT.parents[1]

DEFAULT_DATASET = TOOL_ROOT / "data" / "phase1_commands.jsonl"
DEFAULT_GROUPS = TOOL_ROOT / "data" / "paraphrase_groups.json"
DEFAULT_PAIRS = TOOL_ROOT / "data" / "parameter_pairs.json"
DEFAULT_MODELS_DIR = TOOL_ROOT / ".models"
DEFAULT_OUT_DIR = TOOL_ROOT / "out" / "phase1"
DEFAULT_GOLDEN = TOOL_ROOT / "testdata" / "preprocessing_golden.jsonl"

TFIDF_KEY = "tfidf"


def model_choices() -> tuple[str, ...]:
    return (*CATALOGUE.keys(), TFIDF_KEY)


def model_directory_name(key: str) -> str:
    return key


def run_directory(model_key: str, out_dir: Path = DEFAULT_OUT_DIR) -> Path:
    return out_dir / model_directory_name(model_key)


def _installed_revision(path: Path) -> str | None:
    manifest = path / "model_manifest.json"
    if not manifest.is_file():
        return None
    data = json.loads(manifest.read_text(encoding="utf-8"))
    revision = data.get("revision")
    return revision if isinstance(revision, str) else None


def load_sentence_transformer(
    model_key: str,
    *,
    models_dir: Path = DEFAULT_MODELS_DIR,
    batch_size: int = 32,
) -> tuple[EmbeddingModelSpec, SentenceTransformerExtractor, str]:
    """Load one explicitly fetched model from disk.

    Raises if the model is missing, if its on-disk revision disagrees with the
    pinned catalogue, or if the catalogue revision is still ``None``. Phase 1
    must never silently embed with an unpinned model.
    """

    spec = get_model_spec(model_key)
    path = models_dir / spec.key
    installed = _installed_revision(path)
    if spec.revision is None:
        raise FeatureExtractionError(
            f"{spec.model_id} has no pinned revision in models.py. Run "
            f"scripts/fetch_model.py --model {spec.key}, then record the "
            "resolved SHA in the catalogue before building features."
        )
    if installed is not None and installed != spec.revision:
        raise FeatureExtractionError(
            f"{spec.model_id}: on-disk revision {installed} != pinned "
            f"{spec.revision}. Refusing to mix model versions."
        )
    backend = SentenceTransformerBackend.from_local_path(path, spec)
    extractor = SentenceTransformerExtractor(backend, batch_size=batch_size)
    return spec, extractor, installed or spec.revision


def _extractor_description(extractor: FeatureExtractor) -> dict[str, Any]:
    describe = getattr(extractor, "describe", None)
    if callable(describe):
        return describe()
    return {"name": extractor.name, "dimension": extractor.dimension}


def _measure_timing(
    extractor: FeatureExtractor,
    texts: Sequence[str],
    *,
    repeats: int = 1,
) -> dict[str, Any]:
    """Time single-sentence encoding, which is the production call shape."""

    per_row: list[float] = []
    count = max(1, repeats)
    for text in texts:
        for _ in range(count):
            started = time.perf_counter()
            extractor.transform([text])
            per_row.append(time.perf_counter() - started)
    summary = summarise_timings(per_row)
    summary["repeats"] = count
    return summary


def build_features(
    model_key: str,
    *,
    dataset_path: Path = DEFAULT_DATASET,
    models_dir: Path = DEFAULT_MODELS_DIR,
    out_dir: Path = DEFAULT_OUT_DIR,
    batch_size: int = 32,
    measure_timing: bool = True,
) -> tuple[Path, pipeline.FeatureBuild]:
    """Preprocess the dataset, extract features and save one run directory."""

    dataset = load_dataset(dataset_path)
    extra: dict[str, Any] = {"allowZeroRows": False}

    if model_key == TFIDF_KEY:
        extractor = TfidfExtractor()
        prepared, _ = pipeline.prepare_rows(dataset)
        extractor.fit([row.canonical for row in prepared])
        extra = {
            "allowZeroRows": True,
            "extractorKind": "baseline",
            "note": (
                "TF-IDF is fitted on this example set for comparison only; "
                "it is not a leakage-safe classifier evaluation."
            ),
        }
        revision = None
        model_id = extractor.name
    else:
        spec, extractor, revision = load_sentence_transformer(
            model_key,
            models_dir=models_dir,
            batch_size=batch_size,
        )
        model_id = spec.model_id
        extra = {
            "allowZeroRows": False,
            "extractorKind": "sentence-transformer",
            "modelKey": spec.key,
            "modelId": spec.model_id,
            "revision": revision,
            "batchSize": batch_size,
        }

    if _extractor_description(extractor).get("dimension") is None:
        raise FeatureExtractionError(
            "the extractor did not report a verified dimension"
        )

    build = pipeline.build(
        dataset,
        extractor,
        dataset_path=dataset_path,
        extra=extra,
    )
    directory = run_directory(model_key, out_dir)
    pipeline.save(build, directory)
    if isinstance(extractor, TfidfExtractor):
        extractor.save(directory)

    timing = None
    if measure_timing:
        timing = _measure_timing(
            extractor,
            [row.canonical for row in build.rows],
        )
        timing["model"] = model_id
        timing["dimension"] = build.matrix.shape[1]
        write_json(directory / "timing.json", timing)
    return directory, build


def verify_run(
    run_dir: Path,
    *,
    groups_path: Path = DEFAULT_GROUPS,
    pairs_path: Path = DEFAULT_PAIRS,
    top_k: int = 5,
) -> VerificationReport:
    loaded = pipeline.load(run_dir)
    groups = (
        load_paraphrase_groups(groups_path) if groups_path.is_file() else ()
    )
    pairs = load_parameter_pairs(pairs_path) if pairs_path.is_file() else ()
    timing_path = run_dir / "timing.json"
    timing = (
        json.loads(timing_path.read_text(encoding="utf-8"))
        if timing_path.is_file()
        else None
    )
    report = verify(
        loaded,
        groups=groups,
        pairs=pairs,
        top_k=top_k,
        expected_preprocessing_version=PREPROCESSING_VERSION,
        timing=timing,
    )
    write_json(run_dir / "report.json", report.to_dict())
    write_text(run_dir / "report.txt", report.to_text())
    return report


def discover_runs(out_dir: Path = DEFAULT_OUT_DIR) -> list[Path]:
    if not out_dir.is_dir():
        return []
    return sorted(
        path
        for path in out_dir.iterdir()
        if path.is_dir()
        and (path / "manifest.json").is_file()
        and (path / "features.npy").is_file()
    )


def compare_runs(out_dir: Path = DEFAULT_OUT_DIR) -> str:
    reports: list[tuple[str, dict[str, Any]]] = []
    for directory in discover_runs(out_dir):
        report_path = directory / "report.json"
        if not report_path.is_file():
            verify_run(directory)
        reports.append(
            (
                directory.name,
                json.loads(report_path.read_text(encoding="utf-8")),
            )
        )
    if not reports:
        raise FeatureExtractionError(
            f"no feature runs under {out_dir}; run build_features.py first"
        )
    comparison = compare_reports(reports)
    write_text(out_dir / "comparison.txt", comparison)
    return comparison


def matrix_fingerprint(path: Path) -> dict[str, Any]:
    values = load_matrix(path)
    return {
        "shape": list(values.shape),
        "dtype": str(values.dtype),
        "bytes": int(values.nbytes),
        "sum": float(values.astype(np.float64).sum()),
        "absSum": float(np.abs(values.astype(np.float64)).sum()),
    }
