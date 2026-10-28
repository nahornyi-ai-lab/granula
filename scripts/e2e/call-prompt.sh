#!/bin/zsh
# E2E-2 — call prompt and auto-stop. QuickTime Player plays the "call app":
# it is added to extraCallApps for the test, records audio (holds the mic),
# Granula must offer to record, record, and stop ~15 s after QuickTime stops.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}

defaults write ai.nahornyi.granula extraCallApps -array com.apple.QuickTimePlayerX
trap 'defaults delete ai.nahornyi.granula extraCallApps 2>/dev/null || true; restore_granula' EXIT

quit_granula
log_mark
open -n "$APP" --args --e2e-accept-call-prompt
sleep 3
osascript -e 'tell application "QuickTime Player"' -e 'set d to new audio recording' -e 'start d' -e 'end tell'
shown=$(wait_event call.prompt_shown 20) || { echo "FAIL no call prompt"; new_log; exit 1; }
echo "$shown"
screencapture -x "$WORK/prompt.png" 2>/dev/null && echo "screenshot: $WORK/prompt.png" || echo "screenshot: not allowed here"
line=$(wait_event recording.started 20) || { echo "FAIL recording did not start from the prompt"; new_log; exit 1; }
DIR=~/Documents/Granula/${line##*folder=}
echo "meeting: $DIR"
sleep 15
osascript -e 'tell application "QuickTime Player"' -e 'stop document 1' -e 'close every document saving no' -e 'quit' -e 'end tell' || true
off=$(wait_event "call.mic_off app=com.apple.QuickTimePlayerX" 20) || { echo "FAIL mic release not seen"; new_log; exit 1; }
stop=$(wait_event recording.autostop 40) || { echo "FAIL no auto-stop"; new_log; exit 1; }
delay=$(python3 -I -c "print(round($(epoch ${stop%% *}) - $(epoch ${off%% *}), 1))")
echo "auto-stop ${delay} s after QuickTime released the mic"
echo "status: $(wait_processed "$DIR")"
new_log | grep -E "call\.|recording\.|summary\.|transcript" || true
ok=1
[[ $(meeting_status "$DIR") == done ]] || ok=0
python3 -I -c "import sys; sys.exit(0 if 13 <= $delay <= 20 else 1)" || ok=0
[[ $ok == 1 ]] && echo "PASS E2E-2" || { echo "FAIL E2E-2"; exit 1; }
