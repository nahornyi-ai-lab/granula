#!/bin/zsh
# E2E — live hints in the Live window. The other side (macOS voices, through the speakers)
# says "Okay, got it." (no reply expected) and then a request about a timeline; during the
# recording the app must suggest a reply only to the request, using the "About me" fact.
# Optional: E2E_TRANSLATE=ru adds a Russian question and translates hints into Russian.
# Needs the OpenRouter key saved in Granula → Hints… and network.
# The owner's own settings are not used and not changed. GRANULA_APP=<path> runs another build.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
if [[ ! -s "$HOME/Library/Application Support/Granula/openrouter-api-key" ]]; then
  echo "FAIL the OpenRouter key is not saved (Granula → Hints…)"; exit 1
fi
LANGUAGES=en
[[ -n "${E2E_TRANSLATE:-}" ]] && LANGUAGES=en,$E2E_TRANSLATE
ABOUT="I lead the platform team at a small logistics startup. The database migration is planned for March, in two phases."

python3 -I "$ROOT/scripts/e2e/make_hints_audio.py" "$WORK" "${E2E_TRANSLATE:-}"
CALL_SECONDS=$(python3 -I -c "import wave,sys;w=wave.open(sys.argv[1]);print(int(w.getnframes()/w.getframerate())+1)" "$WORK/call.wav")
# The app counts the stop from the moment the speech model is ready (live.ready).
STOP_AFTER=$((CALL_SECONDS + 15))

quit_granula
log_mark
trap restore_granula EXIT
# Files of an earlier run in a reused E2E_WORK must not count.
rm -rf "$WORK/shots" "$WORK/hints.json"
ARGS=(--e2e-start --e2e-stop-after $STOP_AFTER --e2e-live-window --e2e-live-snapshots "$WORK/shots"
      --e2e-languages "$LANGUAGES" --e2e-hints-out "$WORK/hints.json" --e2e-hints-about "$ABOUT")
[[ -n "${E2E_TRANSLATE:-}" ]] && ARGS+=(--e2e-translate "$E2E_TRANSLATE")
open -n "$APP" --args "${ARGS[@]}"
# After an ad-hoc reinstall macOS first asks for the microphone and system-audio permissions.
line=$(wait_event recording.started 120) || { echo "FAIL recording did not start (permissions?)"; new_log; exit 1; }
DIR=$MEETINGS/${line##*folder=}
echo "meeting: $DIR"
wait_event live.ready 90 >/dev/null || { echo "FAIL live transcript not ready"; new_log | grep -E "live\.|asr\." ; exit 1; }
sleep 1
afplay "$WORK/call.wav"
wait_event live.finished $((STOP_AFTER + 60)) || { echo "FAIL live transcript did not finish"; exit 1; }
new_log | grep -E "hint\." || true
new_log > "$WORK/new.log"
python3 -I "$ROOT/scripts/e2e/check_hints.py" "$DIR" "$WORK/hints.json" "$WORK/phrases.json" \
  "$WORK/new.log" "$WORK/shots" "${E2E_TRANSLATE:-}"
echo "work: $WORK"
