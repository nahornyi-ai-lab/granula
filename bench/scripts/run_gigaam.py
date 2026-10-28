"""Run Sber GigaAM (PyTorch, official `gigaam` package from GitHub) over a TSV file list.

GigaAM v3 is Russian-only, so by default only rows whose lang contains "ru" are processed
(code-switch ru+en rows included, to see what happens to the English half). The multilingual
models (`multilingual_*`) process every row.
GigaAM's short-form API accepts <= 25 s; longer files are cut into <= 22 s chunks at the
quietest 100 ms frame in the last 3 s before the limit, and the chunk texts are joined.

Usage: .venv/bin/python -I scripts/run_gigaam.py <model_name> <list.tsv> <out.jsonl> \
           [--device mps|cpu] [--all-langs]
"""
import argparse
import json
import sys
import time

import numpy as np
import soundfile as sf
import torch

import gigaam

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("list")
ap.add_argument("out")
ap.add_argument("--device", default="mps")
ap.add_argument("--all-langs", action="store_true")
ap.add_argument("--root", default="models/gigaam")
a = ap.parse_args()

SR = 16000
MAX = 22 * SR


def chunks(x):
    res, start, frame, search = [], 0, SR // 10, 3 * SR
    while len(x) - start > MAX:
        best, best_e = start + MAX, float("inf")
        p = start + MAX - search
        while p + frame <= start + MAX:
            e = float(np.sum(x[p:p + frame] ** 2))
            if e < best_e:
                best_e, best = e, p + frame // 2
            p += frame // 2
        res.append(x[start:best])
        start = best
    res.append(x[start:])
    return res


t0 = time.time()
model = gigaam.load_model(a.model, device=a.device, download_root=a.root)
print(f"loaded {a.model} on {a.device} in {time.time() - t0:.1f}s", file=sys.stderr)


@torch.inference_mode()
def run(x):
    wav = torch.from_numpy(x).to(model._device).to(model._dtype).unsqueeze(0)
    length = torch.full([1], wav.shape[-1], device=model._device)
    enc, enc_len = model.forward(wav, length)
    text, _ = model._decode(enc, enc_len, length, False)[0]
    return text


rows = [l.rstrip("\n").split("\t") for l in open(a.list, encoding="utf-8") if l.strip()]
if not (a.all_langs or a.model.startswith("multilingual")):
    rows = [r for r in rows if "ru" in r[2]]
x0, _ = sf.read(rows[0][1], dtype="float32")
run(x0[: 5 * SR])  # warm-up
with open(a.out, "w", encoding="utf-8") as out:
    for utt, path, lang in rows:
        s = time.time()
        rec = dict(utt=utt)
        try:
            x, sr = sf.read(path, dtype="float32")
            assert sr == SR
            parts = chunks(x)
            rec["text"] = " ".join(run(c) for c in parts)
            rec["n_chunks"] = len(parts)
            rec["audio_sec"] = len(x) / SR
        except Exception as e:
            rec["text"], rec["error"] = "", repr(e)
        if a.device == "mps":
            torch.mps.synchronize()
        rec["proc_sec"] = time.time() - s
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
