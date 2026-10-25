"""Generate the private 2 KiB BRAM PCM probe or a reproducible test tone.

Input PCM must be unsigned 8-bit, mono, 12000 Hz. No decoder is needed for
the existing handoff asset. This is a short hardware probe, not a full BGM.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import wave

ROOT = Path(__file__).resolve().parents[1]
COUNT = 2048
RATE = 12000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input", type=Path)
    source.add_argument("--test-tone", action="store_true")
    parser.add_argument("--start-seconds", type=float, default=30.0)
    args = parser.parse_args()
    if not math.isfinite(args.start_seconds) or args.start_seconds < 0:
        parser.error("--start-seconds must be finite and nonnegative")
    if args.input:
        offset = round(args.start_seconds * RATE)
        with args.input.open("rb") as stream:
            stream.seek(offset)
            raw = stream.read(COUNT)
        if len(raw) != COUNT:
            parser.error("input is too short for the requested 2048-sample clip")
        values = [x - 128 for x in raw]
        description = args.input.name
    else:
        # Integer cycles give the public fixture a seamless loop.
        values = [round(96 * math.sin(2 * math.pi * 75 * i / COUNT))
                  for i in range(COUNT)]
        description = "test tone (439.453125 Hz)"
        offset = 0
    peak = max(abs(x) for x in values)
    if peak == 0:
        parser.error("selected clip is silent")
    pcm = bytes(128 + round(x * 96 / peak * min(1, i / 32, (COUNT - 1 - i) / 32))
                for i, x in enumerate(values))
    output = ROOT / "assets/audio/generated"
    output.mkdir(parents=True, exist_ok=True)
    (output / "bgm_stage_a.hex").write_text(
        "".join(f"{x:02x}\n" for x in pcm), encoding="ascii")
    # Repeat the actual loop so the host preview matches what the FPGA plays.
    with wave.open(str(output / "bgm_stage_a_preview.wav"), "wb") as wav:
        wav.setparams((1, 1, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(pcm * 24)
    manifest = dict(source=description, source_offset_samples=offset,
                    sample_rate=RATE, sample_count=COUNT,
                    duration_seconds=COUNT / RATE,
                    pcm_sha256=hashlib.sha256(pcm).hexdigest())
    (output / "bgm_stage_a.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="ascii")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
