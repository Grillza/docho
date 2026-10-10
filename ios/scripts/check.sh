#!/bin/sh
# Generates the project, builds, runs the tests on an iPhone and an iPad mini simulator, and
# fails on any warning in our own sources. SWIFT_TREAT_WARNINGS_AS_ERRORS doesn't promote
# every diagnostic group (some concurrency warnings slip through), hence the log check.
# Usage: ios/scripts/check.sh
set -eu

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ios_dir"
xcodegen --quiet

iphone="${IPHONE_SIMULATOR:-iPhone 18 Pro}"
ipad="${IPAD_SIMULATOR:-iPad mini (A17 Pro)}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

status=0
xcodebuild clean test \
    -project Mihonka.xcodeproj \
    -scheme Mihonka \
    -derivedDataPath build/DerivedData \
    -destination "platform=iOS Simulator,name=$iphone" \
    -destination "platform=iOS Simulator,name=$ipad" \
    >"$log" 2>&1 || status=$?

grep -E "Test case .*(passed|failed)|Testing (passed|failed)|error:" "$log" | sort -u || true

warnings="$(grep -E "^$ios_dir/(Mihonka|MihonkaTests|MihonkaUITests)/.*: warning:" "$log" | sort -u || true)"
if [ -n "$warnings" ]; then
    echo "$warnings"
    echo "check.sh: warnings in our sources" >&2
    exit 1
fi
if [ "$status" -ne 0 ]; then
    tail -20 "$log"
    exit "$status"
fi
echo "check.sh: OK"
