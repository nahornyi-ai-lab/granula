"""Checks the live hints a recording produced (see hints.sh).

Usage: python3 -I check_hints.py <meeting folder> <hints.json> <phrases.json> <new granula.log part>
                                 <snapshots dir> [<translate language>]
Prints "ok   ..." / "FAIL ..." lines and exits non-zero on any FAIL.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

CYR = re.compile(r"[А-Яа-яЁёІіЇїЄє]")
BUNDLE_ID = "ai.nahornyi.granula"
MIN_WIDTH_PT = 620
FIRST_TEXT_MS, DONE_MS = 4000, 7000
failed = False


def check(ok, text):
    global failed
    failed |= not ok
    print(f"{'ok  ' if ok else 'FAIL'} {text}")


def png_points(path):
    """Width in points: pixels divided by the scale the PNG's dpi (pHYs) tells; no dpi: pixels."""
    data = path.read_bytes()
    width = int.from_bytes(data[16:20], "big")
    i = 8
    while i + 8 <= len(data):
        n, kind = int.from_bytes(data[i:i + 4], "big"), data[i + 4:i + 8]
        if kind == b"pHYs":
            ppm = int.from_bytes(data[i + 8:i + 12], "big")  # pixels per metre; 72 dpi = 2834.6
            if ppm:
                return width / max(1.0, round(ppm / 2834.6 * 4) / 4), width
        i += 12 + n
    return float(width), width


def main():
    folder, hints_path, phrases_path, log_path, shots = (Path(a) for a in sys.argv[1:6])
    translate = sys.argv[6] if len(sys.argv) > 6 else ""
    try:
        state = json.loads(hints_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        sys.exit(f"FAIL no readable {hints_path}")
    hints = state.get("hints", [])
    phrases = json.loads(phrases_path.read_text(encoding="utf-8"))
    log = log_path.read_text(encoding="utf-8", errors="replace")
    print(f"judgeError: {state.get('judgeError')}, hints: {len(hints)}")
    for h in hints:
        print(f"  #{h['id']} [{h['start']:.1f}] {h['state']} said: {h['said']}\n      {h['text']}")
        if h.get("translation"):
            print(f"      → {h['translation']}")

    check(state.get("judgeError") is None, f"no judge error ({state.get('judgeError')})")

    timeline = [h for h in hints if "timeline" in h["said"].lower()]
    check(len(timeline) == 1, f"one hint for the timeline request ({len(timeline)})")
    t = timeline[0] if timeline else None
    if t:
        check(t["state"] == "done", f"timeline hint is done ({t['state']}, error {t.get('error')})")
        check(bool(t["text"].strip()) and not CYR.search(t["text"]), "timeline hint is English text")
        check("march" in t["text"].lower(), "timeline hint uses the About me fact (March)")
    check(not any("got it" in h["said"].lower() for h in hints), "no hint for \"Okay, got it.\"")

    if translate == "ru":
        if t:
            check(bool(CYR.search(t.get("translation") or "")), "timeline hint has a Russian translation")
        ru = [h for h in hints if CYR.search(h["said"])]
        check(len(ru) == 1, f"one hint for the Russian question ({len(ru)})")
        if ru:
            check(bool(CYR.search(ru[0]["text"])), "Russian question hint is in Russian")
            check(ru[0].get("translation") is None, "Russian question hint is not translated")

    judged = len(re.findall(r"hint\.judge ", log))
    check(judged >= len(phrases), f"hint.judge rows {judged} >= phrases played {len(phrases)}")

    if t:
        def ms(event):
            m = re.search(rf"{event} id={t['id']} ms=(\d+)", log)
            return int(m.group(1)) if m else None
        first, done = ms(r"hint\.first_text"), ms(r"hint\.done")
        check(first is not None and first <= FIRST_TEXT_MS, f"first text {first} ms <= {FIRST_TEXT_MS}")
        check(done is not None and done <= DONE_MS, f"done {done} ms <= {DONE_MS}")

    # The key lives in its own file only.
    leaks = ["granula.log"] if "sk-or-" in log else []
    for f in folder.rglob("*"):
        if f.is_file() and b"sk-or-" in f.read_bytes():
            leaks.append(f.name)
    defaults = subprocess.run(["defaults", "read", BUNDLE_ID], capture_output=True, text=True).stdout
    if "sk-or-" in defaults:
        leaks.append("defaults")
    check(not leaks, f"no sk-or- in log, meeting folder or defaults{' (found in ' + ', '.join(leaks) + ')' if leaks else ''}")

    pngs = sorted(shots.glob("window-*.png"), key=lambda p: int(re.sub(r"\D", "", p.stem) or 0))
    check(bool(pngs), f"Live window snapshots exist ({len(pngs)})")
    if pngs:
        pt, px = png_points(pngs[-1])
        check(pt >= MIN_WIDTH_PT, f"last snapshot {pngs[-1].name} is {pt:.0f} pt wide ({px} px), need >= {MIN_WIDTH_PT}")

    if failed:
        sys.exit("FAIL live hints")
    print("PASS live hints")


main()
