#!/bin/sh
# Starts Dōchō Server with its data in $DOCHO_DATA and the WebUI built into the image.
set -e
DATA="${DOCHO_DATA:-/data}"
mkdir -p "$DATA"

# The image's WebUI, replaced on every start so it matches the server.
rm -rf "$DATA/webUI"
cp -r /opt/docho/webui "$DATA/webUI"

# shellcheck disable=SC2086
exec java $JAVA_OPTS \
    -Djava.awt.headless=true \
    -Dsuwayomi.tachidesk.config.server.rootDir="$DATA" \
    -Dsuwayomi.tachidesk.config.server.ip=0.0.0.0 \
    -Dsuwayomi.tachidesk.config.server.port=4567 \
    -Dsuwayomi.tachidesk.config.server.webUIFlavor=CUSTOM \
    -Dsuwayomi.tachidesk.config.server.webUIUpdateCheckInterval=0 \
    -Dsuwayomi.tachidesk.config.server.initialOpenInBrowserEnabled=false \
    -Dsuwayomi.tachidesk.config.server.systemTrayEnabled=false \
    -jar /opt/docho/docho-server.jar
