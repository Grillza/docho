#!/bin/sh
# Generates the project, builds, runs the tests on the iPad mini simulator (the main target),
# and fails on any warning in our own sources. Set IPHONE_SIMULATOR to test on an iPhone too.
# SWIFT_TREAT_WARNINGS_AS_ERRORS doesn't promote every diagnostic group (some concurrency
# warnings slip through), hence the log check.
# Usage: ios/scripts/check.sh    or    IPHONE_SIMULATOR="iPhone 18 Pro" ios/scripts/check.sh
set -eu

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ios_dir"
xcodegen --quiet

ipad="${IPAD_SIMULATOR:-iPad mini (A17 Pro)}"
set -- -destination "platform=iOS Simulator,name=$ipad"
if [ -n "${IPHONE_SIMULATOR:-}" ]; then
    set -- "$@" -destination "platform=iOS Simulator,name=$IPHONE_SIMULATOR"
fi
log="$(mktemp)"
results="$(mktemp -d)/results.xcresult"
trap 'rm -rf "$log" "$(dirname "$results")"' EXIT

status=0
xcodebuild clean test \
    -project Docho.xcodeproj \
    -scheme Docho \
    -derivedDataPath build/DerivedData \
    -resultBundlePath "$results" \
    -collect-test-diagnostics never \
    "$@" \
    >"$log" 2>&1 || status=$?

grep -E "error:" "$log" | sort -u || true
if [ -d "$results" ]; then
    xcrun xcresulttool get test-results tests --path "$results" | python3 -c '
import json, sys
def walk(node, out):
    if node.get("nodeType") == "Test Case":
        out.append((node.get("result"), node.get("nodeIdentifier")))
    for child in node.get("children", []):
        walk(child, out)
cases = []
for node in json.load(sys.stdin)["testNodes"]:
    walk(node, cases)
for result, name in sorted(cases):
    if result != "Passed":
        print(f"  {result}: {name}")
counts = {}
for result, _ in cases:
    counts[result] = counts.get(result, 0) + 1
print("tests:", ", ".join(f"{n} {r.lower()}" for r, n in sorted(counts.items())))
' || true
fi

warnings="$(grep -E "^$ios_dir/(Docho|DochoTests|DochoUITests)/.*: warning:" "$log" | sort -u || true)"
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
