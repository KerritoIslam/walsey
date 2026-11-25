"""Feature-extraction implementations and the shared protocol."""

from __future__ import annotations

from .base import (
    EmbeddingBackend,
    EmptyTextError,
    FeatureExtractionError,
    FeatureExtractor,
    FeatureManifestMismatch,
    FittableFeatureExtractor,
    ModelDimensionMismatch,
    l2_normalize,
    validate_matrix,
    validate_texts,
)
from .sentence_transformer import (
    SentenceTransformerBackend,
    SentenceTransformerExtractor,
)
from .tfidf import TfidfExtractor

__all__ = [
    "EmbeddingBackend",
    "EmptyTextError",
    "FeatureExtractionError",
    "FeatureExtractor",
    "FeatureManifestMismatch",
    "FittableFeatureExtractor",
    "ModelDimensionMismatch",
    "SentenceTransformerBackend",
    "SentenceTransformerExtractor",
    "TfidfExtractor",
    "l2_normalize",
    "validate_matrix",
    "validate_texts",
]
