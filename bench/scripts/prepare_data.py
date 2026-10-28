"""Build the STT benchmark sets from FLEURS test split (ru_ru, uk_ua, en_us).

Selection rule (deterministic): for each language, take unique sentence ids in ascending
numeric order; for each id take the first row (TSV order) whose duration is 5-20 s;
keep the first N_PER_LANG ids.

Outputs (under bench/data/sets/):
  clean/<lang>/<id>.wav         original FLEURS audio, 16 kHz mono PCM16
  call/<lang>/<id>.wav          Opus 16 kbps VOIP round-trip of the same clip
  codeswitch/<name>.wav         ru|uk clip + 0.5 s silence + en clip (and en + ru|uk)
  long/<lang>_long.wav          first N_LONG clean clips joined with 0.3 s silence
  manifest.jsonl                one row per test file with reference text

Usage: .venv/bin/python -I scripts/prepare_data.py <bench_dir>
"""

import csv
import json
import subprocess
import sys
import tarfile
from pathlib import Path

import numpy as np
import soundfile as sf

N_PER_LANG = 40
N_LONG = 25
LANGS = ["ru_ru", "uk_ua", "en_us"]
SR = 16000

bench = Path(sys.argv[1]).resolve()
raw = bench / "data" / "fleurs_raw" / "data"
out = bench / "data" / "sets"
csv.field_size_limit(10**9)


def select(lang):
    rows = []
    with open(raw / lang / "test.tsv", encoding="utf-8") as f:
        for r in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            rows.append(r)
    by_id = {}
    for r in rows:
        sid, fname, raw_tr, norm_tr, _, nsamp, gender = r
        dur = int(nsamp) / SR
        if 5.0 <= dur <= 20.0 and int(sid) not in by_id:
            by_id[int(sid)] = dict(
                sentence_id=int(sid), file=fname, raw=raw_tr, ref=norm_tr, dur=dur, gender=gender
            )
    return [by_id[k] for k in sorted(by_id)[:N_PER_LANG]]


def extract(lang, items, dest):
    dest.mkdir(parents=True, exist_ok=True)
    wanted = {"test/" + it["file"]: it for it in items}
    with tarfile.open(raw / lang / "audio" / "test.tar.gz", "r:gz") as tf:
        for m in tf:
            if m.name in wanted and m.isfile():
                data = tf.extractfile(m).read()
                tmp = dest / ("_tmp_" + Path(m.name).name)
                tmp.write_bytes(data)
                audio, sr = sf.read(tmp, dtype="float32")
                tmp.unlink()
                if audio.ndim > 1:
                    audio = audio.mean(axis=1)
                assert sr == SR, (m.name, sr)
                it = wanted[m.name]
                sf.write(dest / f"{it['sentence_id']}.wav", audio, SR, subtype="PCM_16")
    missing = [it for it in items if not (dest / f"{it['sentence_id']}.wav").exists()]
    assert not missing, missing


def call_quality(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    opus = dst.with_suffix(".opus")
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(src), "-ac", "1", "-ar", "16000",
         "-c:a", "libopus", "-b:a", "16k", "-application", "voip", str(opus)], check=True)
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(opus), "-ac", "1", "-ar", "16000",
         "-c:a", "pcm_s16le", str(dst)], check=True)
    opus.unlink()


def read(p):
    a, sr = sf.read(p, dtype="float32")
    assert sr == SR
    return a


def silence(sec):
    return np.zeros(int(sec * SR), dtype=np.float32)


manifest = []
sel = {}
for lang in LANGS:
    items = select(lang)
    sel[lang] = items
    extract(lang, items, out / "clean" / lang)
    for it in items:
        c = out / "clean" / lang / f"{it['sentence_id']}.wav"
        k = out / "call" / lang / f"{it['sentence_id']}.wav"
        call_quality(c, k)
        for cond, p in (("clean", c), ("call", k)):
            manifest.append(dict(set=cond, lang=lang[:2], utt=f"{lang}_{it['sentence_id']}", path=str(p),
                                 ref=it["ref"], ref_raw=it["raw"], dur=it["dur"], fleurs_file=it["file"]))
    print(lang, len(items), "clips, total", round(sum(i["dur"] for i in items), 1), "s")

# code-switch: 10 x (ru_i + en_{20+i}), 5 x (uk_i + en_{30+i}), plus reversed order
# 5 x (en_i + ru_{20+i}), 5 x (en_{5+i} + uk_{20+i}). FLEURS is a parallel corpus, so the two
# halves must be different sentences (asserted below).
cs_dir = out / "codeswitch"
cs_dir.mkdir(parents=True, exist_ok=True)
pairs = ([("ru_ru", i, "en_us", 20 + i) for i in range(10)] + [("uk_ua", i, "en_us", 30 + i) for i in range(5)]
         + [("en_us", i, "ru_ru", 20 + i) for i in range(5)] + [("en_us", 5 + i, "uk_ua", 20 + i) for i in range(5)])
for la, ia, lb, ib in pairs:
    a, b = sel[la][ia], sel[lb][ib]
    assert a["sentence_id"] != b["sentence_id"]
    wav = np.concatenate([read(out / "clean" / la / f"{a['sentence_id']}.wav"), silence(0.5),
                          read(out / "clean" / lb / f"{b['sentence_id']}.wav")])
    name = f"cs_{la[:2]}_{lb[:2]}_{a['sentence_id']}_{b['sentence_id']}"
    p = cs_dir / f"{name}.wav"
    sf.write(p, wav, SR, subtype="PCM_16")
    manifest.append(dict(set="codeswitch", lang=f"{la[:2]}+{lb[:2]}", utt=name, path=str(p),
                         ref=a["ref"] + " " + b["ref"], ref_parts=[a["ref"], b["ref"]],
                         part_langs=[la[:2], lb[:2]], dur=len(wav) / SR))

# long-form: first N_LONG clips per language
long_dir = out / "long"
long_dir.mkdir(parents=True, exist_ok=True)
for lang in LANGS:
    items = sel[lang][:N_LONG]
    chunks = []
    for it in items:
        chunks += [read(out / "clean" / lang / f"{it['sentence_id']}.wav"), silence(0.3)]
    wav = np.concatenate(chunks)
    p = long_dir / f"{lang}_long.wav"
    sf.write(p, wav, SR, subtype="PCM_16")
    manifest.append(dict(set="long", lang=lang[:2], utt=f"{lang}_long", path=str(p),
                         ref=" ".join(it["ref"] for it in items), dur=len(wav) / SR,
                         sentence_ids=[it["sentence_id"] for it in items]))
    print(lang, "long", round(len(wav) / SR, 1), "s")

with open(out / "manifest.jsonl", "w", encoding="utf-8") as f:
    for m in manifest:
        f.write(json.dumps(m, ensure_ascii=False) + "\n")
with open(bench / "results" / "selected_fleurs_ids.json", "w", encoding="utf-8") as f:
    json.dump({l: [dict(sentence_id=i["sentence_id"], file=i["file"], dur=round(i["dur"], 2)) for i in v]
               for l, v in sel.items()}, f, ensure_ascii=False, indent=1)
print("manifest rows:", len(manifest))
