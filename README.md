<div align="center">

<img src="./.github/assets/logo.svg" alt="Dōchō logo" title="Dōchō logo" width="96"/>

# Dōchō

### 同調 · どうちょう

A manga reader for your own servers. Read straight from Kavita, Komga or BookOrbit and keep your
place in sync with them, or with KOReader on your e-reader.

[![Based on Mihon v0.21.3](https://img.shields.io/badge/based_on-Mihon_v0.21.3-0877d2?labelColor=27303D)](https://github.com/mihonapp/mihon/releases/tag/v0.21.3)
[![License: Apache-2.0](https://img.shields.io/github/license/Grillza/docho?labelColor=27303D&color=0877d2)](/LICENSE)

[![Download](https://img.shields.io/github/v/release/Grillza/docho?label=Download&labelColor=06599d&color=043b69)](https://github.com/Grillza/docho/releases/latest)

*Android 8.0 or higher, or iOS / iPadOS 18 or higher with a sideloader.*

</div>

## About

Dōchō is a fork of [Mihon](https://github.com/mihonapp/mihon), the free and open source manga reader.
It keeps everything Mihon does, including extensions, trackers, backups and the reader, and adds
built-in support for self-hosted libraries and progress sync. It follows Mihon's releases.

> [!NOTE]
> Dōchō's additions to Mihon were built with the help of AI, using [Claude](https://claude.ai) by Anthropic.

## What Dōchō adds

### Self-hosted servers, built in

* **[Kavita](https://www.kavitareader.com/)**, **[Komga](https://komga.org/)** and
  **[BookOrbit](https://github.com/bookorbit/bookorbit)** work as built-in sources with no
  extensions needed. Set one up under **More → Settings → Sync / Self-hosted sources** and its
  series show in **Browse → Sources** with the server's own logo.
* Comic archives (CBZ, CBR, CB7) are read page by page; PDFs too on Kavita and Komga.
* Volumes, chapters and specials keep the server's own numbering.
* **[Suwayomi](https://github.com/Suwayomi/Suwayomi-Server)**: if you already run extensions on a
  Suwayomi server, its sources show in **Browse → Sources** beside the extensions on your device,
  so you can read from them without installing anything on the phone. Extensions on the device
  keep working as usual, and take over if the same one is installed in both places.
* Each server's section folds down to its logo, name and connection status, and **Delete** erases
  that server's details without touching the others.

### Reading progress sync

* Every page you read is sent to the server, and progress made on the server's own reader or
  another device is picked up when you open a chapter. Whichever side has read further wins.
* **Sync library now** reconciles every series from a server at once. Progress that can't be sent
  while you're offline is kept and sent later.
* **KOReader sync**: sync everything through a KOReader sync server instead (BookOrbit has one
  built in), so your place is shared with KOReader on an e-reader. Books are matched by file
  fingerprint, so Kavita, BookOrbit, Komga and local archives all work.
* **Settings export**: save your servers and sync options to a file and load them on another
  device. With a password the file is encrypted (AES-256-GCM), and passwords and API keys are only
  ever exported encrypted. Server details are left out of Mihon's own backups, which can't be
  password protected.

See the **[self-hosted sync guide](./docs/self-hosted-sync.md)** for setup steps.

### Edit series details

* **Edit details** (in a series' menu) changes its title, author, artist, description, genres and
  status. Edited fields stay when the series refreshes from its source, and with Dōchō Sync they
  reach your other devices and Dōchō Server, where they can be edited too.

### Library and look

* **Custom themes**: keep up to five of your own. Pick six colours with a colour wheel, swatches
  or hex codes, set the contrast, start from any built-in theme and preview it full screen.
  Dōchō warns about colours that would be hard to read.
* **Navigation bar**: drag the tabs into any order, tap the eye to hide Updates, History or
  Browse, choose where the remaining tabs sit, and see the result in a live preview.
* **Hide missing chapter indicators** for individual series.
* **File name chapter sort** and an **Unread** listing in Browse.
* An **Acknowledgements** screen credits the projects Dōchō is built on.

## From Mihon

* Online reading from sources added through extensions, and local reading of downloaded content.
* A configurable reader with multiple viewers, reading directions and other settings.
* Tracker support: [MangaBaka](https://mangabaka.org), [MyAnimeList](https://myanimelist.net/),
  [AniList](https://anilist.co/), [Kitsu](https://kitsu.app/), [MangaUpdates](https://mangaupdates.com),
  [Shikimori](https://shikimori.one), [Bangumi](https://bgm.tv/), [Hikka](https://hikka.io/) and
  [Comick](https://comick.dev/).
* Categories to organise your library, and scheduled library updates.
* Backups, kept locally or on your cloud service.

## Download

Each **[release](https://github.com/Grillza/docho/releases/latest)** has an Android section and an
iOS section. The two apps are released together, so their version numbers match or differ by at most
a patch number.

### Android

Requires Android 8.0 or higher. Most devices want the `arm64-v8a` APK; `universal` runs anywhere but
is larger.

### iOS and iPadOS

Requires iOS or iPadOS 18 or higher, on iPhone or iPad. The `.ipa` isn't signed and Dōchō isn't on
the App Store, so you need a sideloader such as [AltStore](https://altstore.io),
[SideStore](https://sidestore.io) or [Sideloadly](https://sideloadly.io) to install it. With a free
Apple ID, sideloaded apps have to be refreshed every 7 days.

Extensions can run on the iPhone or iPad itself, with no server: turn on **Settings → Browse →
Extensions on this device**, then add a repo under **Browse → Extensions**. They run on a Java
runtime built into the app (Eclipse OpenJ9), which is why the iOS download is larger.

In AltStore or SideStore you can add Dōchō's source instead, so the app updates from there:

```
https://raw.githubusercontent.com/Grillza/docho/main/altstore/source.json
```

### Optional: Dōchō Server

If you want to run Dōchō's version of [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server), with
Dōchō Sync, Kavita-style libraries, series groups and collections built in, here is the Docker
Compose file. Everything syncs both ways between the Android and iOS apps and its own web reader:
your library and categories, edited series details, chapter renames and Volume/Chapter types, and
read progress page by page. Its extensions, libraries and series groups show in the apps under
**Browse → Sources**.

Clone the repository and build it (the first build takes a while):

```sh
git clone https://github.com/Grillza/docho.git
cd docho/server-docker
docker compose up -d --build
```

The compose file (`server-docker/docker-compose.yml` is the same; set the library folder to yours):

```yaml
services:
  docho-server:
    build:
      context: ..
      dockerfile: server-docker/Dockerfile
    container_name: docho-server
    restart: unless-stopped
    # Match the owner of your library files, so covers and progress can be read and saved.
    user: "1000:1000"
    ports:
      - "4567:4567"
    environment:
      TZ: Australia/Sydney
      # Heap for the server; raise it for very large libraries or big PDFs.
      JAVA_OPTS: "-Xmx1g"
      # "open" lets more than one person make a Dōchō Sync account.
      DOCHO_SYNC_REGISTRATION: ""
      # The sync account whose reading the server follows; empty = the first account, "none" = off.
      DOCHO_SYNC_SERVER_ACCOUNT: ""
      # Where the folder picker opens: the library mount below, as the server sees it.
      DOCHO_LIBRARY_ROOT: /books
    volumes:
      # Database, covers, extensions, downloads and settings.
      - data:/data
      # Your library, read-only: the server never changes your files. Change the left side.
      - /path/to/your/books:/books:ro

volumes:
  data:
```

Then open `http://<host>:4567`, go to **Libraries** and add your folders. In the app, enter the same
address under **More → Settings → Sync / Self-hosted sources**, in both **Dōchō Server / Suwayomi**
(for its sources) and **Dōchō Sync** (for syncing; create the account there). See
[`server-docker/README.md`](./server-docker/README.md) for more.

## Building

```sh
./gradlew assembleRelease
```

Release builds are signed with the keystore named in `keystore.properties`. The iOS app lives on the
[`ios`](https://github.com/Grillza/docho/tree/ios) branch.

## Help and issues

For problems with Dōchō itself, open an [issue](https://github.com/Grillza/docho/issues).
For general reader questions, Mihon's [FAQ](https://mihon.app/docs/faq/general) and
[troubleshooting guide](https://mihon.app/docs/guides/troubleshooting/) still apply. Extensions are
not made or supported here.

## Credits

Dōchō is built on [Mihon](https://github.com/mihonapp/mihon) and
[Tachiyomi](https://github.com/tachiyomiorg/tachiyomi). Thank you to everyone who has
contributed to them.

<a href="https://github.com/mihonapp/mihon/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=mihonapp/mihon" alt="Mihon app contributors" title="Mihon app contributors" width="800"/>
</a>

### Disclaimer

The developer(s) of this application does not have any affiliation with the content providers available, and this application hosts zero content.

### License

<pre>
Copyright © 2015 Javier Tomás
Copyright © 2024 Mihon Open Source Project

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
</pre>
