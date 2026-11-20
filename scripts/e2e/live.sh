#!/bin/zsh
# E2E — live transcript in the Live window. A call (macOS voices: ru, en, uk, es)
# plays through the speakers during a recording; every phrase must appear in the
# live transcript within seconds, "Them" on the call track, the mic's echo of it
# hidden, and the Live window must be on screen (its snapshots).
# Optional: E2E_TRANSLATE=ru translates live into that language, E2E_TRANSLATE_FROM=en
# from that one (unset: Auto, the line's language among E2E_LANGUAGES); lines in the
# target stay as they are, the others come translated. Needs the language packs
# (Granula → Translation…). The owner's own choices are not used and not changed.
# GRANULA_APP=<path> runs another build instead of /Applications/Granula.app.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
LANGUAGES=${E2E_LANGUAGES:-ru,en,uk,es}
if [[ -n "${E2E_TRANSLATE_FROM:-}" && -z "${E2E_TRANSLATE:-}" ]]; then
  echo "FAIL E2E_TRANSLATE_FROM needs E2E_TRANSLATE: From is off without a To"; exit 1
fi

python3 -I "$ROOT/scripts/e2e/make_live_audio.py" "$WORK"
CALL_SECONDS=$(python3 -I -c "import wave,sys;w=wave.open(sys.argv[1]);print(int(w.getnframes()/w.getframerate())+1)" "$WORK/call.wav")
# The app counts the stop from the moment the speech model is ready (live.ready).
STOP_AFTER=$((CALL_SECONDS + 12))

quit_granula
log_mark
trap restore_granula EXIT
# Snapshots of an earlier run in a reused E2E_WORK must not count.
rm -rf "$WORK/shots"
ARGS=(--e2e-start --e2e-stop-after $STOP_AFTER --e2e-live-window --e2e-live-snapshots "$WORK/shots"
      --e2e-languages "$LANGUAGES")
[[ -n "${E2E_TRANSLATE:-}" ]] && ARGS+=(--e2e-translate "$E2E_TRANSLATE")
[[ -n "${E2E_TRANSLATE_FROM:-}" ]] && ARGS+=(--e2e-translate-from "$E2E_TRANSLATE_FROM")
open -n "$APP" --args "${ARGS[@]}"
line=$(wait_event recording.started 30) || { echo "FAIL recording did not start"; new_log; exit 1; }
DIR=$MEETINGS/${line##*folder=}
echo "meeting: $DIR"
ready=$(wait_event live.ready 90) || { echo "FAIL live transcript not ready"; new_log | grep -E "live\.|asr\." ; exit 1; }
# Line times count from the meeting's start (origin=, epoch seconds), not from this log line.
ORIGIN=${ready##*origin=}
sleep 1
PLAYED=$(python3 -I -c "import time;print(time.time())")
afplay "$WORK/call.wav"
OFFSET=$(python3 -I -c "import sys;print(float(sys.argv[1])-float(sys.argv[2]))" "$PLAYED" "$ORIGIN")
wait_event live.finished $((STOP_AFTER + 60)) || { echo "FAIL live transcript did not finish"; exit 1; }
new_log | grep -E "live\.|live_window\.|translation\.|e2e\.snapshot" || true
shots=("$WORK/shots"/window-*.png(N))
(( ${#shots} > 0 )) || { echo "FAIL the Live window was not on screen (no window-N.png)"; exit 1; }
echo "ok   Live window on screen: ${#shots} snapshots"
python3 -I "$ROOT/scripts/e2e/check_live.py" "$DIR" "$WORK/phrases.json" "$OFFSET" \
  "${E2E_TRANSLATE:-}" "${E2E_TRANSLATE_FROM:-}" "$LANGUAGES"
echo "snapshots: $WORK/shots"
echo "status: $(wait_processed "$DIR")"
