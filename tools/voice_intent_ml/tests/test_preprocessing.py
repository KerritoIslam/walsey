"""Preprocessing rules, including the deliberately non-destructive edges."""

from __future__ import annotations

import pytest

from walsey_intent.preprocessing import (
    PREPROCESSING_VERSION,
    normalize_for_embedding,
    normalize_parser_tokens,
    preprocess,
    strip_wake_word_tokens,
)


def test_version_is_pinned() -> None:
    assert PREPROCESSING_VERSION == "phase1-v1"


def test_original_is_preserved_untouched() -> None:
    original = "  Walsey, MAKE the lights blue!! "
    assert preprocess(original).original == original


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Turn the lights ON!!", "turn the lights on"),
        ("  SWITCH   ON the lights!! ", "switch on the lights"),
        ("Turn the LED on.", "turn the led on"),
        ("set brightness to 50%", "set brightness to 50 percent"),
        ("set brightness to 50 percent", "set brightness to 50 percent"),
        ("set brightness to 0.5 percent", "set brightness to 0.5 percent"),
        ("set brightness to -5 percent", "set brightness to -5 percent"),
        ("LEDDMX-03 strip", "leddmx-03 strip"),
        ("make the lights blue \u2014 now", "make the lights blue now"),
        ("\tmake\nthe lights\u00a0red ", "make the lights red"),
        ("turn\u200b the lights on", "turn the lights on"),
        ("hey walsey turn the lights on", "turn the lights on"),
        ("okay ok hey walsey turn the lights on", "turn the lights on"),
        ("walsey walsey turn the lights on", "walsey turn the lights on"),
        ("turn walsey on", "turn walsey on"),
        ("Set brightness to 1,000 percent", "set brightness to 1 000 percent"),
        ("set brightness to 5-10 percent", "set brightness to 5-10 percent"),
        ("!!!", ""),
        ("\U0001f680\U0001f31f", ""),
        ("", ""),
    ],
)
def test_canonical_form(text: str, expected: str) -> None:
    assert normalize_for_embedding(text) == expected


def test_canonical_keeps_apostrophes_hyphens_and_decimals() -> None:
    assert normalize_for_embedding("don't") == "don't"
    assert normalize_for_embedding("Don\u2019t") == "don't"
    assert normalize_for_embedding("LED-strip") == "led-strip"
    assert normalize_for_embedding("0.5") == "0.5"
    assert normalize_for_embedding("-5") == "-5"


def test_canonical_keeps_non_ascii_letters() -> None:
    # NFKC folds full-width digits, and accented/Arabic letters are kept so the
    # embedding model sees the real word, not a stripped ASCII fragment.
    assert normalize_for_embedding("caf\u00e9 lights") == "caf\u00e9 lights"
    assert normalize_for_embedding("\u0627\u0644\u0639\u0631\u0628\u064a\u0629") == (
        "\u0627\u0644\u0639\u0631\u0628\u064a\u0629"
    )
    assert normalize_for_embedding("\uff15\uff10\uff05 bright") == "50 percent bright"


def test_canonical_is_idempotent() -> None:
    samples = [
        "turn the lights on",
        "don't turn the lights on",
        "set brightness to 50 percent",
        "led-strip 0.5",
        "caf\u00e9 lights",
    ]
    for sample in samples:
        once = normalize_for_embedding(sample)
        assert normalize_for_embedding(once) == once


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("turn the lights on", ["turn", "the", "lights", "on"]),
        ("don't turn the lights on", ["dont", "turn", "the", "lights", "on"]),
        ("Don\u2019t turn", ["dont", "turn"]),
        ("set brightness to 50%", ["set", "brightness", "to", "50", "percent"]),
        ("LEDDMX-03", ["leddmx", "03"]),
        ("caf\u00e9 lights", ["caf", "lights"]),
        ("\uff15\uff10\uff05 bright", ["bright"]),
        ("0.5", ["0.5"]),
        ("-5", ["-5"]),
        ("5-10", ["5", "10"]),
        ("lights.", ["lights"]),
        ("", []),
        ("!!!", []),
    ],
)
def test_parser_tokens_match_the_dart_contract(
    text: str,
    expected: list[str],
) -> None:
    assert normalize_parser_tokens(text) == expected


def test_wake_word_stripping_is_leading_only() -> None:
    assert strip_wake_word_tokens(["hey", "walsey", "turn", "on"]) == [
        "turn",
        "on",
    ]
    assert strip_wake_word_tokens(["okay", "ok", "hey", "walsey", "turn"]) == [
        "turn"
    ]
    assert strip_wake_word_tokens(["turn", "walsey", "on"]) == [
        "turn",
        "walsey",
        "on",
    ]
    assert strip_wake_word_tokens(["walsey", "walsey", "turn"]) == [
        "walsey",
        "turn",
    ]
    assert strip_wake_word_tokens([]) == []


def test_preprocess_combines_both_forms() -> None:
    processed = preprocess("hey walsey set brightness to 50%")
    assert processed.canonical == "set brightness to 50 percent"
    assert processed.tokens == (
        "hey",
        "walsey",
        "set",
        "brightness",
        "to",
        "50",
        "percent",
    )
    assert processed.action_tokens == (
        "set",
        "brightness",
        "to",
        "50",
        "percent",
    )
    assert processed.numbers == ("50",)
    assert not processed.is_empty


def test_bare_wake_word_is_empty_for_embedding() -> None:
    processed = preprocess("walsey")
    assert processed.canonical == ""
    assert processed.tokens == ("walsey",)
    assert processed.action_tokens == ()
    assert processed.is_empty


def test_punctuation_only_is_empty() -> None:
    processed = preprocess("!!!")
    assert processed.canonical == ""
    assert processed.tokens == ()
    assert processed.is_empty


def test_non_string_input_is_rejected() -> None:
    with pytest.raises(TypeError):
        preprocess(None)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        normalize_for_embedding(5)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        normalize_parser_tokens(b"turn on")  # type: ignore[arg-type]


def test_long_input_is_handled() -> None:
    text = "turn the lights on " * 500
    processed = preprocess(text)
    assert processed.canonical.startswith("turn the lights on turn the lights on")
    assert processed.canonical.endswith("turn the lights on")
