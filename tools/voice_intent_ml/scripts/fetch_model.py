"""The only network path in the Phase 1 tool.

Downloads an embedding model once, records the resolved commit and a SHA-256 per
file, then exits. Everything else in the pipeline loads from this local folder
with ``local_files_only=True``.

Usage (inside ``tools/voice_intent_ml``)::

    py -3.13 -m venv .venv
    .venv\\Scripts\\pip install -e ".[dev,embedding]"
    .venv\\Scripts\\python scripts\\fetch_model.py --model all-MiniLM-L6-v2

After a successful fetch, copy the printed revision into
``src/walsey_intent/models.py`` and commit that change. The runner refuses to
build features for an unpinned model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

TOOL_ROOT = Path(__file__).resolve().parents[1]
SRC = TOOL_ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from walsey_intent.models import CATALOGUE  # noqa: E402

DEFAULT_MODELS_DIR = TOOL_ROOT / ".models"
SENTENCE_TRANSFORMER_FILES = {
    "config.json",
    "config_sentence_transformers.json",
    "modules.json",
    "sentence_bert_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.txt",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_files(target: Path) -> list[dict[str, Any]]:
    files: list[dict[str, Any]] = []
    for path in sorted(target.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(target)
        if ".cache" in relative.parts:
            continue
        if relative.name == "model_manifest.json":
            continue
        files.append(
            {
                "path": relative.as_posix(),
                "size": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return files


def _verify_dimension(target: Path, expected: int) -> int | None:
    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print("  sentence-transformers is not installed; skipping dimension check")
        return None
    model = SentenceTransformer(str(target), device="cpu", local_files_only=True)
    dimension = model.get_sentence_embedding_dimension()
    if dimension is None:
        raise SystemExit(f"{target}: the model reported no embedding dimension")
    dimension = int(dimension)
    if dimension != expected:
        raise SystemExit(
            f"{target}: measured dimension {dimension}, catalogue claims "
            f"{expected}. Fix models.py before training on these features."
        )
    print(f"  verified dimension: {dimension} (catalogue claim confirmed)")
    return dimension


def _check_expected_files(target: Path, key: str) -> None:
    present = {path.name for path in target.iterdir() if path.is_file()}
    missing = SENTENCE_TRANSFORMER_FILES - present
    # Sentence Transformers exports vary slightly by version; require at least
    # the module/config/tokenizer core so a partial download cannot pass.
    required = {"config.json", "modules.json", "tokenizer_config.json"}
    if required - present:
        raise SystemExit(
            f"{key}: download at {target} is incomplete; missing "
            f"{sorted(required - present)} (all files: {sorted(missing)})"
        )


def fetch_one(
    key: str,
    *,
    models_dir: Path,
    revision_override: str | None = None,
) -> dict[str, Any]:
    from huggingface_hub import HfApi, snapshot_download

    spec = CATALOGUE[key]
    target = models_dir / spec.key
    target.mkdir(parents=True, exist_ok=True)

    api = HfApi()
    info = api.model_info(spec.model_id)
    resolved = revision_override or info.sha
    print(f"{key}: {spec.model_id}@{resolved}")
    if spec.revision and spec.revision != resolved:
        print(
            f"  note: models.py pins {spec.revision}; the fetch resolves "
            f"{resolved}. Update the pin deliberately if this is intended."
        )

    snapshot_download(
        repo_id=spec.model_id,
        revision=resolved,
        local_dir=str(target),
    )
    _check_expected_files(target, key)
    verified_dimension = _verify_dimension(target, spec.expected_dimension)

    files = _manifest_files(target)
    manifest = {
        "schemaVersion": 1,
        "modelKey": spec.key,
        "modelId": spec.model_id,
        "revision": resolved,
        "revisionPinnedInCatalogue": spec.revision,
        "fetchedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "license": spec.license,
        "expectedDimension": spec.expected_dimension,
        "verifiedDimension": verified_dimension,
        "maxSeqLength": spec.max_seq_length,
        "totalBytes": sum(item["size"] for item in files),
        "files": files,
    }
    (target / "model_manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"  wrote {target / 'model_manifest.json'} "
        f"({len(files)} files, {manifest['totalBytes'] / 1e6:.1f} MB)"
    )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Explicitly fetch one or more embedding models (network)."
    )
    parser.add_argument(
        "--model",
        action="append",
        choices=sorted(CATALOGUE),
        required=True,
        help="model key from src/walsey_intent/models.py (repeatable)",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        default=DEFAULT_MODELS_DIR,
        help="gitignored destination (default: tools/voice_intent_ml/.models)",
    )
    parser.add_argument(
        "--revision",
        default=None,
        help="override the resolved commit (advanced; recorded in the manifest)",
    )
    args = parser.parse_args(argv)

    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    token = os.environ.get("HF_TOKEN")
    if not token:
        print(
            "note: no HF_TOKEN set; using anonymous access to the public model."
        )

    manifests = []
    for key in args.model:
        manifests.append(
            fetch_one(
                key,
                models_dir=args.models_dir,
                revision_override=args.revision,
            )
        )

    print()
    print("Pin these revisions in src/walsey_intent/models.py:")
    for manifest in manifests:
        print(f'  "{manifest["modelKey"]}": revision="{manifest["revision"]}"')
    print()
    print("Then rebuild features. Feature building never downloads anything.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
