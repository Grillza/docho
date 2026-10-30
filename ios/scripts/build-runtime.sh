#!/bin/zsh
# Builds the extension runtime (ios/Vendor/docho-runtime): Eclipse OpenJ9 for iOS (device and
# simulator) and the macOS build that jlinks it, then packages it into ios/Embedded with the
# size reductions described in PLAN-2.md (Extensions → Size).
#
# The first run takes hours on a small Mac (about 40 minutes on an M4 Pro); later runs skip
# steps that are done. Needs `brew install cmake autoconf openjdk@21`.
#
# usage: ios/scripts/build-runtime.sh [step…]   steps: fetch patch macos simulator device package
#        JOBS=4 by default, which keeps an 8 GB Mac out of swap.
set -euo pipefail
cd "$(dirname "$0")/.."
IOS="$PWD"
RUNTIME="$IOS/Vendor/docho-runtime"
JVM="$RUNTIME/jvm-ios"
LOGS="$IOS/build/runtime-logs"
export JOBS="${JOBS:-4}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
mkdir -p "$LOGS"

[ -d "$RUNTIME/extension-host/vendor/suwayomi/.git" ] || [ -f "$RUNTIME/extension-host/vendor/suwayomi/.git" ] \
  || git -C "$IOS/.." submodule update --init --recursive ios/Vendor/docho-runtime

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(fetch patch macos simulator device package)

run() { # name command…
  local name="$1"; shift
  echo "$(date '+%H:%M:%S') $name…"
  if ! "$@" > "$LOGS/$name.log" 2>&1; then
    echo "$(date '+%H:%M:%S') $name failed; see $LOGS/$name.log"
    tail -30 "$LOGS/$name.log"
    exit 1
  fi
  echo "$(date '+%H:%M:%S') $name done"
}

for step in "${steps[@]}"; do
  case "$step" in
    fetch) run fetch "$JVM/fetch-openj9.sh" ;;
    patch) run patch "$JVM/apply-openj9-patches.sh" ;;
    macos) run macos "$JVM/build-openj9-macos.sh" ;;
    simulator) run simulator "$JVM/build-openj9-ios.sh" iphonesimulator ;;
    device) run device "$JVM/build-openj9-ios.sh" iphoneos ;;
    package)
      # Size: store the class library compressed (about half the size; classes load a little
      # slower), and keep only English message catalogues.
      export JLINK_EXTRA="${JLINK_EXTRA:---compress zip-6}"
      run package env EMBEDDED_DIR="$IOS/Embedded" "$JVM/package.sh"
      find "$IOS/Embedded/jre/lib" -name '*.properties' -path '*nls*' ! -name '*_en*' ! -name '*[a-z].properties' -delete 2>/dev/null || true
      du -sh "$IOS/Embedded/jre" "$IOS/Embedded/host" "$IOS/Embedded" | sed 's/^/  /'
      ;;
    *) echo "unknown step $step"; exit 2 ;;
  esac
done
