from __future__ import annotations

import numpy as np
import pytest

from walsey_intent.features.base import EmptyTextError
from walsey_intent.features.sentence_transformer import (
    SentenceTransformerExtractor,
)
from walsey_intent.features.tfidf import TfidfExtractor
from walsey_intent.io import write_jsonl
from walsey_intent.pipeline import build, load, save, transform_texts
from walsey_intent.runner import TFIDF_KEY, build_features


def test_transform_texts_shares_preprocessing_and_skips_empty(
    fake_backend,
) -> None:
    extractor = SentenceTransformerExtractor(fake_backend)

    batch = transform_texts(
        ["  Set brightness to 50%. ", "!!!", "Walsey turn the lights on"],
        extractor,
    )

    assert batch.input_indices == (0, 2)
    assert [row.original for row in batch.processed] == [
        "  Set brightness to 50%. ",
        "Walsey turn the lights on",
    ]
    assert [row.canonical for row in batch.processed] == [
        "set brightness to 50 percent",
        "turn the lights on",
    ]
    assert batch.matrix.shape == (2, 8)
    assert [(row.index, row.reason) for row in batch.skipped] == [
        (1, "empty-canonical")
    ]


def test_transform_texts_rejects_all_empty_inputs(fake_backend) -> None:
    extractor = SentenceTransformerExtractor(fake_backend)
    with pytest.raises(EmptyTextError, match="every input"):
        transform_texts(["!!!", "walsey"], extractor)


def test_build_saves_rows_matrix_and_skips_with_matching_order(
    tmp_path,
    sample_dataset,
) -> None:
    extractor = TfidfExtractor()
    prepared = [
        row.original
        for row in sample_dataset
        if row.original != "walsey"
    ]
    from walsey_intent.preprocessing import normalize_for_embedding

    extractor.fit([normalize_for_embedding(text) for text in prepared])
    source_path = tmp_path / "source.jsonl"
    write_jsonl(source_path, (row.to_dict() for row in sample_dataset))
    built = build(
        sample_dataset,
        extractor,
        dataset_path=source_path,
    )

    output = tmp_path / "features"
    save(built, output)
    loaded = load(output)

    assert loaded.matrix.shape == (5, extractor.dimension)
    assert len(loaded.rows) == 5
    assert loaded.rows[0]["original"] == "turn the lights on"
    assert loaded.rows[0]["vector"] == [
        round(float(value), 6) for value in built.matrix[0]
    ]
    assert loaded.manifest["dataset"]["skippedRows"] == 1
    assert loaded.manifest["matrix"]["dtype"] == "float32"
    assert (output / "skipped.jsonl").is_file()


def test_tfidf_run_persists_fitted_mapping_for_inference(
    tmp_path,
    sample_dataset,
) -> None:
    dataset_path = tmp_path / "dataset.jsonl"
    write_jsonl(dataset_path, (row.to_dict() for row in sample_dataset))

    run_dir, built = build_features(
        TFIDF_KEY,
        dataset_path=dataset_path,
        out_dir=tmp_path / "out",
        measure_timing=False,
    )

    restored = TfidfExtractor.load(run_dir)
    inferred = restored.transform(["turn the lights on"])

    assert (run_dir / "vectorizer.joblib").is_file()
    assert (run_dir / "vocabulary.json").is_file()
    assert inferred.shape == (1, built.matrix.shape[1])
    np.testing.assert_allclose(inferred[0], built.matrix[0], atol=1e-6)
