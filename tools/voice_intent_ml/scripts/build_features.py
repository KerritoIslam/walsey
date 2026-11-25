"""Build a legacy transcript-text feature run.

For the raw-audio Phase 1 path, use ``scripts/extract_log_mel.py``.
"""

from __future__ import annotations

import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from walsey_intent.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main(["build-features", *sys.argv[1:]]))
