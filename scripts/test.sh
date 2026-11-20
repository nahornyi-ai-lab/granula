#!/bin/zsh
# Runs the unit tests. Works with Command Line Tools alone (no Xcode): Swift
# Testing ships there, but outside the default search paths, so they are given
# explicitly. The XCTest suites need Xcode and are skipped without it.
# The 26.5 SDK: with the 27 SDK, SwiftUI's @State is a macro whose plugin CLT lacks.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && -d $CLT/SDKs/MacOSX26.5.sdk ]]; then export SDKROOT=$CLT/SDKs/MacOSX26.5.sdk; fi
if [[ "$(xcode-select -p)" == $CLT ]]; then
  swift test --build-system native \
    -Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks \
    -Xswiftc -plugin-path -Xswiftc $CLT/usr/lib/swift/host/plugins/testing \
    -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks \
    -Xlinker -F -Xlinker $CLT/Library/Developer/Frameworks "$@"
else
  swift test "$@"
fi
