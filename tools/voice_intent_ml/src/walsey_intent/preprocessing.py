"""Deterministic text preprocessing for the Walsey intent-ML research pipeline.

Every input produces two representations:

``canonical``
    The light, Unicode-aware form fed to a sentence-embedding model. It keeps
    meaning-bearing material (apostrophes, internal hyphens, decimals and
    signed numbers) and only removes punctuation/symbol noise. It does not
    stem, remove stop words, correct spelling or rewrite synonyms.

``tokens``
    An exact Python port of ``normalizeCommandText`` from
    ``walsey_voice_core/lib/src/parser/normalization.dart``. It exists so this
    tool can reason about exactly what the shipped parser sees, and so a Dart
    test can enforce cross-language parity.

Nothing here parses an intent, validates a parameter or executes a command.
The original string is always preserved untouched.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

PREPROCESSING_VERSION = "phase1-v1"

_GREETINGS = frozenset({"hey", "ok", "okay"})
_WAKE_WORD = "walsey"
_NUMBER_TOKEN = re.compile(r"^-?\d+(?:\.\d+)?$")
_WHITESPACE = re.compile(r"\s+")

# NFKC already folds many of these, but doing it explicitly keeps the rule
# readable and stable across Python/Unicode versions.
_CHAR_TRANSLATION = str.maketrans(
    {
        "\u2018": "'",
        "\u2019": "'",
        "\u201a": "'",
        "\u201b": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u201e": '"',
        "\u201f": '"',
        "\u2010": "-",
        "\u2011": "-",
        "\u2012": "-",
        "\u2013": "-",
        "\u2014": "-",
        "\u2015": "-",
        "\u2212": "-",
    }
)


class PreprocessingError(ValueError):
    """The input cannot be preprocessed as text."""


@dataclass(frozen=True)
class PreprocessedText:
    """Both representations of one original sentence."""

    original: str
    canonical: str
    tokens: tuple[str, ...]
    action_tokens: tuple[str, ...]
    numbers: tuple[str, ...]

    @property
    def is_empty(self) -> bool:
        """True when there is nothing to embed.

        A bare wake word keeps its raw parser token ("walsey") but has an empty
        canonical string, so ``canonical`` — not ``tokens`` — decides this.
        """

        return not self.canonical


def _require_text(text: str) -> None:
    if not isinstance(text, str):
        raise TypeError(
            f"text must be a str, got {type(text).__name__}"
        )


def _is_word_char(char: str) -> bool:
    if not char:
        return False
    # Letters, combining marks and numbers survive. This keeps ``café`` and
    # Arabic script intact instead of reducing them to ASCII.
    return unicodedata.category(char)[0] in {"L", "M", "N"}


def strip_wake_word_tokens(tokens: list[str] | tuple[str, ...]) -> list[str]:
    """Mirror ``_stripWakeWord`` from the Dart parser.

    Leading ``hey``/``ok``/``okay`` are dropped, then one leading ``walsey``.
    A wake word in the middle is never touched.
    """

    index = 0
    while index < len(tokens) and tokens[index] in _GREETINGS:
        index += 1
    if index < len(tokens) and tokens[index] == _WAKE_WORD:
        index += 1
    return list(tokens[index:])


def _clean_embedding_text(text: str) -> str:
    value = unicodedata.normalize("NFKC", text).translate(_CHAR_TRANSLATION)
    value = value.lower().replace("%", " percent ")

    kept: list[str] = []
    length = len(value)
    for index, char in enumerate(value):
        category = unicodedata.category(char)
        if category in {"Cc", "Cf"}:
            # Control/format characters (including zero-width joiners) become
            # a word boundary, never part of a token.
            kept.append(" ")
            continue
        if char.isspace() or _is_word_char(char):
            kept.append(char)
            continue

        previous = value[index - 1] if index > 0 else ""
        following = value[index + 1] if index + 1 < length else ""

        # ``don't``, ``rock'n'roll``: an apostrophe inside a word stays.
        if (
            char == "'"
            and _is_word_char(previous)
            and _is_word_char(following)
        ):
            kept.append(char)
            continue

        # ``led-strip`` keeps its hyphen; ``-5`` keeps its sign.
        if char == "-" and (
            (following.isdigit())
            or (_is_word_char(previous) and _is_word_char(following))
        ):
            kept.append(char)
            continue

        # ``0.5`` stays one token; sentence-final periods are separated.
        if (
            char == "."
            and previous.isdigit()
            and following.isdigit()
        ):
            kept.append(char)
            continue

        kept.append(" ")

    collapsed = _WHITESPACE.sub(" ", "".join(kept)).strip()
    tokens = strip_wake_word_tokens([t for t in collapsed.split(" ") if t])
    return " ".join(tokens)


def normalize_for_embedding(text: str) -> str:
    """Return the light normalization used as the embedding-model input."""

    _require_text(text)
    return _clean_embedding_text(text)


def normalize_parser_tokens(text: str) -> list[str]:
    """Port of ``normalizeCommandText`` from the pure Dart voice core.

    The rules are intentionally identical, including the ASCII-only character
    filter and the number-aware split. Do not "improve" this function without
    updating ``normalization.dart`` and the golden parity fixture together.
    """

    _require_text(text)
    value = text.lower().strip()
    value = re.sub(r"['\u2019]", "", value)
    value = value.replace("%", " percent ")
    value = re.sub(r"-(?!\d)", " ", value)
    value = re.sub(r"[^a-z0-9.\s-]", " ", value)
    value = _WHITESPACE.sub(" ", value).strip()

    tokens: list[str] = []
    if not value:
        return tokens
    for raw in value.split(" "):
        if _NUMBER_TOKEN.match(raw):
            tokens.append(raw)
            continue
        for part in re.split(r"[.\-]", raw):
            if part:
                tokens.append(part)
    return tokens


def preprocess(text: str) -> PreprocessedText:
    """Preprocess one sentence into both representations."""

    _require_text(text)
    canonical = normalize_for_embedding(text)
    tokens = tuple(normalize_parser_tokens(text))
    action_tokens = tuple(strip_wake_word_tokens(tokens))
    numbers = tuple(
        token for token in action_tokens if _NUMBER_TOKEN.match(token)
    )
    return PreprocessedText(
        original=text,
        canonical=canonical,
        tokens=tokens,
        action_tokens=action_tokens,
        numbers=numbers,
    )
