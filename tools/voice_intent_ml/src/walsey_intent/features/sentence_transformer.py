"""Sentence Transformer feature extraction.

The real backend is imported lazily so the core package (and the offline test
suite) works without torch or sentence-transformers installed. Tests use a fake
:class:`~walsey_intent.features.base.EmbeddingBackend`; the real model is only
loaded from a local, explicitly fetched directory.
"""

from __future__ import annotations

from pathlib import Path
from typing import Callable, Sequence

import numpy as np

from ..models import EmbeddingModelSpec
from .base import (
    EmbeddingBackend,
    FeatureExtractionError,
    ModelDimensionMismatch,
    l2_normalize,
    validate_matrix,
    validate_texts,
)


class SentenceTransformerBackend:
    """Adapter around ``sentence_transformers.SentenceTransformer``.

    The model is always loaded from ``path`` with ``local_files_only=True``.
    Nothing in this class downloads anything; that is the job of the explicit
    ``scripts/fetch_model.py``.
    """

    def __init__(
        self,
        model: object,
        *,
        name: str,
        model_id: str,
        revision: str | None,
        dimension: int,
        max_seq_length: int,
    ) -> None:
        self._model = model
        self.name = name
        self.model_id = model_id
        self.revision = revision
        self.dimension = dimension
        self.max_seq_length = max_seq_length

    @classmethod
    def from_local_path(
        cls,
        path: Path,
        spec: EmbeddingModelSpec,
        *,
        loader: Callable[..., object] | None = None,
    ) -> "SentenceTransformerBackend":
        """Load a model from an already-fetched local directory.

        ``loader`` exists so tests can prove that the dimension is *read from
        the model object* rather than assumed; the default loader is the only
        path that imports ``sentence_transformers``.
        """

        if not path.is_dir():
            raise FeatureExtractionError(
                f"embedding model {spec.key!r} is not installed at {path}. "
                "Run scripts/fetch_model.py once (explicit download); "
                "nothing is fetched implicitly."
            )
        if loader is None:
            try:
                from sentence_transformers import SentenceTransformer
            except ImportError as error:  # pragma: no cover - depends on install
                raise FeatureExtractionError(
                    "sentence-transformers is not installed. Install the "
                    "'embedding' extra: pip install -e \".[embedding]\""
                ) from error
            loader = SentenceTransformer

        model = loader(
            str(path),
            device="cpu",
            local_files_only=True,
        )
        dimension = model.get_sentence_embedding_dimension()
        if dimension is None:
            raise FeatureExtractionError(
                f"{spec.model_id} did not report an embedding dimension"
            )
        dimension = int(dimension)
        if dimension != spec.expected_dimension:
            raise ModelDimensionMismatch(
                f"{spec.model_id} reports dimension {dimension}, but the "
                f"catalogue claims {spec.expected_dimension}. Update "
                "models.py deliberately before training on these features."
            )
        return cls(
            model,
            name=spec.model_id,
            model_id=spec.model_id,
            revision=spec.revision,
            dimension=dimension,
            max_seq_length=int(model.max_seq_length),
        )

    def encode(
        self,
        texts: Sequence[str],
        *,
        batch_size: int = 32,
    ) -> np.ndarray:
        import torch  # lazy: only needed when a real model is used

        prepared = validate_texts(texts)
        with torch.inference_mode():
            vectors = self._model.encode(
                prepared,
                batch_size=batch_size,
                convert_to_numpy=True,
                normalize_embeddings=True,
                show_progress_bar=False,
                device="cpu",
            )
        return np.asarray(vectors, dtype=np.float32)

    def describe(self) -> dict[str, object]:
        return {
            "provider": "sentence-transformers",
            "model_id": self.model_id,
            "revision": self.revision,
            "dimension": self.dimension,
            "max_seq_length": self.max_seq_length,
            "pooling": "mean",
            "normalize": "l2",
            "dtype": "float32",
            "device": "cpu",
        }


class SentenceTransformerExtractor:
    """Feature extractor over an :class:`EmbeddingBackend`."""

    def __init__(
        self,
        backend: EmbeddingBackend,
        *,
        batch_size: int = 32,
    ) -> None:
        self._backend = backend
        self._batch_size = batch_size

    @property
    def name(self) -> str:
        return f"sentence-transformers/{self._backend.model_id}"

    @property
    def dimension(self) -> int:
        return self._backend.dimension

    def transform(self, texts: Sequence[str]) -> np.ndarray:
        prepared = validate_texts(texts)
        raw = self._backend.encode(prepared, batch_size=self._batch_size)
        values = np.asarray(raw, dtype=np.float32)
        if values.ndim != 2:
            raise FeatureExtractionError(
                f"the backend returned shape {values.shape}; expected 2-D"
            )
        if values.shape[0] != len(prepared):
            raise FeatureExtractionError(
                f"the backend returned {values.shape[0]} rows for "
                f"{len(prepared)} texts"
            )
        if values.shape[1] != self.dimension:
            raise ModelDimensionMismatch(
                f"the backend returned width {values.shape[1]}, but its "
                f"declared dimension is {self.dimension}"
            )
        # Normalize here as well as in the backend: the manifest promises unit
        # rows, and an accidental backend change must not silently shift the
        # MLP input scale.
        return validate_matrix(
            values,
            rows=len(prepared),
            dimension=self.dimension,
        )

    def describe(self) -> dict[str, object]:
        describe = getattr(self._backend, "describe", None)
        if callable(describe):
            return describe()
        return {
            "provider": "sentence-transformers",
            "model_id": getattr(self._backend, "model_id", self.name),
            "revision": getattr(self._backend, "revision", None),
            "dimension": self.dimension,
            "max_seq_length": getattr(self._backend, "max_seq_length", None),
            "pooling": "mean",
            "normalize": "l2",
            "dtype": "float32",
            "device": "cpu",
        }
