#!/bin/zsh
# Starts local Kavita, Komga and Suwayomi servers in Docker with a few generated test comics, for the
# live tests (PLAN-2.md, Part H). Prints the environment variables check.sh needs.
#
# usage: ios/scripts/test-servers.sh [work-dir]     (default: ios/build/test-servers)
# stop:  docker rm -f docho-kavita docho-komga docho-suwayomi
set -euo pipefail
cd "$(dirname "$0")"
WORK="${1:-$PWD/../build/test-servers}"
mkdir -p "$WORK/bin" "$WORK/library/Comics" "$WORK/kavita-config" "$WORK/komga-config" "$WORK/suwayomi/local"

# Test comics: numbered pages, so a test can see which page is shown.
swiftc -O -o "$WORK/bin/make-test-pages" make-test-pages.swift
make_cbz() { # series file pages label hue [width height]
  local tmp="$WORK/tmp"; rm -rf "${tmp:?}"; mkdir -p "$tmp"
  "$WORK/bin/make-test-pages" "$tmp" "$3" "$4" "$5" ${6:-} ${7:-}
  mkdir -p "$WORK/library/Comics/$1"
  (cd "$tmp" && zip -q -0 "$WORK/library/Comics/$1/$2.cbz" ./*.jpg)
}
if [ -z "$(ls -A "$WORK/library/Comics")" ]; then
  make_cbz "Docho Test" "Docho Test v01" 12 "Docho Test v1" 0.58
  make_cbz "Docho Test" "Docho Test v02" 12 "Docho Test v2" 0.33
  make_cbz "Docho Test" "Docho Test v10" 8 "Docho Test v10" 0.08
  make_cbz "Long Strip Test" "Long Strip Test 001" 6 "Strip 1" 0.75 800 2400
  make_cbz "Spread Test" "Spread Test v01" 10 "Spread" 0.95 1600 1200
fi

docker rm -f docho-komga docho-kavita docho-suwayomi >/dev/null 2>&1 || true
# Suwayomi's own Local source reads its local folder; the live tests read the test comic there.
mkdir -p "$WORK/suwayomi/local/Docho Test"
cp "$WORK/library/Comics/Docho Test/"*.cbz "$WORK/suwayomi/local/Docho Test/" 2>/dev/null || true
docker run -d --name docho-suwayomi -p 4567:4567 \
  -v "$WORK/suwayomi:/home/suwayomi/.local/share/Tachidesk" ghcr.io/suwayomi/suwayomi-server:stable >/dev/null
docker run -d --name docho-komga -p 25600:25600 -e JAVA_TOOL_OPTIONS=-Xmx512m \
  -v "$WORK/komga-config:/config" -v "$WORK/library:/data:ro" gotson/komga:latest >/dev/null
docker run -d --name docho-kavita -p 5005:5000 \
  -v "$WORK/kavita-config:/kavita/config" -v "$WORK/library:/manga:ro" jvmilazz0/kavita:latest >/dev/null
until curl -s -o /dev/null -w '%{http_code}' http://localhost:25600/api/v1/libraries | grep -q 401; do sleep 3; done
until curl -s -o /dev/null -w '%{http_code}' http://localhost:5005/api/health | grep -q 200; do sleep 3; done
until curl -sf -o /dev/null http://localhost:4567/api/v1/settings/about; do sleep 3; done

# Komga: claim the server, add the library, make an API key (first run only).
if [ ! -s "$WORK/komga.key" ]; then
  curl -s -X POST http://localhost:25600/api/v1/claim -H 'X-Komga-Email: test@docho.local' -H 'X-Komga-Password: dochotest' >/dev/null
  curl -s -u test@docho.local:dochotest -X POST http://localhost:25600/api/v1/libraries \
    -H 'Content-Type: application/json' -d '{"name":"Comics","root":"/data/Comics"}' >/dev/null
  curl -s -u test@docho.local:dochotest -X POST http://localhost:25600/api/v2/users/me/api-keys \
    -H 'Content-Type: application/json' -d '{"comment":"docho-ios"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])' > "$WORK/komga.key"
fi

# Kavita: register the admin, add the library (first run only). Kavita 0.9 wants a
# metadataProvider, which is a flag value; 2 is accepted.
if [ ! -s "$WORK/kavita.key" ]; then
  curl -s -X POST http://localhost:5005/api/Account/register -H 'Content-Type: application/json' \
    -d '{"username":"docho","password":"Dochotest1!","email":"test@docho.local"}' > "$WORK/kavita.json"
  python3 -c "import json; d=json.load(open('$WORK/kavita.json')); open('$WORK/kavita.key','w').write(d['apiKey']); open('$WORK/kavita.token','w').write(d['token'])"
  curl -s -X POST http://localhost:5005/api/Library/create -H "Authorization: Bearer $(cat "$WORK/kavita.token")" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Comics","type":1,"folders":["/manga/Comics"],"folderWatching":false,"includeInDashboard":true,"includeInSearch":true,"manageCollections":false,"manageReadingLists":false,"allowScrobbling":false,"fileGroupTypes":[1,4],"excludePatterns":[],"metadataProvider":2}' >/dev/null
fi

echo "Servers are up. For the live tests:"
echo "  TEST_RUNNER_DOCHO_KAVITA_URL=http://localhost:5005 TEST_RUNNER_DOCHO_KAVITA_KEY=$(cat "$WORK/kavita.key") \\"
echo "  TEST_RUNNER_DOCHO_KOMGA_URL=http://localhost:25600 TEST_RUNNER_DOCHO_KOMGA_KEY=$(cat "$WORK/komga.key") \\"
echo "  TEST_RUNNER_DOCHO_SUWAYOMI_URL=http://localhost:4567 \\"
echo "  TEST_RUNNER_DOCHO_KOMGA_SERIES='Docho Test' ios/scripts/check.sh"
