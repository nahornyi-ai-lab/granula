"""Builds the E2E "far end of a call": six FLEURS clips (ru, uk, en; different
topics) with 1.2 s pauses, normalized to call level (-6 dBFS peak).

Usage: python3 -I make_call_audio.py <bench_dir> <out_dir>
Writes <out_dir>/call.wav and <out_dir>/reference.txt (normalized FLEURS text).
"""
import array
import json
import sys
import wave
from pathlib import Path

CLIPS = ["ru_ru_1663", "uk_ua_1668", "en_us_1665", "ru_ru_1669", "uk_ua_1661", "en_us_1667"]
RATE = 16000
GAP = int(1.2 * RATE)

bench, out = Path(sys.argv[1]), Path(sys.argv[2])
manifest = {}
for line in open(bench / "data/sets/manifest.jsonl", encoding="utf-8"):
    m = json.loads(line)
    if m["set"] == "clean":
        manifest[m["utt"]] = m

samples = array.array("h", [0] * int(0.5 * RATE))
refs = []
for utt in CLIPS:
    m = manifest[utt]
    with wave.open(m["path"], "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        clip = array.array("h", w.readframes(w.getnframes()))
    peak = max(abs(s) for s in clip) or 1
    gain = 0.5 * 32767 / peak
    samples.extend(int(max(-32767, min(32767, s * gain))) for s in clip)
    samples.extend([0] * GAP)
    refs.append(m["ref"])

out.mkdir(parents=True, exist_ok=True)
with wave.open(str(out / "call.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(samples.tobytes())
(out / "reference.txt").write_text(" ".join(refs) + "\n", encoding="utf-8")
print(f"call.wav {len(samples) / RATE:.1f} s, {len(CLIPS)} clips")
