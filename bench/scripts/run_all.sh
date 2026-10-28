#!/bin/zsh
# Run every engine configuration one after another (never in parallel: timings matter).
# Usage: zsh scripts/run_all.sh [config ...]            (no args = all configs)
#        LIST=data/lists/x.tsv RAW=results/raw_x zsh scripts/run_all.sh [config ...]
#          -> every config runs on that one list instead of its default list
# Output: $RAW/<config>.jsonl (default results/raw), logs with /usr/bin/time -l in results/logs/.
set -u
B=${0:A:h:h}
cd "$B"
PY=".venv/bin/python -I"
L_ALL=${LIST:-data/lists/all.tsv}
L_SHORT=${LIST:-data/lists/short.tsv}
L_CS=${LIST:-data/lists/codeswitch.tsv}
L_LONG=${LIST:-data/lists/long.tsv}
R=${RAW:-results/raw}
G=results/logs/${R:t}
mkdir -p $R $G
P=scripts/swift/parakeet-runner/.build/release
W=models/whisper-ggml
VAD="-mc 0 --vad -vm $W/ggml-silero-v5.1.2.bin"
ONLY="${*:-}"

run() {  # run <config> <command...>
  local cfg=$1; shift
  if [[ -n "$ONLY" && " $ONLY " != *" $cfg "* ]]; then return; fi
  echo "=== $cfg $(date '+%H:%M:%S')"
  /usr/bin/time -l "$@" > $G/$cfg.log 2>&1
  echo "    exit $? $(date '+%H:%M:%S')  $(grep -c . $R/$cfg.jsonl 2>/dev/null) rows"
}

run parakeet-v3          $P/parakeet-runner models/fluidaudio/parakeet-tdt-0.6b-v3 $L_ALL $R/parakeet-v3.jsonl
run parakeet-v3-hint     $P/parakeet-runner models/fluidaudio/parakeet-tdt-0.6b-v3 $L_ALL $R/parakeet-v3-hint.jsonl --lang-hint
run parakeet-ultra       $P/parakeet-runner models/fluidaudio/parakeet-ultra $L_ALL $R/parakeet-ultra.jsonl --version ultra
run canary-1b-v2         $P/canary-runner models/fluidaudio/canary-1b-v2 $L_ALL $R/canary-1b-v2.jsonl --units gpu
run whisper-turbo-auto   ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3-turbo.bin $L_ALL $R/whisper-turbo-auto.jsonl --lang auto
run whisper-turbo-forced ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3-turbo.bin $L_ALL $R/whisper-turbo-forced.jsonl --lang forced
run whisper-turbo-forced-vad ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3-turbo.bin $L_LONG $R/whisper-turbo-forced-vad.jsonl --lang forced --server-args "$VAD"
run whisper-turbo-forced-chunk28 ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3-turbo.bin $L_LONG $R/whisper-turbo-forced-chunk28.jsonl --lang forced --chunk 28
run whisper-large-v3-forced ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3.bin $L_ALL $R/whisper-large-v3-forced.jsonl --lang forced
run whisper-large-v3-auto ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3.bin $L_CS $R/whisper-large-v3-auto.jsonl --lang auto
run whisper-large-v3-forced-vad ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3.bin $L_LONG $R/whisper-large-v3-forced-vad.jsonl --lang forced --server-args "$VAD"
run whisper-large-v3-forced-chunk28 ${=PY} scripts/run_whisper_cpp.py $W/ggml-large-v3.bin $L_LONG $R/whisper-large-v3-forced-chunk28.jsonl --lang forced --chunk 28
run qwen3-asr-0.6b-auto  scripts/swift/qwen3-runner/.build/release/qwen3-runner models/fluidaudio/qwen3-asr-0.6b-int8 $L_ALL $R/qwen3-asr-0.6b-auto.jsonl --lang auto
run qwen3-asr-0.6b-forced scripts/swift/qwen3-runner/.build/release/qwen3-runner models/fluidaudio/qwen3-asr-0.6b-int8 $L_SHORT $R/qwen3-asr-0.6b-forced.jsonl --lang forced
run gigaam-v3-e2e-rnnt   ${=PY} scripts/run_gigaam.py v3_e2e_rnnt $L_ALL $R/gigaam-v3-e2e-rnnt.jsonl
run gigaam-multilingual-large-ctc ${=PY} scripts/run_gigaam.py multilingual_large_ctc $L_ALL $R/gigaam-multilingual-large-ctc.jsonl
run apple-dictation      models/apple-dictation $L_ALL $R/apple-dictation.jsonl
echo "=== done $(date '+%H:%M:%S')"
