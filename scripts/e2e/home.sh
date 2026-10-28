#!/bin/zsh
# E2E — main screen and interface languages. The calendar helper creates the event
# "E2E встреча" an hour ahead (too early for a reminder). Granula runs in Spanish,
# then in English, with --e2e-snapshot: it saves PNGs of its own window —
# «Главная», the newest meeting (the same action as a click), «Главная» again.
# Then look at the pictures: no Russian interface text (meeting titles aside),
# the «Предстоящие» card with the test event, the feed by day, the meeting screen.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}
TITLE="E2E встреча"
HELPER=$ROOT/build/GranulaE2ECalendar.app
[[ -x $HELPER/Contents/MacOS/GranulaE2ECalendar ]] || { echo "FAIL build the helper first: scripts/e2e/calendar.sh"; exit 1; }
trap 'fixture delete || true; restore_granula' EXIT

fixture create "$TITLE" 3600 || { echo "FAIL could not create the test event"; exit 1; }
ok=1
for lang in es en; do
  quit_granula
  log_mark
  open -n "$APP" --args -AppleLanguages "($lang)" --e2e-snapshot "$WORK/$lang"
  wait_event "calendar.upcoming title=$TITLE" 30 >/dev/null || { echo "FAIL $lang: test event not read"; ok=0; }
  if ! wait_event "e2e.snapshots_done" 40 >/dev/null; then
    echo "FAIL $lang: no snapshots"; new_log | tail -20; ok=0; continue
  fi
  for f in 1-home 2-meeting 3-home; do
    [[ -s $WORK/$lang/$f.png ]] || { echo "FAIL $lang: $f.png missing"; ok=0; }
  done
  echo "$lang: $WORK/$lang"
done
[[ $ok == 1 ]] && echo "PASS E2E home: snapshots saved, check them by eye" || { echo "FAIL E2E home"; exit 1; }
