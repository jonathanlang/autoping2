#!/bin/bash
# Runs the unit tests with the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS="$(xcode-select -p)"
FRAMEWORKS="$TOOLS/Library/Developer/Frameworks"

# --build-system native: SwiftPM's new default build system refuses to start while
# the Command Line Tools contain an incomplete SDK folder (MacOSX12.3.sdk).
swift test --build-system native \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xswiftc -plugin-path -Xswiftc "$TOOLS/usr/lib/swift/host/plugins/testing" \
    "$@" 2>&1 | grep -v "build-system native' has been deprecated"
