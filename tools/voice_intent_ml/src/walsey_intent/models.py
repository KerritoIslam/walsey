"""Catalogue of embedding models investigated in Phase 1.

The catalogue is deliberately small and explicit. ``expected_dimension`` is a
*claim* that the loader verifies against the real model; the verified value is
written to the run manifest. A mismatch stops the run instead of silently
changing the MLP input size.

``revision`` is pinned to the commit resolved by ``scripts/fetch_model.py``.
Until a model has been fetched, it stays ``None`` and the fetch script records
the resolved SHA in ``model_manifest.json``.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class EmbeddingModelSpec:
    key: str
    model_id: str
    revision: str | None
    expected_dimension: int
    max_seq_length: int
    license: str
    approx_size_mb: int
    notes: str

    @property
    def is_pinned(self) -> bool:
        return self.revision is not None


CATALOGUE: dict[str, EmbeddingModelSpec] = {
    "all-MiniLM-L6-v2": EmbeddingModelSpec(
        key="all-MiniLM-L6-v2",
        model_id="sentence-transformers/all-MiniLM-L6-v2",
        revision=None,
        expected_dimension=384,
        max_seq_length=256,
        license="Apache-2.0",
        approx_size_mb=90,
        notes=(
            "Default candidate: 6-layer MiniLM, mean pooling + L2 normalize. "
            "Strong general-purpose sentence embedding for its size."
        ),
    ),
    "paraphrase-MiniLM-L3-v2": EmbeddingModelSpec(
        key="paraphrase-MiniLM-L3-v2",
        model_id="sentence-transformers/paraphrase-MiniLM-L3-v2",
        revision=None,
        expected_dimension=384,
        max_seq_length=128,
        license="Apache-2.0",
        approx_size_mb=61,
        notes=(
            "Lighter 3-layer candidate trained for paraphrase similarity. "
            "Same expected output width, lower CPU cost."
        ),
    ),
}

DEFAULT_MODEL = "all-MiniLM-L6-v2"


def get_model_spec(key: str) -> EmbeddingModelSpec:
    try:
        return CATALOGUE[key]
    except KeyError as error:
        known = ", ".join(sorted(CATALOGUE))
        raise KeyError(f"unknown embedding model {key!r}; known: {known}") from error
