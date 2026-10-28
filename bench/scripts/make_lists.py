"""Write TSV file lists (utt, path, lang) from data/sets/manifest.jsonl for the engine runners.
Usage: .venv/bin/python -I scripts/make_lists.py <bench_dir>"""
import json, sys
from pathlib import Path
b = Path(sys.argv[1]).resolve()
rows = [json.loads(l) for l in open(b / "data/sets/manifest.jsonl", encoding="utf-8")]
d = b / "data/lists"; d.mkdir(parents=True, exist_ok=True)
sets = {"all": rows}
for s in ("clean", "call", "codeswitch", "long"):
    sets[s] = [r for r in rows if r["set"] == s]
sets["short"] = [r for r in rows if r["set"] != "long"]
for name, rs in sets.items():
    with open(d / f"{name}.tsv", "w", encoding="utf-8") as f:
        for r in rs:
            f.write(f"{r['set']}/{r['utt']}\t{r['path']}\t{r['lang']}\n")
    print(name, len(rs))
