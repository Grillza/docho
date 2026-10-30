<div align="center">

<img src="./.github/assets/logo.svg" alt="Dōki logo" title="Dōki logo" width="96"/>

# Dōki

### 同期 · どうき · sync

A manga reader for your own servers. Read straight from Kavita, Komga or BookOrbit and keep your
place in sync with them, or with KOReader on your e-reader.

[![Based on Mihon v0.21.3](https://img.shields.io/badge/based_on-Mihon_v0.21.3-0877d2?labelColor=27303D)](https://github.com/mihonapp/mihon/releases/tag/v0.21.3)
[![License: Apache-2.0](https://img.shields.io/github/license/Grillza/doki?labelColor=27303D&color=0877d2)](/LICENSE)

[![Download](https://img.shields.io/github/v/release/Grillza/doki?label=Download&labelColor=06599d&color=043b69)](https://github.com/Grillza/doki/releases/latest)

*Requires Android 8.0 or higher.*

</div>

## About

Dōki is a fork of [Mihon](https://github.com/mihonapp/mihon), the free and open source manga reader.
It keeps everything Mihon does, including extensions, trackers, backups and the reader, and adds
built-in support for self-hosted libraries and progress sync. It follows Mihon's releases.

## What Dōki adds

### Self-hosted servers, built in

* **[Kavita](https://www.kavitareader.com/)**, **[Komga](https://komga.org/)** and
  **[BookOrbit](https://github.com/bookorbit/bookorbit)** work as built-in sources with no
  extensions needed. Set one up under **More → Settings → Sync / Self-hosted sources** and its
  series show in **Browse → Sources** with the server's own logo.
* Comic archives (CBZ, CBR, CB7) are read page by page; PDFs too on Kavita and Komga.
* Volumes, chapters and specials keep the server's own numbering.
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
  ever exported encrypted.

See the **[self-hosted sync guide](./docs/self-hosted-sync.md)** for setup steps.

### Library and look

* **Custom themes**: keep up to five of your own. Pick six colours with a colour wheel, swatches
  or hex codes, set the contrast, start from any built-in theme and preview it full screen.
  Dōki warns about colours that would be hard to read.
* **Navigation bar**: hide Updates, History or Browse, choose where the remaining tabs sit, and
  see the result in a live preview.
* **Hide missing chapter indicators** for individual series.
* **File name chapter sort** and an **Unread** listing in Browse.
* An **Acknowledgements** screen credits the projects Dōki is built on.

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

Get the latest APK from **[Releases](https://github.com/Grillza/doki/releases/latest)**. Most devices
want the `arm64-v8a` build; `universal` runs anywhere but is larger.

## Building

```sh
./gradlew assembleRelease
```

Release builds are signed with the keystore named in `keystore.properties`. An iPad version is
being built on the [`ios`](https://github.com/Grillza/doki/tree/ios) branch.

## Help and issues

For problems with Dōki itself, open an [issue](https://github.com/Grillza/doki/issues).
For general reader questions, Mihon's [FAQ](https://mihon.app/docs/faq/general) and
[troubleshooting guide](https://mihon.app/docs/guides/troubleshooting/) still apply. Extensions are
not made or supported here.

## Credits

Dōki is built on [Mihon](https://github.com/mihonapp/mihon) and
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
