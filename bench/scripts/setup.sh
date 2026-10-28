#!/bin/zsh
# One-time setup for the STT benchmark (what was done on 2026-10-16/17). Idempotent-ish: re-running
# re-downloads only what is missing. Run from anywhere: zsh bench/scripts/setup.sh
set -eu
B=${0:A:h:h}
cd "$B"
mkdir -p data models/whisper-ggml models/fluidaudio models/gigaam vendor results

# Python env (uv) — jiwer/soundfile for scoring, huggingface_hub for downloads, GigaAM from GitHub
[[ -x .venv/bin/python ]] || uv venv .venv --python 3.12
uv pip install --python .venv/bin/python jiwer soundfile numpy pandas huggingface_hub pyarrow requests \
  "gigaam @ git+https://github.com/salute-developers/GigaAM@7447938d791c4f3e643386ee22c33777004293a5"

# FLEURS test split (google/fleurs @ 70bb2e84b976b7e960aa89f1c648e09c59f894dd): TSV + audio tarballs
.venv/bin/python -I - <<'EOF'
from huggingface_hub import hf_hub_download
for l in ["ru_ru", "uk_ua", "en_us"]:
    for f in [f"data/{l}/test.tsv", f"data/{l}/audio/test.tar.gz"]:
        hf_hub_download("google/fleurs", f, repo_type="dataset", local_dir="data/fleurs_raw",
                        revision="70bb2e84b976b7e960aa89f1c648e09c59f894dd")
EOF

# Models
.venv/bin/python -I - <<'EOF'
from huggingface_hub import hf_hub_download, snapshot_download
for m in ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin"]:
    hf_hub_download("ggerganov/whisper.cpp", m, local_dir="models/whisper-ggml")
hf_hub_download("ggml-org/whisper-vad", "ggml-silero-v5.1.2.bin", local_dir="models/whisper-ggml")
snapshot_download("FluidInference/parakeet-ultra-coreml", local_dir="models/fluidaudio/parakeet-ultra",
                  revision="95eaa59a39d4394f047a4dc5cce480388a60d1b6")
snapshot_download("FluidInference/canary-1b-v2-coreml", local_dir="models/fluidaudio/canary-1b-v2",
                  revision="224631d3724c8f34c2d4d99b92e7e26cd6d2f93b", ignore_patterns=["*.npz"])
EOF
# Parakeet v3 and Qwen3-ASR int8 are copied (never moved) from another app's FluidAudio cache;
# without that cache: snapshot_download FluidInference/parakeet-tdt-0.6b-v3-coreml / qwen3-asr-0.6b-coreml (int8/).
M="$HOME/Library/Application Support/FluidAudio/Models"
[[ -d models/fluidaudio/parakeet-tdt-0.6b-v3 ]] || cp -R "$M/parakeet-tdt-0.6b-v3" models/fluidaudio/
if [[ ! -d models/fluidaudio/qwen3-asr-0.6b-int8 ]]; then
  mkdir -p models/fluidaudio/qwen3-asr-0.6b-int8
  for f in qwen3_asr_audio_encoder_v2.mlmodelc qwen3_asr_decoder_stateful.mlmodelc qwen3_asr_embeddings.bin vocab.json metadata.json; do
    cp -R "$M/qwen3-asr-0.6b/int8/$f" models/fluidaudio/qwen3-asr-0.6b-int8/
  done
fi

# Engines: whisper.cpp (Homebrew, Metal), FluidAudio (current + last commit with Qwen3-ASR)
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
[[ -d vendor/FluidAudio ]] || git clone https://github.com/FluidInference/FluidAudio.git vendor/FluidAudio
git -C vendor/FluidAudio checkout -q 2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042
[[ -d vendor/FluidAudio-qwen3 ]] || git -C vendor/FluidAudio worktree add ../FluidAudio-qwen3 2b6564251dc2b982be0f615bafd4e741066e2a05
(cd scripts/swift/parakeet-runner && swift build -c release)
(cd scripts/swift/qwen3-runner && swift build -c release)
swiftc -O -parse-as-library scripts/swift/apple-dictation/main.swift -o models/apple-dictation
for l in ru_RU uk_UA en_US; do models/apple-dictation --install $l; done

# Test sets + lists
.venv/bin/python -I scripts/prepare_data.py .
.venv/bin/python -I scripts/make_lists.py .
echo "setup done"
