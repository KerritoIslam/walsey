"""Phase 1 verification: structural invariants plus honest quality metrics.

There is deliberately no pass/fail threshold on similarity quality. The
example set is small and unbalanced; arbitrary thresholds would be theatre.
What *is* enforced is structural: shape, dtype, finiteness, unit length, the
manifest agreeing with the matrix, and the preprocessing version. Quality
numbers are measured, printed and recorded in ``docs/voice_intent_ml.md``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from itertools import combinations
from typing import Any, Iterable, Sequence

import numpy as np

from .features.base import FeatureExtractionError
from .io import DatasetError, ParameterPair, ParaphraseGroup, KNOWN_INTENT_LABELS
from .pipeline import LoadedBuild
from .preprocessing import PREPROCESSING_VERSION, preprocess


@dataclass(frozen=True)
class PairStats:
    pairs: int
    mean: float | None
    minimum: float | None
    maximum: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "pairs": self.pairs,
            "mean": self.mean,
            "min": self.minimum,
            "max": self.maximum,
        }


def _stats(values: Sequence[float]) -> PairStats:
    if not values:
        return PairStats(pairs=0, mean=None, minimum=None, maximum=None)
    return PairStats(
        pairs=len(values),
        mean=float(np.mean(values)),
        minimum=float(np.min(values)),
        maximum=float(np.max(values)),
    )


def cosine_matrix(matrix: np.ndarray) -> np.ndarray:
    """Cosine similarity for already L2-normalized rows.

    Zero rows (TF-IDF with no in-vocabulary token) yield ``0`` against every
    row, which is the honest meaning of "no shared vocabulary".
    """

    values = np.asarray(matrix, dtype=np.float32)
    similarities = values @ values.T
    return np.clip(similarities, -1.0, 1.0).astype(np.float32)


def _label_groups(
    intents: Sequence[str],
) -> dict[str, list[int]]:
    groups: dict[str, list[int]] = {}
    for index, intent in enumerate(intents):
        groups.setdefault(intent, []).append(index)
    return groups


def similarity_stats(
    similarities: np.ndarray,
    intents: Sequence[str],
) -> dict[str, Any]:
    groups = _label_groups(intents)
    within_known: list[float] = []
    per_label: dict[str, PairStats] = {}
    for label in KNOWN_INTENT_LABELS:
        indices = groups.get(label, [])
        values = [
            float(similarities[i, j]) for i, j in combinations(indices, 2)
        ]
        per_label[label] = _stats(values)
        within_known.extend(values)

    known_indices = [
        index
        for label in KNOWN_INTENT_LABELS
        for index in groups.get(label, [])
    ]
    across_known: list[float] = []
    for left, right in combinations(known_indices, 2):
        if intents[left] != intents[right]:
            across_known.append(float(similarities[left, right]))

    unsupported = groups.get("unsupported", [])
    unsupported_within = [
        float(similarities[i, j]) for i, j in combinations(unsupported, 2)
    ]
    unsupported_vs_known = [
        float(similarities[i, j]) for i in unsupported for j in known_indices
    ]

    same = _stats(within_known)
    different = _stats(across_known)
    separation = (
        None
        if same.mean is None or different.mean is None
        else same.mean - different.mean
    )
    return {
        "sameIntent": same.to_dict(),
        "differentIntent": different.to_dict(),
        "separation": separation,
        "perLabel": {label: stats.to_dict() for label, stats in per_label.items()},
        "unsupportedWithin": _stats(unsupported_within).to_dict(),
        "unsupportedVsKnown": _stats(unsupported_vs_known).to_dict(),
    }


def _lookup(
    rows: Sequence[dict[str, Any]],
) -> tuple[dict[str, int], dict[str, int]]:
    """Index rows by original string and by canonical text.

    The original lookup keeps duplicate canonicals distinguishable; the
    canonical lookup lets a group sentence that differs only in punctuation or
    capitalisation still resolve to its row.
    """

    by_original: dict[str, int] = {}
    by_canonical: dict[str, int] = {}
    for index, row in enumerate(rows):
        by_original.setdefault(str(row["original"]), index)
        canonical = str(row.get("canonical") or preprocess(str(row["original"])).canonical)
        by_canonical.setdefault(canonical, index)
    return by_original, by_canonical


def _resolve(
    sentence: str,
    rows: Sequence[dict[str, Any]],
    by_original: dict[str, int],
    by_canonical: dict[str, int],
) -> int | None:
    if sentence in by_original:
        return by_original[sentence]
    canonical = preprocess(sentence).canonical
    return by_canonical.get(canonical)


def paraphrase_results(
    similarities: np.ndarray,
    rows: Sequence[dict[str, Any]],
    groups: Sequence[ParaphraseGroup],
) -> list[dict[str, Any]]:
    by_original, by_canonical = _lookup(rows)
    results: list[dict[str, Any]] = []
    for group in groups:
        indices: list[int] = []
        missing: list[str] = []
        for sentence in group.sentences:
            index = _resolve(sentence, rows, by_original, by_canonical)
            if index is None:
                missing.append(sentence)
            else:
                indices.append(index)
        values = [
            float(similarities[i, j]) for i, j in combinations(indices, 2)
        ]
        stats = _stats(values)
        results.append(
            {
                "name": group.name,
                "intent": group.intent,
                "sentences": list(group.sentences),
                "resolved": [str(rows[i]["id"]) for i in indices],
                "missing": missing,
                "similarity": stats.to_dict(),
            }
        )
    return results


def parameter_pair_results(
    similarities: np.ndarray,
    rows: Sequence[dict[str, Any]],
    pairs: Sequence[ParameterPair],
) -> list[dict[str, Any]]:
    by_original, by_canonical = _lookup(rows)
    results: list[dict[str, Any]] = []
    for pair in pairs:
        left = _resolve(pair.left, rows, by_original, by_canonical)
        right = _resolve(pair.right, rows, by_original, by_canonical)
        record: dict[str, Any] = {
            "name": pair.name,
            "left": pair.left,
            "right": pair.right,
            "expectation": pair.expectation,
            "cosine": None,
            "missing": [],
        }
        if left is None:
            record["missing"].append(pair.left)
        if right is None:
            record["missing"].append(pair.right)
        if left is not None and right is not None:
            record["cosine"] = float(similarities[left, right])
            record["leftId"] = str(rows[left]["id"])
            record["rightId"] = str(rows[right]["id"])
        results.append(record)
    return results


def nearest_neighbours(
    similarities: np.ndarray,
    rows: Sequence[dict[str, Any]],
    *,
    top_k: int = 5,
) -> dict[str, list[dict[str, Any]]]:
    neighbours: dict[str, list[dict[str, Any]]] = {}
    count = len(rows)
    for index, row in enumerate(rows):
        scores = similarities[index].copy()
        scores[index] = -np.inf
        order = np.argsort(-scores)[: min(top_k, count - 1)]
        neighbours[str(row["id"])] = [
            {
                "id": str(rows[int(other)]["id"]),
                "original": str(rows[int(other)]["original"]),
                "intent": str(rows[int(other)]["intent"]),
                "cosine": float(scores[int(other)]),
            }
            for other in order
        ]
    return neighbours


def duplicate_canonicals(rows: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        canonical = str(row.get("canonical") or "")
        groups.setdefault(canonical, []).append(
            {"id": str(row["id"]), "original": str(row["original"])}
        )
    return [
        {"canonical": canonical, "rows": items}
        for canonical, items in groups.items()
        if len(items) > 1
    ]


def _norm_summary(matrix: np.ndarray) -> dict[str, Any]:
    norms = np.linalg.norm(matrix, axis=1)
    return {
        "min": float(np.min(norms)),
        "max": float(np.max(norms)),
        "unitRows": int(np.sum(np.isclose(norms, 1.0, atol=1e-5))),
        "zeroRows": int(np.sum(norms == 0)),
        "rows": int(norms.size),
    }


def assert_structural_invariants(
    loaded: LoadedBuild,
    *,
    expected_preprocessing_version: str = PREPROCESSING_VERSION,
) -> dict[str, Any]:
    matrix = loaded.matrix
    manifest = loaded.manifest
    if matrix.dtype != np.float32:
        raise FeatureExtractionError(
            f"feature matrix dtype is {matrix.dtype}; expected float32"
        )
    if matrix.ndim != 2:
        raise FeatureExtractionError(
            f"feature matrix rank is {matrix.ndim}; expected 2"
        )
    if not np.isfinite(matrix).all():
        raise FeatureExtractionError("the feature matrix contains NaN or infinity")
    recorded_shape = manifest["matrix"]["shape"]
    if list(matrix.shape) != recorded_shape:
        raise FeatureExtractionError(
            f"matrix shape {list(matrix.shape)} != manifest {recorded_shape}"
        )
    dimension = manifest["extractor"].get("dimension")
    if dimension != matrix.shape[1]:
        raise FeatureExtractionError(
            f"manifest dimension {dimension!r} != matrix width {matrix.shape[1]}"
        )
    if manifest["preprocessing"]["version"] != expected_preprocessing_version:
        raise FeatureExtractionError(
            "manifest preprocessing version "
            f"{manifest['preprocessing']['version']!r} != "
            f"{expected_preprocessing_version!r}"
        )
    norms = np.linalg.norm(matrix, axis=1)
    zero_rows = norms == 0
    if not np.allclose(norms[~zero_rows], 1.0, atol=1e-5):
        raise FeatureExtractionError(
            "some non-zero feature rows are not unit length"
        )
    allow_zero = bool(manifest.get("extra", {}).get("allowZeroRows", False))
    if zero_rows.any() and not allow_zero:
        raise FeatureExtractionError(
            f"{int(zero_rows.sum())} feature rows are all zeros"
        )
    return {
        "shape": [int(matrix.shape[0]), int(matrix.shape[1])],
        "dtype": str(matrix.dtype),
        "norms": _norm_summary(matrix),
        "preprocessingVersion": manifest["preprocessing"]["version"],
    }


@dataclass(frozen=True)
class VerificationReport:
    summary: dict[str, Any]
    rows: Sequence[dict[str, Any]]
    similarities: np.ndarray = field(repr=False)
    neighbours: dict[str, list[dict[str, Any]]]
    paraphrase: list[dict[str, Any]]
    parameter_pairs: list[dict[str, Any]]
    duplicates: list[dict[str, Any]]
    timing: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "summary": self.summary,
            "rows": [
                {
                    "id": row.get("id"),
                    "original": row.get("original"),
                    "canonical": row.get("canonical"),
                    "intent": row.get("intent"),
                    "humanIntent": row.get("humanIntent"),
                    "parameters": row.get("parameters"),
                }
                for row in self.rows
            ],
            "nearestNeighbours": self.neighbours,
            "paraphraseGroups": self.paraphrase,
            "parameterPairs": self.parameter_pairs,
            "duplicateCanonicals": self.duplicates,
        }
        if self.timing is not None:
            data["timing"] = self.timing
        return data

    def to_text(self) -> str:
        summary = self.summary
        matrix = summary["matrix"]
        stats = summary["similarity"]
        lines: list[str] = []
        lines.append("Walsey voice intent — Phase 1 feature verification")
        lines.append("=" * 56)
        lines.append("")
        lines.append(f"extractor          : {summary['extractorName']}")
        lines.append(f"model id           : {summary['modelId']}")
        lines.append(f"model revision     : {summary['revision']}")
        lines.append(f"preprocessing      : {summary['preprocessingVersion']}")
        lines.append(f"dataset sha256     : {summary['datasetSha256']}")
        lines.append(
            f"matrix             : {matrix['shape'][0]} x {matrix['shape'][1]} "
            f"({matrix['dtype']})"
        )
        lines.append(
            f"rows               : {matrix['norms']['unitRows']} unit, "
            f"{matrix['norms']['zeroRows']} zero"
        )
        lines.append("")
        lines.append("Label counts")
        lines.append("-" * 56)
        for label, count in summary["labelCounts"].items():
            lines.append(f"  {label:<22} {count:>4}")
        lines.append("")
        lines.append("Cosine similarity (unit rows)")
        lines.append("-" * 56)
        for key, label in (
            ("sameIntent", "same known intent"),
            ("differentIntent", "different known intent"),
            ("unsupportedWithin", "both unsupported"),
            ("unsupportedVsKnown", "unsupported vs known"),
        ):
            entry = stats[key]
            if entry["mean"] is None:
                lines.append(f"  {label:<24} n/a")
            else:
                lines.append(
                    f"  {label:<24} mean {entry['mean']:+.4f}  "
                    f"min {entry['min']:+.4f}  max {entry['max']:+.4f}  "
                    f"(n={entry['pairs']})"
                )
        if stats["separation"] is not None:
            lines.append(
                f"  {'separation':<24} {stats['separation']:+.4f} "
                "(same - different)"
            )
        lines.append("")
        lines.append("Per-intent within-label cosine")
        lines.append("-" * 56)
        for label, entry in stats["perLabel"].items():
            if entry["pairs"] == 0:
                lines.append(f"  {label:<22} n/a (fewer than 2 rows)")
            else:
                lines.append(
                    f"  {label:<22} mean {entry['mean']:+.4f}  "
                    f"min {entry['min']:+.4f}  max {entry['max']:+.4f}  "
                    f"(n={entry['pairs']})"
                )
        lines.append("")
        lines.append("Paraphrase groups (expected: high cosine)")
        lines.append("-" * 56)
        for group in self.paraphrase:
            entry = group["similarity"]
            if group["missing"]:
                missing = "; ".join(group["missing"])
                lines.append(
                    f"  {group['name']:<22} MISSING {missing}"
                )
                continue
            if entry["pairs"] == 0:
                lines.append(f"  {group['name']:<22} n/a (single row)")
                continue
            lines.append(
                f"  {group['name']:<22} mean {entry['mean']:+.4f}  "
                f"min {entry['min']:+.4f}  max {entry['max']:+.4f}  "
                f"(n={entry['pairs']})"
            )
        lines.append("")
        lines.append("Parameter pairs (does the vector separate the value?)")
        lines.append("-" * 56)
        for pair in self.parameter_pairs:
            if pair["cosine"] is None:
                missing = "; ".join(pair["missing"])
                lines.append(f"  {pair['name']:<30} MISSING {missing}")
                continue
            lines.append(
                f"  {pair['name']:<30} cosine {pair['cosine']:+.4f} "
                f"(expect {pair['expectation']})"
            )
        lines.append("")
        lines.append("Nearest neighbour with a different label")
        lines.append("-" * 56)
        by_id = {str(row["id"]): row for row in self.rows}
        shown = 0
        for row_id, neighbours in self.neighbours.items():
            row = by_id[row_id]
            other = next(
                (item for item in neighbours if item["intent"] != row["intent"]),
                None,
            )
            if other is None:
                continue
            lines.append(
                f"  {row['intent']:<18} {row['original']!r}"
            )
            lines.append(
                f"      -> {other['intent']:<18} {other['original']!r} "
                f"({other['cosine']:+.4f})"
            )
            shown += 1
            if shown >= 12:
                break
        if shown == 0:
            lines.append("  none: every nearest neighbour shares its label")
        lines.append("")
        lines.append("Notes")
        lines.append("-" * 56)
        lines.append(
            "  These numbers describe a small example set, not a trained "
            "classifier."
        )
        lines.append(
            "  Sentence embeddings are expected to blur polarity and exact "
            "numbers; the tables above measure that."
        )
        if self.duplicates:
            lines.append(
                f"  {len(self.duplicates)} canonical text(s) appear more than "
                "once (see report.json)."
            )
        if self.timing:
            lines.append(
                f"  encode timing: {self.timing.get('summary', 'see report.json')}"
            )
        return "\n".join(lines) + "\n"


def verify(
    loaded: LoadedBuild,
    *,
    groups: Sequence[ParaphraseGroup] = (),
    pairs: Sequence[ParameterPair] = (),
    top_k: int = 5,
    expected_preprocessing_version: str = PREPROCESSING_VERSION,
    timing: dict[str, Any] | None = None,
) -> VerificationReport:
    invariants = assert_structural_invariants(
        loaded,
        expected_preprocessing_version=expected_preprocessing_version,
    )
    rows = loaded.rows
    intents = [str(row["intent"]) for row in rows]
    similarities = cosine_matrix(loaded.matrix)
    manifest = loaded.manifest
    counts: dict[str, int] = {}
    for intent in intents:
        counts[intent] = counts.get(intent, 0) + 1
    summary: dict[str, Any] = {
        "extractorName": manifest["extractor"].get("name")
        or manifest["extractor"].get("model_id"),
        "modelId": manifest["extractor"].get("model_id"),
        "revision": manifest["extractor"].get("revision"),
        "preprocessingVersion": invariants["preprocessingVersion"],
        "datasetSha256": manifest["dataset"]["sha256"],
        "datasetRows": manifest["dataset"]["declaredRows"],
        "usedRows": manifest["dataset"]["usedRows"],
        "skippedRows": manifest["dataset"]["skippedRows"],
        "matrix": {
            "shape": invariants["shape"],
            "dtype": invariants["dtype"],
            "norms": invariants["norms"],
        },
        "labelCounts": dict(sorted(counts.items())),
        "similarity": similarity_stats(similarities, intents),
    }
    duplicates = duplicate_canonicals(rows)
    if duplicates:
        summary["duplicateCanonicals"] = len(duplicates)
    if not all(
        isinstance(label, str) for label in counts
    ):  # pragma: no cover - defensive
        raise DatasetError("every row must carry a string intent label")
    return VerificationReport(
        summary=summary,
        rows=rows,
        similarities=similarities,
        neighbours=nearest_neighbours(similarities, rows, top_k=top_k),
        paraphrase=paraphrase_results(similarities, rows, groups),
        parameter_pairs=parameter_pair_results(similarities, rows, pairs),
        duplicates=duplicates,
        timing=timing,
    )


def format_seconds(seconds: float) -> str:
    if seconds < 1e-3:
        return f"{seconds * 1e6:.0f} us"
    if seconds < 1.0:
        return f"{seconds * 1e3:.2f} ms"
    return f"{seconds:.2f} s"


def summarise_timings(per_row: Sequence[float]) -> dict[str, Any]:
    if not per_row:
        return {}
    values = np.asarray(per_row, dtype=np.float64)
    return {
        "rows": int(values.size),
        "totalSeconds": float(values.sum()),
        "meanSeconds": float(values.mean()),
        "medianSeconds": float(np.median(values)),
        "p95Seconds": float(np.percentile(values, 95)),
        "summary": (
            f"median {format_seconds(float(np.median(values)))} per sentence, "
            f"p95 {format_seconds(float(np.percentile(values, 95)))}"
        ),
    }


def compare_reports(
    reports: Sequence[tuple[str, dict[str, Any]]],
) -> str:
    """Compare saved ``report.json`` documents (one per model)."""

    lines = ["Model comparison (Phase 1 example set)", "=" * 56]
    header = f"{'metric':<28}" + "".join(
        f"{name:>18}" for name, _ in reports
    )
    lines.append(header)
    lines.append("-" * len(header))

    def cell(value: float | None) -> str:
        return "n/a" if value is None else f"{value:+.4f}"

    rows: list[tuple[str, list[float | None]]] = []
    rows.append(
        (
            "dimension",
            [
                float(report["summary"]["matrix"]["shape"][1])
                for _, report in reports
            ],
        )
    )
    for key, label in (
        ("sameIntent", "same-intent cosine"),
        ("differentIntent", "different-intent cosine"),
        ("unsupportedVsKnown", "unsupported-vs-known"),
    ):
        rows.append(
            (
                label,
                [
                    report["summary"]["similarity"][key]["mean"]
                    for _, report in reports
                ],
            )
        )
    rows.append(
        (
            "separation",
            [
                report["summary"]["similarity"]["separation"]
                for _, report in reports
            ],
        )
    )

    group_names = sorted(
        {
            group["name"]
            for _, report in reports
            for group in report.get("paraphraseGroups", [])
        }
    )
    for name in group_names:
        values: list[float | None] = []
        for _, report in reports:
            match = next(
                (
                    group
                    for group in report.get("paraphraseGroups", [])
                    if group["name"] == name
                ),
                None,
            )
            values.append(
                None
                if match is None
                else match["similarity"]["mean"]
            )
        rows.append((f"group: {name}", values))

    for label, values in rows:
        if label == "dimension":
            rendered = "".join(
                f"{'n/a' if value is None else int(value):>18}"
                for value in values
            )
        else:
            rendered = "".join(f"{cell(value):>18}" for value in values)
        lines.append(f"{label:<28}{rendered}")

    lines.append("")
    lines.append("Timing (per-sentence encode, from report.json)")
    lines.append("-" * 56)
    for name, report in reports:
        timing = report.get("timing")
        if not timing:
            lines.append(f"  {name:<20} n/a")
            continue
        lines.append(f"  {name:<20} {timing.get('summary', 'n/a')}")
    return "\n".join(lines) + "\n"


def top_paraphrase_failures(
    report: dict[str, Any],
    *,
    threshold: float = 0.8,
) -> list[dict[str, Any]]:
    """Groups whose mean cosine is below ``threshold`` (documentation aid)."""

    failures: list[dict[str, Any]] = []
    for group in report.get("paraphraseGroups", []):
        mean = group["similarity"]["mean"]
        if mean is not None and not math.isnan(mean) and mean < threshold:
            failures.append(group)
    return failures
