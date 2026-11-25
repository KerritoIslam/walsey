"""Write the Python preprocessed golden fixture consumed by a Dart test."""

from __future__ import annotations

import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from walsey_intent.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main(["build-golden", *sys.argv[1:]]))
