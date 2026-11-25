"""Shared fixtures for the Phase 1 test suite.

The suite is offline by default: HF and Transformers are forced into offline
mode, and the only tests that touch a real model are marked ``run_model`` and
need an explicit ``--run-model``.
"""

from __future__ import annotations

import os
import sys
import zlib
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import numpy as np
import pytest

TOOL_ROOT = Path(__file__).resolve().parents[1]
SRC = TOOL_ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from walsey_intent.io import DatasetRow  # noqa: E402


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--run-model",
        action="store_true",
        default=False,
        help="run tests that load a real, explicitly fetched embedding model",
    )


def pytest_collection_modifyitems(
    config: pytest.Config,
    items: list[pytest.Item],
) -> None:
    if config.getoption("--run-model"):
        return
    skip = pytest.mark.skip(reason="needs a real model; pass --run-model")
    for item in items:
        if "run_model" in item.keywords:
            item.add_marker(skip)


class FakeBackend:
    """Deterministic in-memory :class:`EmbeddingBackend`.

    Vectors come from a CRC-seeded RNG, so they are stable across runs but carry
    no semantics. Tests that need meaning build the similarity matrix by hand.
    """

    def __init__(
        self,
        dimension: int = 8,
        *,
        returned_width: int | None = None,
        zero_rows: bool = False,
        nonfinite: bool = False,
        name: str = "fake-mini",
        model_id: str = "fake/mini",
        revision: str = "0" * 40,
        max_seq_length: int = 64,
    ) -> None:
        self.dimension = dimension
        self.returned_width = returned_width or dimension
        self.zero_rows = zero_rows
        self.nonfinite = nonfinite
        self.name = name
        self.model_id = model_id
        self.revision = revision
        self.max_seq_length = max_seq_length
        self.calls: list[tuple[int, int]] = []

    def encode(
        self,
        texts: list[str] | tuple[str, ...],
        *,
        batch_size: int = 32,
    ) -> np.ndarray:
        self.calls.append((len(texts), batch_size))
        rows: list[np.ndarray] = []
        for text in texts:
            if self.zero_rows:
                rows.append(np.zeros(self.returned_width, dtype=np.float32))
            elif self.nonfinite:
                rows.append(
                    np.full(self.returned_width, np.nan, dtype=np.float32)
                )
            else:
                seed = zlib.crc32(text.encode("utf-8"))
                rng = np.random.default_rng(seed)
                rows.append(
                    rng.standard_normal(self.returned_width).astype(np.float32)
                )
        if not rows:
            return np.zeros((0, self.returned_width), dtype=np.float32)
        return np.vstack(rows)

    def describe(self) -> dict[str, object]:
        return {
            "provider": "fake",
            "name": self.name,
            "model_id": self.model_id,
            "revision": self.revision,
            "dimension": self.dimension,
            "max_seq_length": self.max_seq_length,
            "pooling": "mean",
            "normalize": "l2",
            "dtype": "float32",
            "device": "cpu",
        }


@pytest.fixture
def fake_backend() -> FakeBackend:
    return FakeBackend()


@pytest.fixture
def make_backend():
    created: list[FakeBackend] = []

    def factory(**kwargs: object) -> FakeBackend:
        backend = FakeBackend(**kwargs)  # type: ignore[arg-type]
        created.append(backend)
        return backend

    return factory


def _row(
    row_id: str,
    original: str,
    intent: str,
    *,
    human_intent: str | None = None,
    parameters: tuple[str, ...] = (),
    failure_kind: str | None = None,
) -> DatasetRow:
    return DatasetRow(
        id=row_id,
        original=original,
        source="test",
        intent=intent,
        parser_accepts=intent != "unsupported",
        parameters=parameters,
        human_intent=human_intent,
        parser_failure_kind=failure_kind
        or ("unsupported" if intent == "unsupported" else None),
        tags=("test",),
    )


@pytest.fixture
def sample_dataset() -> tuple[DatasetRow, ...]:
    return (
        _row("t-1", "turn the lights on", "powerOn"),
        _row("t-2", "switch on the lights", "powerOn"),
        _row("t-3", "make the lights blue", "setColor", parameters=("Color: blue",)),
        _row(
            "t-4",
            "set brightness to 50 percent",
            "setBrightness",
            parameters=("Brightness: 50%",),
        ),
        _row("t-5", "play some music", "unsupported"),
        _row("t-6", "walsey", "unsupported"),
    )


@pytest.fixture
def tool_root() -> Path:
    return TOOL_ROOT


@pytest.fixture
def dataset_path(tool_root: Path) -> Path:
    return tool_root / "data" / "phase1_commands.jsonl"
