"""Critical test: every interface text in the code has a translation in uk, en and es.

Without it part of the screen stays in Russian when Granula runs in another language.

Usage: python3 -I scripts/check-strings.py [--keys]
1. Builds Granula with -emit-localized-strings (own scratch folder .build/l10n) and collects
   the keys the compiler sees: Text("…"), Button("…"), String(localized: "…") and the like.
2. Every key with Cyrillic letters must be in Resources/{uk,en,es}.lproj/Localizable.strings
   with the same placeholders (%@, %lld …).
3. Every Cyrillic string literal in Sources/ must be such a key, unless its line says
   "not localized" (stored values, folder names) or the file is not interface text.
--keys prints the keys as JSON and exits (used to write the translation files).
Exit 0 when everything is translated.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["uk", "en", "es"]
# Prompt for Claude and text normalisation, not interface text.
SKIP_FILES = {"Templates.swift", "EchoFilter.swift"}
CYRILLIC = re.compile(r"[А-Яа-яЁёІіЇїЄєҐґ]")
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|lf|f)")
HOLE = "\x00"


def extract_keys():
    out = ROOT / ".build/l10n/strings"
    out.mkdir(parents=True, exist_ok=True)
    cmd = ["swift", "build", "--product", "Granula", "--scratch-path", str(ROOT / ".build/l10n"),
           "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path",
           "-Xswiftc", str(out)]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-4000:], r.stderr[-4000:])
        sys.exit("FAIL build with -emit-localized-strings")
    keys = set()
    for f in out.glob("*.stringsdata"):
        data = json.loads(f.read_text(encoding="utf-8"))
        source = Path(data.get("source", ""))
        # Files are kept between builds (unchanged files are not recompiled); skip deleted ones.
        if str(ROOT / "Sources") not in str(source) or not source.exists():
            continue
        for entries in data.get("tables", {}).values():
            keys.update(e["key"] for e in entries)
    if not keys:
        sys.exit("FAIL compiler reported no strings")
    return {k for k in keys if CYRILLIC.search(k)}


def load_strings(path):
    if not path.exists():
        return {}
    r = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"FAIL unreadable {path.relative_to(ROOT)}: {r.stderr.strip()}")
    return json.loads(r.stdout)


def specs(s):
    return sorted(re.sub(r"\d+\$", "", m) for m in SPEC.findall(s))


def literals(text):
    """Single-line string literals outside comments and triple-quoted blocks: (line, text with holes)."""
    in_block = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.count('"""') % 2 == 1:
            in_block = not in_block
            continue
        if in_block or "not localized" in line or line.lstrip().startswith("//"):
            continue
        i = 0
        while i < len(line):
            if line.startswith("//", i):
                break
            if line[i] != '"':
                i += 1
                continue
            j, buf, depth = i + 1, "", 0
            while j < len(line):
                ch = line[j]
                if depth:
                    depth += {"(": 1, ")": -1}.get(ch, 0)
                    j += 1
                    continue
                if line.startswith("\\(", j):
                    buf, depth, j = buf + HOLE, 1, j + 2
                    continue
                if ch == "\\":
                    buf, j = buf + line[j:j + 2], j + 2
                    continue
                if ch == '"':
                    break
                buf, j = buf + ch, j + 1
            yield n, buf
            i = j + 1


def main():
    keys = extract_keys()
    if "--keys" in sys.argv:
        print(json.dumps(sorted(keys), ensure_ascii=False, indent=1))
        return
    problems = []
    # Without a ru table macOS falls back to the development region (English) for Russian.
    if not (ROOT / "Resources/ru.lproj/Localizable.strings").exists():
        problems.append("ru: Resources/ru.lproj/Localizable.strings is missing")
    for lang in LANGS:
        path = ROOT / f"Resources/{lang}.lproj/Localizable.strings"
        table = load_strings(path)
        for key in sorted(keys):
            if key not in table:
                problems.append(f"{lang}: no translation for «{key}»")
            elif specs(key) != specs(table[key]):
                problems.append(f"{lang}: placeholders differ in «{key}» → «{table[key]}»")
    holes = {SPEC.sub(HOLE, k) for k in keys}
    for src in sorted((ROOT / "Sources").rglob("*.swift")):
        if src.name in SKIP_FILES:
            continue
        for n, lit in literals(src.read_text(encoding="utf-8")):
            if CYRILLIC.search(lit) and lit not in holes:
                problems.append(f"{src.relative_to(ROOT)}:{n}: text is not a translation key: «{lit}»")
    for p in problems:
        print(p)
    print(f"keys: {len(keys)}, problems: {len(problems)}")
    if problems:
        sys.exit("FAIL translations incomplete")
    print("PASS every interface text has uk, en and es")


if __name__ == "__main__":
    main()
