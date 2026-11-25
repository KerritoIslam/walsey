"""Command line entry point for legacy transcript-text experiments.

Use ``scripts/extract_log_mel.py`` for the raw-audio Phase 1 path.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from .features.base import FeatureExtractionError
from .golden import write_golden
from .io import DatasetError, ManifestError
from .models import CATALOGUE, DEFAULT_MODEL
from .runner import (
    DEFAULT_DATASET,
    DEFAULT_GOLDEN,
    DEFAULT_GROUPS,
    DEFAULT_MODELS_DIR,
    DEFAULT_OUT_DIR,
    DEFAULT_PAIRS,
    TFIDF_KEY,
    build_features,
    compare_runs,
    discover_runs,
    model_choices,
    run_directory,
    verify_run,
)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="walsey-intent",
        description=(
            "Legacy transcript-text feature experiments. For direct acoustic "
            "features, use scripts/extract_log_mel.py. Never executes a command."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser(
        "build-features",
        help="preprocess the dataset and save one feature run",
    )
    build.add_argument(
        "--model",
        required=True,
        choices=model_choices(),
        help=(
            f"{TFIDF_KEY} baseline or one of: "
            f"{', '.join(CATALOGUE)} (default: {DEFAULT_MODEL})"
        ),
    )
    build.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    build.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR)
    build.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    build.add_argument("--batch-size", type=int, default=32)
    build.add_argument(
        "--no-timing",
        action="store_true",
        help="skip per-sentence encode timing",
    )

    verify = sub.add_parser(
        "verify",
        help="check invariants and write report.json/report.txt",
    )
    verify.add_argument(
        "--run-dir",
        type=Path,
        action="append",
        default=None,
        help="run directory; omit to verify every run under --out-dir",
    )
    verify.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    verify.add_argument("--groups", type=Path, default=DEFAULT_GROUPS)
    verify.add_argument("--pairs", type=Path, default=DEFAULT_PAIRS)
    verify.add_argument("--top-k", type=int, default=5)

    compare = sub.add_parser(
        "compare",
        help="compare saved reports across models",
    )
    compare.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)

    golden = sub.add_parser(
        "build-golden",
        help="write the cross-language preprocessing fixture",
    )
    golden.add_argument("--out", type=Path, default=DEFAULT_GOLDEN)

    sub.add_parser("list-models", help="print the pinned model catalogue")
    return parser


def _print_build(directory: Path, build: object, model_key: str) -> None:
    build = build  # type: ignore[assignment]
    manifest = json.loads(
        (directory / "manifest.json").read_text(encoding="utf-8")
    )
    shape = manifest["matrix"]["shape"]
    extractor = manifest["extractor"]
    revision = extractor.get("revision")
    print(f"model      : {model_key}")
    print(f"extractor  : {extractor.get('model_id') or extractor.get('name')}")
    print(f"revision   : {revision if revision is not None else 'n/a (baseline)'}")
    print(f"dimension  : {shape[1]} (verified from the extractor)")
    print(f"matrix     : {shape[0]} rows x {shape[1]}")
    print(f"dataset    : {manifest['dataset']['declaredRows']} declared, "
          f"{manifest['dataset']['usedRows']} used, "
          f"{manifest['dataset']['skippedRows']} skipped")
    print(f"directory  : {directory}")
    print(f"manifest   : {directory / 'manifest.json'}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "list-models":
            for key, spec in CATALOGUE.items():
                revision = spec.revision or "UNPINNED (run fetch_model.py)"
                print(f"{key}")
                print(f"  model id  : {spec.model_id}")
                print(f"  revision  : {revision}")
                print(f"  dimension : {spec.expected_dimension} (verified on load)")
                print(f"  max tokens: {spec.max_seq_length}")
                print(f"  licence   : {spec.license}")
                print(f"  size      : ~{spec.approx_size_mb} MB")
            print(f"{TFIDF_KEY}")
            print("  model id  : scikit-learn TfidfVectorizer (fitted on the corpus)")
            print("  dimension : corpus vocabulary size")
            return 0

        if args.command == "build-features":
            directory, build = build_features(
                args.model,
                dataset_path=args.dataset,
                models_dir=args.models_dir,
                out_dir=args.out_dir,
                batch_size=args.batch_size,
                measure_timing=not args.no_timing,
            )
            _print_build(directory, build, args.model)
            return 0

        if args.command == "verify":
            directories = (
                [path for path in args.run_dir]
                if args.run_dir
                else discover_runs(args.out_dir)
            )
            if not directories:
                raise FeatureExtractionError(
                    f"no feature runs under {args.out_dir}; build one first"
                )
            for directory in directories:
                report = verify_run(
                    directory,
                    groups_path=args.groups,
                    pairs_path=args.pairs,
                    top_k=args.top_k,
                )
                print(report.to_text())
                print(f"report     : {directory / 'report.txt'}")
                print()
            return 0

        if args.command == "compare":
            print(compare_runs(args.out_dir), end="")
            return 0

        if args.command == "build-golden":
            count = write_golden(args.out)
            print(f"wrote {count} preprocessing golden rows to {args.out}")
            return 0

        parser.error(f"unknown command {args.command!r}")
        return 2
    except (FeatureExtractionError, DatasetError, ManifestError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
