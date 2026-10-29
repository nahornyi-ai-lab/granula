#!/bin/zsh
# E2E — a recording started without the reminder (hot key, «Новая встреча», call
# prompt) during a calendar meeting takes that meeting's title and event id
# (attendees come with it; the helper cannot add attendees, so the summary
# line «Участники» is covered by CalendarRulesTests). The helper creates
# "E2E связка", started a minute ago; Granula starts a plain recording at once.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}
TITLE="E2E связка"
HELPER=$ROOT/build/GranulaE2ECalendar.app
[[ -x $HELPER/Contents/MacOS/GranulaE2ECalendar ]] || { echo "FAIL build the helper first: scripts/e2e/calendar.sh"; exit 1; }
trap 'fixture delete || true; restore_granula' EXIT

quit_granula
log_mark
fixture create "$TITLE" -60 || { echo "FAIL could not create the test event"; exit 1; }
open -n "$APP" --args --e2e-start --e2e-stop-after 8

wait_event "calendar.upcoming title=$TITLE" 30 >/dev/null || { echo "FAIL event not read from the calendar"; new_log | tail -20; exit 1; }
linked=$(wait_event "calendar.linked" 30) || { echo "FAIL recording not linked to the meeting"; new_log | tail -20; exit 1; }
echo "$linked"
line=$(wait_event recording.started 30) || { echo "FAIL recording did not start"; new_log | tail -20; exit 1; }
DIR=$MEETINGS/${line##*folder=}
echo "meeting: $DIR"
wait_event recording.stopped 30 >/dev/null || true
python3 -I -c "import json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if m['title'] == sys.argv[2] and m.get('calendarEventID') else 1)" \
  "$DIR/meeting.json" "$TITLE" || { echo "FAIL meeting.json: $(cat "$DIR/meeting.json")"; exit 1; }
wait_processed "$DIR" >/dev/null || true
# The test recording is not the owner's meeting: to the Trash (recoverable).
/usr/bin/trash "$DIR" && echo "test meeting moved to the Trash"
echo "PASS E2E calendar link"
