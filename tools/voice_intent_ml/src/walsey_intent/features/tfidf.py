"""TF-IDF baseline for the Phase 1 comparison.

This is deliberately a *baseline*, not the planned representation. It shows how
much word overlap alone buys on the command corpus: paraphrase pairs such as
"switch on the lights" and "activate my led" share no tokens, so TF-IDF cannot
place them near each other.

The vectorizer is fitted on the same ``canonical`` strings used by the
Sentence Transformer extractor and is persisted with ``joblib``. Phase 1 uses
it descriptively (fit and evaluate on the example corpus); it is not a
leakage-safe classifier evaluation.
"""

from __future__ import annotations

from pathlib import Path
from typing import Sequence

import joblib
import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer

from .base import FeatureExtractionError, l2_normalize, validate_matrix, validate_texts


class TfidfExtractor:
    """Word/ngram TF-IDF with L2-normalized dense output."""

    def __init__(
        self,
        *,
        ngram_range: tuple[int, int] = (1, 2),
        min_df: int = 1,
        sublinear_tf: bool = True,
    ) -> None:
        self._ngram_range = ngram_range
        self._min_df = min_df
        self._sublinear_tf = sublinear_tf
        self._vectorizer: TfidfVectorizer | None = None

    @property
    def name(self) -> str:
        low, high = self._ngram_range
        return f"tfidf/word-{low}-{high}"

    @property
    def dimension(self) -> int:
        if self._vectorizer is None:
            raise FeatureExtractionError("the TF-IDF extractor is not fitted")
        return len(self._vectorizer.vocabulary_)

    @property
    def is_fitted(self) -> bool:
        return self._vectorizer is not None

    def fit(self, texts: Sequence[str]) -> None:
        prepared = validate_texts(texts)
        vectorizer = TfidfVectorizer(
            lowercase=False,
            tokenizer=str.split,
            token_pattern=None,
            ngram_range=self._ngram_range,
            min_df=self._min_df,
            sublinear_tf=self._sublinear_tf,
            norm="l2",
            dtype=np.float32,
        )
        vectorizer.fit(prepared)
        self._vectorizer = vectorizer

    def transform(self, texts: Sequence[str]) -> np.ndarray:
        if self._vectorizer is None:
            raise FeatureExtractionError(
                "fit the TF-IDF extractor before transforming"
            )
        prepared = validate_texts(texts)
        sparse = self._vectorizer.transform(prepared)
        dense = sparse.toarray().astype(np.float32, copy=False)
        # TfidfVectorizer already applies L2 normalization, but run the shared
        # validator so both extractors have the same guarantees.
        return validate_matrix(
            dense,
            rows=len(prepared),
            dimension=self.dimension,
            # A sentence whose tokens are all out of vocabulary shares nothing
            # with the fitted corpus. Its correct TF-IDF row is all zeros; the
            # baseline reports that honestly instead of refusing to run.
            allow_zero_rows=True,
        )

    def fit_transform(self, texts: Sequence[str]) -> np.ndarray:
        self.fit(texts)
        return self.transform(texts)

    def vocabulary(self) -> dict[str, int]:
        if self._vectorizer is None:
            raise FeatureExtractionError("the TF-IDF extractor is not fitted")
        return dict(self._vectorizer.vocabulary_)

    def describe(self) -> dict[str, object]:
        return {
            "provider": "scikit-learn",
            "name": self.name,
            "ngram_range": list(self._ngram_range),
            "min_df": self._min_df,
            "sublinear_tf": self._sublinear_tf,
            "norm": "l2",
            "dtype": "float32",
            "dimension": self.dimension if self.is_fitted else None,
        }

    def save(self, directory: Path) -> None:
        if self._vectorizer is None:
            raise FeatureExtractionError("cannot save an unfitted TF-IDF extractor")
        directory.mkdir(parents=True, exist_ok=True)
        joblib.dump(self._vectorizer, directory / "vectorizer.joblib")
        import json

        (directory / "vocabulary.json").write_text(
            json.dumps(self.vocabulary(), indent=2, sort_keys=True),
            encoding="utf-8",
        )

    @classmethod
    def load(cls, directory: Path) -> "TfidfExtractor":
        path = directory / "vectorizer.joblib"
        if not path.is_file():
            raise FeatureExtractionError(f"no TF-IDF vectorizer at {path}")
        vectorizer = joblib.load(path)
        if not isinstance(vectorizer, TfidfVectorizer):
            raise FeatureExtractionError(
                f"{path} did not contain a TfidfVectorizer"
            )
        extractor = cls()
        extractor._vectorizer = vectorizer
        return extractor
