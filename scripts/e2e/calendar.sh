#!/bin/zsh
# E2E — calendar reminder. A helper app creates the calendar "Granula E2E" with
# the event "E2E созвон" 90 s ahead (zoom.us link). Granula must list it, show the
# reminder ≤ 60 s before the start, record with the event title, and finish with
# status done. The helper deletes the calendar at the end.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}
TITLE="E2E созвон"
LEAD=90

# Helper app, built once and kept: rebuilding would reset its calendar permission.
HELPER=$ROOT/build/GranulaE2ECalendar.app
if [[ ! -x $HELPER/Contents/MacOS/GranulaE2ECalendar ]]; then
  mkdir -p $HELPER/Contents/MacOS
  swiftc -O -o $HELPER/Contents/MacOS/GranulaE2ECalendar ${0:A:h}/calendar-fixture/main.swift
  cat > $HELPER/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.nahornyi.granula.e2e-calendar</string>
<key>CFBundleName</key><string>Granula E2E Calendar</string>
<key>CFBundleExecutable</key><string>GranulaE2ECalendar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Тест Granula создаёт и удаляет календарь «Granula E2E».</string>
</dict></plist>
PLIST
  codesign --force --sign - --identifier ai.nahornyi.granula.e2e-calendar $HELPER
fi

trap 'fixture delete || true; restore_granula' EXIT

quit_granula
log_mark
fixture create "$TITLE" $LEAD || { echo "FAIL could not create the test event"; exit 1; }
START=$(python3 -I -c "import time;print(time.time() + $LEAD)")
open -n "$APP" --args --e2e-accept-call-prompt --e2e-stop-after 20

wait_event "calendar.upcoming title=$TITLE" 30 || { echo "FAIL event not read from the calendar"; new_log; exit 1; }
shown=$(wait_event "calendar.reminder_shown title=$TITLE" 100) || { echo "FAIL no reminder"; new_log; exit 1; }
echo "$shown"
lead=$(python3 -I -c "print(round($START - $(epoch ${shown%% *})))")
echo "reminder ${lead} s before the start"
line=$(wait_event recording.started 30) || { echo "FAIL recording did not start from the reminder"; new_log; exit 1; }
DIR=$MEETINGS/${line##*folder=}
echo "meeting: $DIR"
echo "status: $(wait_processed "$DIR")"
new_log | grep -E "calendar\.|recording\.|summary\.|transcript" || true

ok=1
[[ $(meeting_status "$DIR") == done ]] || { echo "status is not done"; ok=0; }
python3 -I -c "import sys; sys.exit(0 if 0 < $lead <= 60 else 1)" || { echo "reminder outside 0–60 s"; ok=0; }
python3 -I -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['title'] == sys.argv[2] else 1)" \
  "$DIR/meeting.json" "$TITLE" || { echo "title is not «$TITLE»"; ok=0; }
[[ $ok == 1 ]] && echo "PASS E2E calendar" || { echo "FAIL E2E calendar"; exit 1; }
