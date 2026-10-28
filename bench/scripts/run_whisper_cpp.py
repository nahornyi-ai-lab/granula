"""Run whisper.cpp (Homebrew whisper-server, Metal) over a TSV file list.

The model is loaded once by whisper-server; each file is POSTed to /inference and the
request wall time is recorded. Peak memory of the server comes from /usr/bin/time -l.

Usage:
  .venv/bin/python -I scripts/run_whisper_cpp.py <model.bin> <list.tsv> <out.jsonl> \
      --lang auto|forced [--beam 5] [--port 8178] [--server-args "-mc 0 --vad -vm silero.bin"]
list.tsv rows: utt \t wav_path \t lang (ru|uk|en|ru+en|uk+en). With --lang forced, single-language
files get their language; mixed files (ru+en) get the first language.
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import requests
import soundfile as sf
import tempfile

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("list")
ap.add_argument("out")
ap.add_argument("--lang", choices=["auto", "forced"], required=True)
ap.add_argument("--beam", type=int, default=5)
ap.add_argument("--port", type=int, default=8178)
ap.add_argument("--threads", type=int, default=8)
ap.add_argument("--chunk", type=float, default=0,
                help="if >0: cut files longer than this many seconds at the quietest 100 ms frame in the last 3 s "
                     "before the limit and transcribe each piece as an independent request (no shared context)")
ap.add_argument("--server-args", default="", help='extra whisper-server flags, e.g. "-mc 0 --vad -vm <silero.bin>"')
a = ap.parse_args()

rows = [l.rstrip("\n").split("\t") for l in open(a.list, encoding="utf-8") if l.strip()]
log_path = Path(a.out).with_suffix(".server.log")
log = open(log_path, "w")
srv = subprocess.Popen(
    ["/usr/bin/time", "-l", "whisper-server", "-m", a.model, "--host", "127.0.0.1", "--port", str(a.port),
     "-t", str(a.threads)] + a.server_args.split(),
    stdout=log, stderr=subprocess.STDOUT)
url = f"http://127.0.0.1:{a.port}/inference"
t0 = time.time()
while True:
    try:
        requests.get(f"http://127.0.0.1:{a.port}/", timeout=1)
        break
    except Exception:
        if srv.poll() is not None:
            sys.exit("server died, see " + str(log_path))
        time.sleep(0.5)
print(f"server ready in {time.time() - t0:.1f}s", file=sys.stderr)


def infer(path, lang):
    with open(path, "rb") as f:
        r = requests.post(url, files={"file": (Path(path).name, f, "audio/wav")}, data={
            "language": lang, "beam_size": str(a.beam), "best_of": "5", "temperature": "0.0",
            "temperature_inc": "0.2", "response_format": "verbose_json"}, timeout=3600)
    r.raise_for_status()
    return r.json()


def pieces(path):
    """yield wav paths: the file itself, or temp files with <= a.chunk seconds each"""
    x, sr = sf.read(path, dtype="float32")
    max_len = int(a.chunk * sr)
    if not a.chunk or len(x) <= max_len:
        yield path
        return
    frame, search, start = sr // 10, 3 * sr, 0
    cuts = []
    while len(x) - start > max_len:
        best, best_e = start + max_len, float("inf")
        p = start + max_len - search
        while p + frame <= start + max_len:
            e = float(np.sum(x[p:p + frame] ** 2))
            if e < best_e:
                best_e, best = e, p + frame // 2
            p += frame // 2
        cuts.append((start, best))
        start = best
    cuts.append((start, len(x)))
    with tempfile.TemporaryDirectory() as td:
        for i, (b, e) in enumerate(cuts):
            q = Path(td) / f"piece{i:03d}.wav"
            sf.write(q, x[b:e], sr, subtype="PCM_16")
            yield str(q)


infer(rows[0][1], "auto")  # warm-up (Metal kernels)
with open(a.out, "w", encoding="utf-8") as out:
    for utt, path, lang in rows:
        req_lang = "auto" if a.lang == "auto" else lang.split("+")[0]
        s = time.time()
        try:
            js = [infer(q, req_lang) for q in pieces(path)]
            j = js[0]
            rec = dict(utt=utt, text=" ".join(x.get("text", "") for x in js), req_lang=req_lang, n_chunks=len(js),
                       detected=j.get("detected_language") or j.get("language"),
                       detected_p=j.get("detected_language_probability"),
                       audio_sec=sum(x.get("duration") or 0 for x in js))
        except Exception as e:  # keep going, record the failure
            rec = dict(utt=utt, text="", error=str(e), req_lang=req_lang)
        rec["proc_sec"] = time.time() - s
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        out.flush()
# stop the real server (child of /usr/bin/time) so time -l prints its peak memory
child = subprocess.run(["pgrep", "-P", str(srv.pid)], capture_output=True, text=True).stdout.split()
for pid in child:
    subprocess.run(["kill", "-INT", pid])
srv.wait()
log.close()
