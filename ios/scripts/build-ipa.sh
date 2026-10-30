#!/bin/sh
# Builds an unsigned Doki.ipa for SideStore/AltStore, which sign it on install.
# Usage: ios/scripts/build-ipa.sh [output-dir]   (default: ios/build)
set -eu

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$(mkdir -p "${1:-$ios_dir/build}" && cd "${1:-$ios_dir/build}" && pwd)"
derived="$out_dir/DerivedData"

cd "$ios_dir"
xcodegen --quiet

xcodebuild build \
    -project Doki.xcodeproj \
    -scheme Doki \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    -quiet

app="$derived/Build/Products/Release-iphoneos/Doki.app"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

mkdir "$staging/Payload"
cp -R "$app" "$staging/Payload/"
rm -f "$out_dir/Doki.ipa"
(cd "$staging" && zip -qry "$out_dir/Doki.ipa" Payload)

echo "$out_dir/Doki.ipa"
