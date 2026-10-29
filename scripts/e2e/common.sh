# Shared helpers for E2E scripts (sourced).
LOG=~/Library/Logs/Granula/granula.log
APP=/Applications/Granula.app
# Meetings folder: the one picked in «Папка для встреч…», else the default.
MEETINGS=$(defaults read ai.nahornyi.granula meetingsFolder 2>/dev/null || echo ~/Documents/Granula)
mkdir -p ${LOG:h}; touch "$LOG"

quit_granula() {
  osascript -e 'tell application id "ai.nahornyi.granula" to quit' >/dev/null 2>&1 || true
  for i in {1..20}; do pgrep -x Granula >/dev/null || return 0; sleep 0.5; done
  echo "Granula did not quit" >&2; return 1
}

# Tests launch Granula with E2E flags (auto-accept, auto-stop); afterwards the
# owner's Granula must run normally again.
restore_granula() {
  quit_granula || true
  # LaunchServices needs a moment after a quit (otherwise open fails with -600).
  for i in {1..5}; do sleep 1; open "$APP" 2>/dev/null && return 0; done
  echo "could not reopen Granula" >&2
}

log_mark() { LOG_START=$(wc -c < "$LOG" | tr -d ' '); }
new_log() { tail -c +$((LOG_START + 1)) "$LOG"; }

# wait_event <event> <seconds> → prints the first matching new log line
wait_event() {
  local line
  for i in $(seq 1 $(( $2 * 2 ))); do
    line=$(new_log | grep -m1 " $1" || true)
    if [[ -n "$line" ]]; then echo "$line"; return 0; fi
    sleep 0.5
  done
  return 1
}

meeting_status() {
  python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$1/meeting.json" 2>/dev/null || echo "?"
}

wait_processed() {
  local s
  for i in {1..240}; do
    s=$(meeting_status "$1")
    case $s in done|summary_failed|failed|no_model) echo "$s"; return 0;; esac
    sleep 5
  done
  echo "$s"; return 1
}

epoch() { python3 -I -c "import sys,datetime;print(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp())" "$1"; }

# Calendar test helper (built by calendar.sh): fixture create <title> <seconds> | delete.
# Uses $HELPER and $WORK of the calling script.
fixture() {
  rm -f $WORK/fixture.out
  open -W -n --stdout $WORK/fixture.out --stderr $WORK/fixture.out $HELPER --args "$@"
  cat $WORK/fixture.out
  grep -q "^FAIL" $WORK/fixture.out && return 1 || return 0
}
