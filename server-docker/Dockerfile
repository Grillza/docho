# syntax=docker/dockerfile:1
# Dōchō Server: Suwayomi-Server with Kavita-style libraries, series groups and Dōchō Sync.
# Build from the repository root:  docker build -f server-docker/Dockerfile -t docho-server .

# ---- WebUI ----
FROM node:24.20.0-bookworm-slim AS webui
WORKDIR /src
RUN npm install -g pnpm@11.1.2
COPY server-webui/package.json server-webui/pnpm-lock.yaml server-webui/pnpm-workspace.yaml ./
RUN --mount=type=cache,target=/root/.local/share/pnpm/store pnpm install --frozen-lockfile
COPY server-webui/ ./
# The server reads the WebUI's version from build/revision (Suwayomi's release zips include it);
# without it the WebUI's first query fails and it never leaves the splash screen.
# r + the upstream WebUI release this is based on (v20260929.01).
RUN pnpm build && echo r20260929 > build/revision

# ---- Server ----
FROM eclipse-temurin:21-jdk AS server
WORKDIR /src
COPY server/ ./
ENV GRADLE_OPTS="-Dorg.gradle.daemon=false"
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew :server:shadowJar --no-daemon -x downloadWebUI \
        -Dorg.gradle.jvmargs=-Xmx3g -Pkotlin.compiler.execution.strategy=in-process --max-workers=2 \
    && cp server/build/*.jar /docho-server.jar

# ---- Runtime ----
FROM eclipse-temurin:21-jre
LABEL org.opencontainers.image.title="Dōchō Server" \
      org.opencontainers.image.description="Read and organise manga, comics and books; sync the Dōchō app." \
      org.opencontainers.image.source="https://github.com/Grillza/docho" \
      org.opencontainers.image.licenses="MPL-2.0"

# Fonts lay out EPUB text as pages (Noto CJK for Japanese, Chinese and Korean books).
RUN apt-get update \
    && apt-get install -y --no-install-recommends fontconfig fonts-dejavu-core fonts-noto-core fonts-noto-cjk tini curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=server /docho-server.jar /opt/docho/docho-server.jar
COPY --from=webui /src/build /opt/docho/webui
COPY server-docker/entrypoint.sh /opt/docho/entrypoint.sh
RUN chmod 755 /opt/docho/entrypoint.sh && mkdir -p /data && chmod 777 /data

ENV DOCHO_DATA=/data \
    DOCHO_LIBRARY_ROOT=/books \
    JAVA_OPTS="-Xmx1g"
VOLUME /data
EXPOSE 4567
HEALTHCHECK --interval=1m --timeout=10s --start-period=2m \
    CMD curl -fsS http://localhost:4567/api/docho/sync/v1/health || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/docho/entrypoint.sh"]
