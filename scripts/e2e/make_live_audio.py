"""Builds the test call for live.sh: Russian, English, Ukrainian and Spanish sentences
spoken by macOS voices, with pauses between them, as one 16 kHz WAV.

Usage: python3 -I make_live_audio.py <work dir>
Writes call.wav and phrases.json: [{"lang", "text", "start", "end"}] (seconds in call.wav).
"""
import json
import subprocess
import sys
import wave
from pathlib import Path

PHRASES = [
    ("ru", "Milena", "Давайте обсудим бюджет на следующий квартал и сроки запуска."),
    ("en", "Samantha", "The client agreed to move the launch to next Tuesday."),
    ("uk", "Lesya", "Ми готові підписати договір наступного тижня."),
    ("ru", "Milena", "Тогда я отправлю презентацию сегодня вечером."),
    ("es", "Mónica", "Podemos firmar el contrato la próxima semana."),
]
LEAD, PAUSE, TAIL = 1.0, 2.0, 3.0
RATE = 16000


def main():
    work = Path(sys.argv[1])
    frames = bytearray(b"\0\0" * int(LEAD * RATE))
    meta = []
    for i, (lang, voice, text) in enumerate(PHRASES):
        part = work / f"phrase{i}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(part), "--data-format=LEI16@16000", text], check=True)
        with wave.open(str(part)) as w:
            assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
            data = w.readframes(w.getnframes())
        start = len(frames) / 2 / RATE
        frames += data
        meta.append({"lang": lang, "text": text, "start": round(start, 2), "end": round(len(frames) / 2 / RATE, 2)})
        frames += b"\0\0" * int((PAUSE if i < len(PHRASES) - 1 else TAIL) * RATE)
    with wave.open(str(work / "call.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))
    (work / "phrases.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"call.wav: {len(frames) / 2 / RATE:.1f} s, {len(PHRASES)} phrases")


main()
