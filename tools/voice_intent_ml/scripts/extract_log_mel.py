"""Extract log-Mel features directly from an original WAV recording."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from walsey_intent.audio_pipeline import build_audio_features  # noqa: E402
from walsey_intent.io import INTENT_LABELS  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Convert WAV audio samples directly to log-Mel numeric features. "
            "No speech recognition or transcript is used."
        )
    )
    parser.add_argument("wav", type=Path, help="16-bit PCM WAV recording")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("out/audio"),
        help="feature output root (default: out/audio)",
    )
    parser.add_argument("--id", dest="sample_id", help="optional sample id")
    parser.add_argument("--intent", choices=INTENT_LABELS)
    parser.add_argument(
        "--parameter",
        action="append",
        default=[],
        help="optional validated parameter annotation; may be repeated",
    )
    args = parser.parse_args()

    result = build_audio_features(
        args.wav,
        args.out_dir,
        sample_id=args.sample_id,
        intent=args.intent,
        parameters=args.parameter,
    )
    audio = result.metadata["sourceAudio"]
    feature = result.metadata["features"]
    print(f"audio       : {audio['fileName']}")
    print(
        f"input       : {audio['sourceSampleRate']} Hz, "
        f"{audio['sourceChannels']} channel(s), "
        f"{audio['durationSeconds']:.3f} s"
    )
    print(f"features    : {feature['shape']} {feature['dtype']} (mel_bin, frame)")
    print(f"output      : {result.output_directory}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
