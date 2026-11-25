from __future__ import annotations

import numpy as np
import pytest

from walsey_intent.features.base import FeatureExtractionError, ModelDimensionMismatch
from walsey_intent.features.sentence_transformer import (
    SentenceTransformerBackend,
    SentenceTransformerExtractor,
)
from walsey_intent.features.tfidf import TfidfExtractor
from walsey_intent.models import EmbeddingModelSpec


def test_sentence_transformer_extractor_validates_and_normalizes(
    fake_backend,
) -> None:
    extractor = SentenceTransformerExtractor(fake_backend)

    matrix = extractor.transform(["turn the lights on", "make the lights blue"])

    assert matrix.shape == (2, 8)
    assert matrix.dtype == np.float32
    np.testing.assert_allclose(np.linalg.norm(matrix, axis=1), 1.0, atol=1e-6)


def test_sentence_transformer_extractor_rejects_wrong_model_width(
    make_backend,
) -> None:
    backend = make_backend(dimension=8, returned_width=7)
    extractor = SentenceTransformerExtractor(backend)

    with pytest.raises(ModelDimensionMismatch, match="returned width 7"):
        extractor.transform(["turn the lights on"])


def test_local_model_dimension_is_read_and_checked(tmp_path) -> None:
    model_path = tmp_path / "model"
    model_path.mkdir()
    spec = EmbeddingModelSpec(
        key="test-model",
        model_id="test/model",
        revision="a" * 40,
        expected_dimension=384,
        max_seq_length=128,
        license="test",
        approx_size_mb=1,
        notes="test fixture",
    )

    class Model:
        max_seq_length = 128

        def get_sentence_embedding_dimension(self) -> int:
            return 384

    loader_calls: list[tuple[str, dict[str, object]]] = []

    def loader(path: str, **kwargs: object) -> Model:
        loader_calls.append((path, kwargs))
        return Model()

    backend = SentenceTransformerBackend.from_local_path(
        model_path,
        spec,
        loader=loader,
    )

    assert backend.dimension == 384
    assert loader_calls == [
        (str(model_path), {"device": "cpu", "local_files_only": True})
    ]

    class WrongDimensionModel(Model):
        def get_sentence_embedding_dimension(self) -> int:
            return 768

    with pytest.raises(ModelDimensionMismatch, match="reports dimension 768"):
        SentenceTransformerBackend.from_local_path(
            model_path,
            spec,
            loader=lambda *_args, **_kwargs: WrongDimensionModel(),
        )


def test_tfidf_zero_vector_for_out_of_vocabulary_text() -> None:
    extractor = TfidfExtractor()
    extractor.fit(["turn the lights on", "make the lights blue"])

    matrix = extractor.transform(["turn the lights on", "quartz nebula"])

    assert matrix.shape == (2, extractor.dimension)
    assert matrix.dtype == np.float32
    assert np.linalg.norm(matrix[0]) == pytest.approx(1.0)
    assert np.linalg.norm(matrix[1]) == pytest.approx(0.0)


def test_tfidf_cannot_transform_before_fit() -> None:
    with pytest.raises(FeatureExtractionError, match="fit the TF-IDF"):
        TfidfExtractor().transform(["turn the lights on"])
