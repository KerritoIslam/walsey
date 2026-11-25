"""The shared fixture intended for future cross-language parity checks.

Regenerating it from the current Python implementation must produce exactly the
checked-in data, and every fixture row must agree with the Python functions.
"""

from __future__ import annotations

import json
from pathlib import Path

from walsey_intent.golden import GOLDEN_CASES, build_golden_rows
from walsey_intent.io import read_jsonl
from walsey_intent.preprocessing import (
    normalize_for_embedding,
    normalize_parser_tokens,
)

FIXTURE = Path(__file__).resolve().parents[1] / "testdata" / "preprocessing_golden.jsonl"


def _load_fixture() -> list[dict[str, object]]:
    return [data for _, data in read_jsonl(FIXTURE)]


def test_fixture_exists_and_is_not_empty() -> None:
    assert FIXTURE.is_file()
    assert len(_load_fixture()) == len(GOLDEN_CASES)


def test_fixture_matches_the_current_python_implementation() -> None:
    assert _load_fixture() == build_golden_rows()


def test_fixture_has_the_documented_fields() -> None:
    required = {
        "note",
        "original",
        "canonical",
        "tokens",
        "actionTokens",
        "numbers",
        "preprocessingVersion",
    }
    for row in _load_fixture():
        assert set(row) == required
        assert row["preprocessingVersion"] == "phase1-v1"
        assert isinstance(row["original"], str)
        assert isinstance(row["canonical"], str)
        assert isinstance(row["tokens"], list)
        assert isinstance(row["actionTokens"], list)
        assert isinstance(row["numbers"], list)


def test_every_row_agrees_with_the_pure_functions() -> None:
    for row in _load_fixture():
        original = str(row["original"])
        assert row["canonical"] == normalize_for_embedding(original)
        assert row["tokens"] == normalize_parser_tokens(original)


def test_fixture_covers_the_documented_edge_cases() -> None:
    originals = {str(row["original"]) for row in _load_fixture()}
    # Case, punctuation, apostrophes, percent, decimal, sign, product hyphen,
    # accents, full-width characters, wake words, control characters, empty,
    # emoji and non-Latin script.
    assert "Turn the LED on." in originals
    assert "don't turn the lights on" in originals
    assert "Don\u2019t turn the lights on." in originals
    assert "set brightness to 50%" in originals
    assert "set brightness to 0.5 percent" in originals
    assert "set brightness to -5 percent" in originals
    assert "LEDDMX-03 strip" in originals
    assert "caf\u00e9 lights" in originals
    assert "\uff15\uff10\uff05 bright" in originals
    assert "hey walsey turn the lights on" in originals
    assert "turn\u200b the lights on" in originals
    assert "!!!" in originals
    assert "" in originals
    assert "\U0001f680\U0001f31f" in originals
    assert "\u0627\u0644\u0639\u0631\u0628\u064a\u0629" in originals


def test_fixture_contains_literal_dart_expectations() -> None:
    rows = {str(row["original"]): row for row in _load_fixture()}
    assert rows["don't turn the lights on"]["tokens"] == [
        "dont",
        "turn",
        "the",
        "lights",
        "on",
    ]
    assert rows["set brightness to 50%"]["tokens"] == [
        "set",
        "brightness",
        "to",
        "50",
        "percent",
    ]
    assert rows["LEDDMX-03 strip"]["tokens"] == ["leddmx", "03", "strip"]
    assert rows["caf\u00e9 lights"]["canonical"] == "caf\u00e9 lights"
    assert rows["caf\u00e9 lights"]["tokens"] == ["caf", "lights"]
    assert rows["\uff15\uff10\uff05 bright"]["tokens"] == ["bright"]
    assert rows["walsey"]["tokens"] == ["walsey"]


def test_fixture_file_is_utf8_jsonl() -> None:
    raw = FIXTURE.read_text(encoding="utf-8").splitlines()
    assert raw
    for line in raw:
        assert json.loads(line)["preprocessingVersion"] == "phase1-v1"
