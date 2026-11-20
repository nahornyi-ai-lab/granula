"""Checks the live transcript a recording left in live.jsonl (see live.sh).

Usage: python3 -I check_live.py <meeting folder> <phrases.json> <seconds the call started after the
                                live origin> [<target> [<source> [<meeting languages, comma-separated>]]]
Every phrase of the call must appear as "Them" text while the meeting goes on,
soon after it is spoken. Prints each line with its delay and translation.
With a target, each shown line is matched to the phrase it says (phrases.json knows its language):
a line of a phrase in the target stays as it is (told as the target, no translation); with a source,
a line of a phrase in it is told as it and translated; on Auto, a line of a phrase in any other
meeting language is translated. Lines of other phrases (say Spanish while From is English) are not judged.
"""
import json
import re
import sys
from pathlib import Path

MAX_DELAY = 4.0  # seconds from the end of a phrase to its line on screen


def words(text):
    return re.findall(r"[^\W\d_]+", text.lower().replace("ё", "е"))


def same(a, b):
    return a.split("-")[0] == b.split("-")[0]


def phrase_of(line, phrases):
    """The phrase a line says: the one holding most of its words (at least half of them)."""
    w = words(line["text"])
    if not w:
        return None
    score, best = max(((sum(x in set(words(p["text"])) for x in w) / len(w), i) for i, p in enumerate(phrases)))
    return phrases[best] if score >= 0.5 else None


def main():
    folder, phrases_path, offset = Path(sys.argv[1]), Path(sys.argv[2]), float(sys.argv[3])
    target = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
    source = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
    log = folder / "live.jsonl"
    if not log.exists():
        sys.exit(f"FAIL no {log.name}")
    lines = {}
    for row in log.read_text(encoding="utf-8").splitlines():
        try:
            line = json.loads(row)
        except ValueError:
            continue
        lines[line["id"]] = line
    lines = sorted(lines.values(), key=lambda l: l["start"])
    shown = [l for l in lines if not l.get("echo")]
    print(f"lines: {len(lines)}, shown: {len(shown)}, echoes hidden: {len(lines) - len(shown)}")
    for l in shown:
        delay = (l.get("finishedAt") or 0) - l["end"]
        tr = l.get("translatedAt")
        tr_delay = f" +{tr - l['end']:.1f}s" if tr else ""
        print(f"  [{l['start']:6.1f}] {l['speaker']:<4} +{delay:.1f}s {l['text']}")
        if l.get("translation"):
            print(f"         {l.get('language')}→{l.get('target')}{tr_delay}: {l['translation']}")

    phrases = json.loads(phrases_path.read_text(encoding="utf-8"))
    them = [l for l in shown if l["speaker"] == "Them"]
    failed = False
    for p in phrases:
        start, end = p["start"] + offset, p["end"] + offset
        near = [l for l in them if l["end"] >= start - 1 and l["start"] <= end + 1]
        heard = set(w for l in near for w in words(l["text"]))
        expected = words(p["text"])
        recall = sum(w in heard for w in expected) / len(expected)
        delays = [(l.get("finishedAt") or 1e9) - l["end"] for l in near]
        worst = max(delays) if delays else None
        ok = recall >= 0.7 and worst is not None and worst <= MAX_DELAY
        failed |= not ok
        print(f"{'ok  ' if ok else 'FAIL'} {p['lang']} recall={recall:.2f} delay={worst if worst is None else round(worst, 1)} — {p['text']}")

    # Translation, judged by what was said (phrases.json), not by the language the app told.
    if target:
        languages = [x for x in (sys.argv[6].split(",") if len(sys.argv) > 6 else []) if x]
        for l in shown:
            p = phrase_of(l, phrases)
            if p is None:
                continue
            truth, told, translated = p["lang"], l.get("language"), bool(l.get("translation"))
            if same(truth, target):
                ok = not translated and told is not None and same(told, target)
                what = "left as it is" if ok else "must be left as it is"
            elif source and same(truth, source):
                ok = translated and told is not None and same(told, source)
                what = "translated" if ok else f"must be told as {source} and translated"
            elif not source and any(same(truth, x) for x in languages):
                ok = translated
                what = "translated" if ok else "must be translated"
            else:
                print(f"skip {truth} line, not {source or 'a meeting language'}: {l['text']}")
                continue
            failed |= not ok
            print(f"{'ok  ' if ok else 'FAIL'} {l['speaker']:<4} {truth} (told {told or '?'})→{target} {what}: "
                  f"{l.get('translation') or l['text']}")

    # The call plays through the speakers, so the mic hears it: those "Me" lines must be hidden.
    # A shown "Me" line repeats the call when half of its words are in a phrase near it in time.
    me = [l for l in shown if l["speaker"] == "Me"]
    repeats = []
    for l in me:
        w = words(l["text"])
        near = [p for p in phrases
                if l["end"] >= p["start"] + offset - 3 and l["start"] <= p["end"] + offset + 3]
        said = set(x for p in near for x in words(p["text"]))
        if w and sum(x in said for x in w) / len(w) >= 0.5:
            repeats.append(l["text"])
    echo_ok = len(repeats) <= 1
    failed |= not echo_ok
    print(f"{'ok  ' if echo_ok else 'FAIL'} {len(repeats)} of {len(me)} shown Me lines repeat the call")
    for text in repeats:
        print(f"      Me echo shown: {text}")

    if failed:
        sys.exit("FAIL live transcript")
    print("PASS live transcript")


main()
