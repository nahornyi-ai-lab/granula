"""Checks one recorded meeting folder against the granula v1 E2E-1 criteria.

Usage: python3 -I check_meeting.py <meeting_folder> <reference.txt>
Exit 0 when every check passes.
"""
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

folder, reference = Path(sys.argv[1]), Path(sys.argv[2]).read_text(encoding="utf-8")
# The summary is written in the language of the conversation: ru, uk or en.
FACTS = {
    "Кочамо / Чили": r"кочам|cocham|\bчили|\bчилі|chile",
    "Соланки / полиция": r"соланк|solank|полици|поліц|police",
    "Wild Card / парки ЮАР": r"wild card|юар|парк|южн\w* африк|південн\w* африк|south africa|park",
    "Китай": r"кита|china|chinese",
    "Палестина / 1967": r"палестин|palestin|1967",
    "менеджеры": r"менеджер|керівник|руковод|manager",
}
APOS = re.compile(r"['’ʼ`´‘]")


def norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower().replace("ё", "е")
    s = APOS.sub("", s)
    s = "".join(" " if unicodedata.category(c)[0] in "PSC" else c for c in s)
    return s.split()


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
        prev = cur
    return prev[-1]


def lcs(a, b):
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0] * (len(b) + 1)
        for j, y in enumerate(b, 1):
            cur[j] = prev[j - 1] + 1 if x == y else max(prev[j], cur[j - 1])
        prev = cur
    return prev[-1]


def duration(path):
    out = subprocess.run(["afinfo", str(path)], capture_output=True, text=True).stdout
    m = re.search(r"estimated duration: ([\d.]+)", out)
    return float(m.group(1)) if m else 0.0


results = []
meeting = json.loads((folder / "meeting.json").read_text())
results.append(("статус встречи done", meeting["status"] == "done", meeting["status"]))

# Stop pads both tracks with silence, so length alone proves nothing.
for key in ["micPeak", "systemPeak"]:
    peak = meeting.get(key) or 0
    results.append((f"{key} ≥ 0.002 (дорожка слышит звук)", peak >= 0.002, f"{peak:.4f}"))

for name in ["mic.m4a", "system.m4a"]:
    d = duration(folder / name) if (folder / name).exists() else 0
    results.append((f"{name} не пустой (≥60 с)", d >= 60, f"{d:.1f} с"))

segments = json.loads((folder / "transcript.json").read_text())["segments"]
them = [s for s in segments if s["speaker"] == "Собеседник"]
me = [s for s in segments if s["speaker"] == "Я"]
ref = norm(reference)
hyp = norm(" ".join(s["text"] for s in them))
wer = edit_distance(ref, hyp) / len(ref)
results.append(("WER «Собеседник» ≤ 20%", wer <= 0.20, f"{wer:.1%}"))

dups = []
for s in me:
    words = norm(s["text"])
    near = [t for t in them if t["start"] - 3 <= s["end"] and s["start"] <= t["end"] + 3]
    near_words = norm(" ".join(t["text"] for t in near))
    if words and lcs(words, near_words) / len(words) >= 0.5:
        dups.append(s["text"])
results.append(("≤1 реплики «Я», дублирующей собеседника", len(dups) <= 1,
                f"{len(dups)} из {len(me)} реплик «Я»"))

summary = (folder / "summary.md").read_text(encoding="utf-8") if (folder / "summary.md").exists() else ""
found = [k for k, rx in FACTS.items() if re.search(rx, summary.lower())]
results.append(("итог не пустой и содержит ≥2 факта", len(summary.strip()) > 0 and len(found) >= 2,
                f"{len(found)} фактов: {', '.join(found)}"))

for name, ok, detail in results:
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")
for d in dups:
    print(f"      дубль «Я»: {d}")
print(f"echoes dropped by app: {json.loads((folder / 'transcript.json').read_text()).get('droppedEchoes')}")
sys.exit(0 if all(ok for _, ok, _ in results) else 1)
