"""Builds the test call for hints.sh: the other side says three things, 6 s apart, as one 16 kHz WAV.

Usage: python3 -I make_hints_audio.py <work dir> [<translate language>]
Phrases: "Okay, got it." (no reply expected), "Tell me about your timeline for the migration."
(a request without a question mark), and with a translate language "ru" a Russian question.
Writes call.wav and phrases.json: [{"lang", "text", "start", "end"}] (seconds in call.wav).
"""
import json
import subprocess
import sys
import wave
from pathlib import Path

PHRASES = [
    ("en", "Samantha", "Okay, got it."),
    ("en", "Samantha", "Tell me about your timeline for the migration."),
]
RUSSIAN = ("ru", "Milena", "Когда вы планируете закончить первый этап?")
LEAD, PAUSE, TAIL = 1.0, 6.0, 8.0  # the tail lets the last hint finish
RATE = 16000


def main():
    work = Path(sys.argv[1])
    phrases = list(PHRASES)
    if len(sys.argv) > 2 and sys.argv[2] == "ru":
        phrases.append(RUSSIAN)
    frames = bytearray(b"\0\0" * int(LEAD * RATE))
    meta = []
    for i, (lang, voice, text) in enumerate(phrases):
        part = work / f"phrase{i}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(part), "--data-format=LEI16@16000", text], check=True)
        with wave.open(str(part)) as w:
            assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
            data = w.readframes(w.getnframes())
        start = len(frames) / 2 / RATE
        frames += data
        meta.append({"lang": lang, "text": text, "start": round(start, 2), "end": round(len(frames) / 2 / RATE, 2)})
        frames += b"\0\0" * int((PAUSE if i < len(phrases) - 1 else TAIL) * RATE)
    with wave.open(str(work / "call.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))
    (work / "phrases.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"call.wav: {len(frames) / 2 / RATE:.1f} s, {len(phrases)} phrases")


main()
