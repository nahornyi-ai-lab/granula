#!/bin/zsh
# E2E — meeting prep. The helper creates "E2E prep", started a minute ago; Granula is launched
# with --e2e-prepare, which saves a text file as the prep of that meeting through the same
# function as the Prepare sheet (translation off for it), then records it. The other side asks
# about the timeline; the fact the hint needs ("March, in two phases") is only in the prep:
# "About me" is empty. The default To is Russian, so a translated line would show.
# Pass: the meeting's context.md is the prepared text, meeting.json has hints on and no
# translateTo, the timeline hint mentions March, no live line is translated.
# Needs the OpenRouter key saved in Granula → Hints…, network and the calendar helper.
# The owner's own settings are not used and not changed. GRANULA_APP=<path> runs another build.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh
WORK=${E2E_WORK:-$(mktemp -d)}
mkdir -p "$WORK"
TITLE="E2E prep"
HELPER=$ROOT/build/GranulaE2ECalendar.app
[[ -x $HELPER/Contents/MacOS/GranulaE2ECalendar ]] || { echo "FAIL build the helper first: scripts/e2e/calendar.sh"; exit 1; }
if [[ ! -s "$HOME/Library/Application Support/Granula/openrouter-api-key" ]]; then
  echo "FAIL the OpenRouter key is not saved (Granula → Hints…)"; exit 1
fi
PREP=""
cleanup() {
  fixture delete || true
  # The prep of the test event is test data: to the Trash with it (only if it is the test event's).
  if [[ -n "$PREP" && -d "$MEETINGS/_upcoming/$PREP" ]] && python3 -I -c \
      "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['title'] == sys.argv[2] else 1)" \
      "$MEETINGS/_upcoming/$PREP/prep.json" "$TITLE" 2>/dev/null; then
    /usr/bin/trash "$MEETINGS/_upcoming/$PREP" || true
  fi
  restore_granula
}

cat > "$WORK/context.txt" <<'TXT'
Agenda for the call with Dana from Northwind.
Our database migration is planned for March, in two phases: the read replicas first, then the primary.
Dana will probably ask about the timeline.
TXT
python3 -I "$ROOT/scripts/e2e/make_hints_audio.py" "$WORK"
CALL_SECONDS=$(python3 -I -c "import wave,sys;w=wave.open(sys.argv[1]);print(int(w.getnframes()/w.getframerate())+1)" "$WORK/call.wav")
STOP_AFTER=$((CALL_SECONDS + 15))

quit_granula
log_mark
trap cleanup EXIT
rm -f "$WORK/hints.json"
fixture create "$TITLE" -60 || { echo "FAIL could not create the test event"; exit 1; }
open -n "$APP" --args --e2e-start --e2e-stop-after $STOP_AFTER --e2e-live-window --e2e-languages en \
  --e2e-translate ru --e2e-hints-out "$WORK/hints.json" \
  --e2e-prepare "$WORK/context.txt" --e2e-prepare-translate off

# A fresh build first asks for the calendar: up to two minutes for the owner to allow it.
saved=$(wait_event "prep.saved" 120) || { echo "FAIL prep not saved"; new_log | tail -20; exit 1; }
PREP=${${saved##*folder=}%% *}
echo "prep: $PREP"
wait_event "prep.used" 30 >/dev/null || { echo "FAIL the recording did not take the prep"; new_log | tail -20; exit 1; }
# After an ad-hoc reinstall macOS first asks for the microphone and system-audio permissions.
line=$(wait_event recording.started 120) || { echo "FAIL recording did not start (permissions?)"; new_log | tail -20; exit 1; }
DIR=$MEETINGS/${line##*folder=}
echo "meeting: $DIR"
wait_event live.ready 90 >/dev/null || { echo "FAIL live transcript not ready"; new_log | grep -E "live\.|asr\."; exit 1; }
sleep 1
afplay "$WORK/call.wav"
wait_event live.finished $((STOP_AFTER + 60)) >/dev/null || { echo "FAIL live transcript did not finish"; exit 1; }
new_log | grep -E "prep\.|hint\.|live\.languages" || true

python3 -I - "$DIR" "$WORK/context.txt" "$WORK/hints.json" <<'PY'
import json, sys
from pathlib import Path
folder, context, hints_path = (Path(a) for a in sys.argv[1:4])
failed = False
def check(ok, text):
    global failed
    failed |= not ok
    print(f"{'ok  ' if ok else 'FAIL'} {text}")
got = (folder / "context.md").read_text(encoding="utf-8") if (folder / "context.md").exists() else None
check(got is not None and got.strip() == context.read_text(encoding="utf-8").strip(), "context.md is the prepared text")
meeting = json.loads((folder / "meeting.json").read_text(encoding="utf-8"))
check(meeting.get("hints") is True, f"meeting.json hints on ({meeting.get('hints')})")
check(meeting.get("translateTo") is None, f"meeting.json has no translateTo ({meeting.get('translateTo')})")
try:
    hints = json.loads(hints_path.read_text(encoding="utf-8")).get("hints", [])
except (OSError, ValueError):
    hints = []
for h in hints:
    print(f"  #{h['id']} {h['state']} said: {h['said']}\n      {h['text']}")
timeline = [h for h in hints if "timeline" in h["said"].lower() and h["state"] == "done"]
check(any("march" in h["text"].lower() for h in timeline), "the timeline hint uses the prepared fact (March)")
check(all(not h.get("translation") for h in hints), "no hint is translated")
lines = [json.loads(l) for l in (folder / "live.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
translated = [l["text"] for l in lines if l.get("translation")]
check(bool(lines) and not translated, f"{len(lines)} live rows, none translated {translated[:2]}")
sys.exit(1 if failed else 0)
PY
wait_processed "$DIR" >/dev/null || true
# The test recording is not the owner's meeting: to the Trash (recoverable).
/usr/bin/trash "$DIR" && echo "test meeting moved to the Trash"
echo "PASS E2E meeting prep"
echo "work: $WORK"
