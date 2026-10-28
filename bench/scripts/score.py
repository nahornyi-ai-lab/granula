"""Score engine outputs: WER/CER per engine x set x language, speed, language ID, code-switch.

Normalization (same for reference and hypothesis): NFKC, lowercase, ё->е, apostrophes removed,
every other punctuation/symbol -> space, whitespace collapsed. References are FLEURS's
normalized `transcription` field. Digits vs number words are NOT normalized (caveat).

Usage: .venv/bin/python -I scripts/score.py <bench_dir>
Writes results/per_utt.csv, results/summary.csv, results/speed.csv, results/codeswitch.csv,
results/lid.csv and prints markdown tables.
"""
import csv
import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

import jiwer

B = Path(sys.argv[1]).resolve()
R = B / "results"
manifest = {}
for l in open(B / "data/sets/manifest.jsonl", encoding="utf-8"):
    m = json.loads(l)
    manifest[f"{m['set']}/{m['utt']}"] = m

APOS = re.compile(r"['’ʼ`´‘]")


def norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower().replace("ё", "е")
    s = APOS.sub("", s)
    s = "".join(" " if unicodedata.category(c)[0] in "PSC" else c for c in s)
    return re.sub(r"\s+", " ", s).strip()


def errs(ref, hyp):
    """word errors, ref words, char errors, ref chars (chars without spaces)"""
    r, h = norm(ref), norm(hyp)
    if not r:
        return 0, 0, 0, 0
    wo = jiwer.process_words(r, h if h else "")
    we = wo.substitutions + wo.deletions + wo.insertions
    rc, hc = r.replace(" ", ""), h.replace(" ", "")
    co = jiwer.process_words(" ".join(rc), " ".join(hc) if hc else "")  # each char = one token
    ce = co.substitutions + co.deletions + co.insertions
    return we, len(r.split()), ce, len(rc)


def script_words(s):
    """count Cyrillic-script and Latin-script words"""
    cyr = lat = 0
    for w in norm(s).split():
        if re.search(r"[а-яіїєґ]", w):
            cyr += 1
        elif re.search(r"[a-z]", w):
            lat += 1
    return cyr, lat


LANG_ALIASES = {"russian": "ru", "ukrainian": "uk", "english": "en"}

rows = []
for f in sorted((R / "raw").glob("*.jsonl")):
    engine = f.stem
    for l in open(f, encoding="utf-8"):
        h = json.loads(l)
        if engine.startswith("whisper"):
            # whisper-server joins its (~60-char, sometimes mid-word) segments with "\n"; segment text
            # already carries the leading space of a new word, so the newline itself is not a word break.
            h["text"] = (h.get("text") or "").replace("\n", "")
        m = manifest[h["utt"]]
        we, nw, ce, nc = errs(m["ref"], h.get("text", ""))
        det = h.get("detected")
        det = LANG_ALIASES.get(det, det)
        lang = m["lang"]
        if m["set"] == "codeswitch":  # group both orders: ru+en / en+ru -> ru+en
            lang = [x for x in m["part_langs"] if x != "en"][0] + "+en"
        rows.append(dict(engine=engine, set=m["set"], lang=lang, order=m["lang"], utt=h["utt"], dur=m["dur"],
                         proc_sec=h.get("proc_sec"), word_err=we, ref_words=nw, char_err=ce, ref_chars=nc,
                         wer=round(we / nw, 4) if nw else 0, detected=det or "",
                         error=h.get("error", ""), ref=norm(m["ref"]), hyp=norm(h.get("text", "")),
                         hyp_raw=h.get("text", "").strip()))

with open(R / "per_utt.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

# --- WER/CER summary (corpus-level: total errors / total reference units)
agg = defaultdict(lambda: [0, 0, 0, 0, 0, 0.0, 0.0, 0])
for r in rows:
    a = agg[(r["engine"], r["set"], r["lang"])]
    a[0] += r["word_err"]; a[1] += r["ref_words"]; a[2] += r["char_err"]; a[3] += r["ref_chars"]
    a[4] += 1; a[5] += r["dur"]; a[6] += r["proc_sec"] or 0; a[7] += 1 if r["error"] else 0
summary = []
for (e, s, lg), a in sorted(agg.items()):
    summary.append(dict(engine=e, set=s, lang=lg, n=a[4], wer=round(100 * a[0] / a[1], 2),
                        cer=round(100 * a[2] / a[3], 2), audio_sec=round(a[5], 1),
                        proc_sec=round(a[6], 2), rtf=round(a[6] / a[5], 4), errors=a[7]))
with open(R / "summary.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
    w.writeheader()
    w.writerows(summary)

# --- language ID (engines that report a detected language)
lid = []
for e in sorted({r["engine"] for r in rows if r["detected"]}):
    for s in ("clean", "call", "long", "codeswitch"):
        for lg in ("ru", "uk", "en", "ru+en", "uk+en"):
            rs = [r for r in rows if r["engine"] == e and r["set"] == s and r["lang"] == lg]
            if not rs:
                continue
            # code-switch: "correct" = detected the language of the first half
            ok = sum(1 for r in rs if r["detected"] == r["order"].split("+")[0])
            confused = defaultdict(int)
            for r in rs:
                if r["detected"] != r["order"].split("+")[0]:
                    confused[r["detected"]] += 1
            lid.append(dict(engine=e, set=s, lang=lg, n=len(rs), correct=ok,
                            wrong=";".join(f"{k}:{v}" for k, v in confused.items())))
if lid:
    with open(R / "lid.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(lid[0].keys()))
        w.writeheader()
        w.writerows(lid)

# --- code-switch: per-part recall + script balance
cs = []
for r in rows:
    if r["set"] != "codeswitch":
        continue
    m = manifest[r["utt"]]
    hyp_words = norm(r["hyp_raw"]).split()
    hyp_bag = defaultdict(int)
    for wd in hyp_words:
        hyp_bag[wd] += 1
    rec = {}
    for part, pl in zip(m["ref_parts"], m["part_langs"]):
        pw = norm(part).split()
        bag = dict(hyp_bag)
        hit = 0
        for wd in pw:
            if bag.get(wd, 0) > 0:
                bag[wd] -= 1
                hit += 1
        rec["en" if pl == "en" else "slavic"] = hit / len(pw)
    rc, rl = script_words(m["ref"])
    hc, hl = script_words(r["hyp_raw"])
    verdict = "ok"
    if rec["slavic"] < 0.3 and rec["en"] < 0.3:
        verdict = "both_lost"
    elif rec["slavic"] < 0.3:
        verdict = "slavic_part_lost" + ("_translated_to_en" if hl > rl * 1.4 else "")
    elif rec["en"] < 0.3:
        verdict = "en_part_lost" + ("_translated_or_transliterated" if hc > rc * 1.2 else "")
    elif rec["slavic"] < 0.7 or rec["en"] < 0.7:
        verdict = "partial"
    cs.append(dict(engine=r["engine"], utt=r["utt"], order=r["order"], wer=r["wer"],
                   recall_slavic=round(rec["slavic"], 2), recall_en=round(rec["en"], 2),
                   ref_cyr=rc, ref_lat=rl, hyp_cyr=hc, hyp_lat=hl, detected=r["detected"], verdict=verdict))
if cs:
    with open(R / "codeswitch.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(cs[0].keys()))
        w.writeheader()
        w.writerows(cs)

# --- print markdown tables
engines = sorted({r["engine"] for r in rows})
S = {(s["engine"], s["set"], s["lang"]): s for s in summary}


def cell(e, s, lg, key="wer"):
    x = S.get((e, s, lg))
    return f"{x[key]:.1f}" if x else "—"


print("\n## WER % (CER %)\n")
cols = [("clean", "ru"), ("clean", "uk"), ("clean", "en"), ("call", "ru"), ("call", "uk"), ("call", "en"),
        ("long", "ru"), ("long", "uk"), ("long", "en"), ("codeswitch", "ru+en"), ("codeswitch", "uk+en")]
print("| engine | " + " | ".join(f"{s} {lg}" for s, lg in cols) + " |")
print("|---" * (len(cols) + 1) + "|")
for e in engines:
    print(f"| {e} | " + " | ".join(
        f"{cell(e, s, lg)} ({cell(e, s, lg, 'cer')})" if (e, s, lg) in S else "—" for s, lg in cols) + " |")

print("\n## Speed (RTF = processing time / audio time; lower is faster)\n")
print("| engine | RTF short clean (all langs) | long ru RTF | long uk RTF | long en RTF | long total proc s |")
print("|---|---|---|---|---|---|")
speed = []
for e in engines:
    sc = [S[(e, "clean", lg)] for lg in ("ru", "uk", "en") if (e, "clean", lg) in S]
    short_rtf = sum(x["proc_sec"] for x in sc) / sum(x["audio_sec"] for x in sc) if sc else None
    lg_rtf = {lg: S[(e, "long", lg)]["rtf"] if (e, "long", lg) in S else None for lg in ("ru", "uk", "en")}
    lt = sum(S[(e, "long", lg)]["proc_sec"] for lg in ("ru", "uk", "en") if (e, "long", lg) in S)
    speed.append(dict(engine=e, short_clean_rtf=round(short_rtf, 4) if short_rtf else "",
                      **{f"long_{k}_rtf": v if v is not None else "" for k, v in lg_rtf.items()},
                      long_total_proc_sec=round(lt, 1)))
    fmt = lambda v: f"{v:.3f}" if isinstance(v, float) else "—"
    print(f"| {e} | {fmt(short_rtf)} | {fmt(lg_rtf['ru'])} | {fmt(lg_rtf['uk'])} | {fmt(lg_rtf['en'])} | {lt:.1f} |")
with open(R / "speed.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(speed[0].keys()))
    w.writeheader()
    w.writerows(speed)

if lid:
    print("\n## Language ID (correct / n)\n")
    for x in lid:
        print(f"- {x['engine']} {x['set']} {x['lang']}: {x['correct']}/{x['n']} {x['wrong']}")
if cs:
    print("\n## Code-switch verdicts\n")
    for e in sorted({c["engine"] for c in cs}):
        cc = [c for c in cs if c["engine"] == e]
        v = defaultdict(int)
        for c in cc:
            v[c["order"] + ":" + c["verdict"]] += 1
        rs = sum(c["recall_slavic"] for c in cc) / len(cc)
        re_ = sum(c["recall_en"] for c in cc) / len(cc)
        print(f"- {e}: {dict(v)}  mean recall slavic={rs:.2f} en={re_:.2f}")

# --- clean speed pass (scripts/run_speed.sh): long-form files only, nothing else running
SP = R / "raw_speed"
if SP.exists():
    def peak_rss(cfg):
        """max resident set size (MB) from /usr/bin/time -l; whisper: the server's own log"""
        best = None
        for p in [R / "logs_speed" / f"{cfg}.log", SP / f"{cfg}.server.log"]:
            if p.exists():
                for line in open(p, errors="ignore"):
                    if "maximum resident set size" in line:
                        v = int(line.split()[0]) / 1e6
                        best = v if best is None else max(best, v)
        return best
    print("\n## Clean speed pass on long-form files (RTF = processing / audio; x-real-time = 1/RTF)\n")
    print("| engine | ru RTF | uk RTF | en RTF | total audio s | total proc s | x real-time | peak RSS MB |")
    print("|---|---|---|---|---|---|---|---|")
    sp_rows = []
    for f in sorted(SP.glob("*.jsonl")):
        recs = {json.loads(l)["utt"]: json.loads(l) for l in open(f, encoding="utf-8")}
        rtf, ta, tp = {}, 0.0, 0.0
        for lg in ("ru", "uk", "en"):
            key = {"ru": "long/ru_ru_long", "uk": "long/uk_ua_long", "en": "long/en_us_long"}[lg]
            if key in recs:
                d = manifest[key]["dur"]
                rtf[lg] = recs[key]["proc_sec"] / d
                ta += d
                tp += recs[key]["proc_sec"]
        mem = peak_rss(f.stem)
        sp_rows.append(dict(engine=f.stem, **{f"{k}_rtf": round(v, 4) for k, v in rtf.items()},
                            audio_sec=round(ta, 1), proc_sec=round(tp, 1),
                            x_realtime=round(ta / tp, 1) if tp else "", peak_rss_mb=round(mem) if mem else ""))
        g = lambda k: f"{rtf[k]:.3f}" if k in rtf else "—"
        print(f"| {f.stem} | {g('ru')} | {g('uk')} | {g('en')} | {ta:.0f} | {tp:.1f} | "
              f"{(ta / tp if tp else 0):.0f}x | {round(mem) if mem else '—'} |")
    with open(R / "speed_clean.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, restval="", fieldnames=["engine", "ru_rtf", "uk_rtf", "en_rtf", "audio_sec",
                                                         "proc_sec", "x_realtime", "peak_rss_mb"])
        w.writeheader()
        w.writerows(sp_rows)
