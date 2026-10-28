#!/bin/zsh
# Clean speed pass: every engine on the three ~5-minute long-form files only, one at a time,
# with nothing else running. Output: results/raw_speed/<config>.jsonl and results/logs_speed/<config>.log
# (the logs carry /usr/bin/time -l "maximum resident set size"; whisper-server's own is in
# results/raw_speed/<config>.server.log).
# Usage: zsh scripts/run_speed.sh [config ...]   (no args = all)
set -u
B=${0:A:h:h}
cd "$B"
PY=".venv/bin/python -I"
L=data/lists/long.tsv
R=results/raw_speed
G=results/logs_speed
mkdir -p $R $G
ONLY="${*:-}"
P=scripts/swift/parakeet-runner/.build/release
VAD="-mc 0 --vad -vm models/whisper-ggml/ggml-silero-v5.1.2.bin"

run() {
  local cfg=$1; shift
  if [[ -n "$ONLY" && " $ONLY " != *" $cfg "* ]]; then return; fi
  echo "=== $cfg $(date '+%H:%M:%S')"
  /usr/bin/time -l "$@" > $G/$cfg.log 2>&1
  echo "    exit $? $(date '+%H:%M:%S')"
}

run parakeet-v3             $P/parakeet-runner models/fluidaudio/parakeet-tdt-0.6b-v3 $L $R/parakeet-v3.jsonl
run parakeet-ultra          $P/parakeet-runner models/fluidaudio/parakeet-ultra $L $R/parakeet-ultra.jsonl --version ultra
run canary-1b-v2            $P/canary-runner models/fluidaudio/canary-1b-v2 $L $R/canary-1b-v2.jsonl --units gpu
run whisper-turbo-forced    ${=PY} scripts/run_whisper_cpp.py models/whisper-ggml/ggml-large-v3-turbo.bin $L $R/whisper-turbo-forced.jsonl --lang forced
run whisper-turbo-forced-vad ${=PY} scripts/run_whisper_cpp.py models/whisper-ggml/ggml-large-v3-turbo.bin $L $R/whisper-turbo-forced-vad.jsonl --lang forced --server-args "$VAD"
run whisper-turbo-forced-chunk28 ${=PY} scripts/run_whisper_cpp.py models/whisper-ggml/ggml-large-v3-turbo.bin $L $R/whisper-turbo-forced-chunk28.jsonl --lang forced --chunk 28
run whisper-large-v3-forced ${=PY} scripts/run_whisper_cpp.py models/whisper-ggml/ggml-large-v3.bin $L $R/whisper-large-v3-forced.jsonl --lang forced
run whisper-large-v3-forced-vad ${=PY} scripts/run_whisper_cpp.py models/whisper-ggml/ggml-large-v3.bin $L $R/whisper-large-v3-forced-vad.jsonl --lang forced --server-args "$VAD"
run whisper-large-v3-forced-chunk28 ${=PY} scripts/run_whisper_cpp.py models/whisper-ggml/ggml-large-v3.bin $L $R/whisper-large-v3-forced-chunk28.jsonl --lang forced --chunk 28
run qwen3-asr-0.6b-auto     scripts/swift/qwen3-runner/.build/release/qwen3-runner models/fluidaudio/qwen3-asr-0.6b-int8 $L $R/qwen3-asr-0.6b-auto.jsonl --lang auto
run gigaam-v3-e2e-rnnt      ${=PY} scripts/run_gigaam.py v3_e2e_rnnt $L $R/gigaam-v3-e2e-rnnt.jsonl
run gigaam-multilingual-large-ctc ${=PY} scripts/run_gigaam.py multilingual_large_ctc $L $R/gigaam-multilingual-large-ctc.jsonl
run apple-dictation         models/apple-dictation $L $R/apple-dictation.jsonl
echo "=== done $(date '+%H:%M:%S')"
