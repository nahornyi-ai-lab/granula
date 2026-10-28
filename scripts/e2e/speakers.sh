#!/bin/zsh
# E2E-1 — a call through the speakers. The installed app is launched through
# LaunchServices (`open`), so it runs with its own permissions; the test call
# (FLEURS ru+uk+en) plays through the speakers, the mic hears it as echo.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}

python3 -I "$ROOT/scripts/e2e/make_call_audio.py" "$ROOT/bench" "$WORK"
echo "output device: $(system_profiler SPAudioDataType 2>/dev/null | awk '/Default Output Device: Yes/{print prev} {prev=$0}' | head -1 | sed 's/^ *//;s/:$//')"
echo "volume: $(osascript -e 'output volume of (get volume settings)'), muted: $(osascript -e 'output muted of (get volume settings)')"

quit_granula
log_mark
trap restore_granula EXIT
open -n "$APP" --args --e2e-start --e2e-stop-after 78
line=$(wait_event recording.started 30) || { echo "FAIL recording did not start"; new_log; exit 1; }
DIR=~/Documents/Granula/${line##*folder=}
echo "meeting: $DIR"
sleep 3
afplay "$WORK/call.wav"
echo "status: $(wait_processed "$DIR")"
new_log | grep -E "recording\.|transcript|asr\.|summary\.|mic\.|system\.|track\." || true
python3 -I "$ROOT/scripts/e2e/check_meeting.py" "$DIR" "$WORK/reference.txt"
