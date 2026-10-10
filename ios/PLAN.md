# Mihonka for iOS: plan

A native SwiftUI app for iPhone and iPad that reads manga and comics from a **Kavita** server
and syncs reading progress with it, the same way the Android app does. It's for personal use
and is installed by sideloading.

This file is the hand-off point: a fresh session on the Mac should be able to start from here
with no other context. Work through the [milestones](#milestones) in order.

## Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Technology | **Native Swift + SwiftUI** (UIKit only where SwiftUI falls short, e.g. the zooming reader) | Native reader feel and iPad behaviour. Mihon's reader is Android views, so it would be rewritten anyway |
| Location | **`ios/` in this repo** | The Android Kavita code stays next to it as the reference implementation |
| Sources | **Kavita only.** No Tachiyomi extensions, no extension runtime | Not needed. Kavita is the only thing this app talks to |
| Code sharing | **None.** Kavita logic is *ported* to Swift, with its tests | Only ~1,250 lines would be shareable; a Kotlin Multiplatform refactor of the Android app costs more than porting |
| Cross-device sync | **Through Kavita** | The Android and iOS apps both sync progress with Kavita, so they never need to talk to each other |
| Distribution | **Sideload** (SideStore/AltStore, or Xcode straight to the device) | No App Store |

## Building and installing (README)

Version 1 is complete (milestones 1–9). To build and install it:

**Requirements:** a Mac with Xcode 27 or later, `brew install xcodegen swiftlint`, and an
iPhone or iPad on iOS 18 or later. The main target is an iPad mini on iOS 27.

**Build an .ipa and sideload it** (free Apple ID):

1. `ios/scripts/build-ipa.sh` builds an unsigned `ios/build/Mihonka.ipa` (Release).
2. Copy it to the device (AirDrop, Files) and install it with **SideStore** or **AltStore**,
   which sign it with your Apple ID.
3. With a free Apple ID the app must be re-signed every **7 days**; SideStore can refresh it on
   the device. The app's data (library, progress, downloads) survives a refresh.

**Or run it from Xcode:** `cd ios && xcodegen`, open `Mihonka.xcodeproj`, choose your Personal
Team under Signing & Capabilities, plug the device in, and run. Developer Mode must be on.

**First launch:** Settings → enter the Kavita server address (e.g. `https://kavita.example.com`
or `192.168.1.10:5000`) and the API key from Kavita (your user settings → API Key / OPDS).
The status shows "Connected to Kavita". Then Browse → Kavita, press and hold a cover to add a
series to the Library, and tap it to read.

**Using it:**

- **Reading:** tap the left or right third to turn pages (in reading direction), the middle for
  the overlay. Double-tap or pinch to zoom. The overlay's menu picks the mode for the series
  (left to right, right to left, webtoon) and, on iPad, two-page spreads in landscape. With a
  keyboard, the arrow keys and space turn pages and Escape closes the reader.
- **Progress** syncs with Kavita page by page, both ways, as on Android: the side that has read
  further wins, except marks made by hand. Offline progress is queued (Settings shows how much)
  and sent when the server is reachable again.
- **Downloads:** the button on each chapter row, Select → Download, or the series' download
  menu. Downloaded chapters open without a network. The Downloads tab shows the queue and
  what's on the device.

**Developing:** `ios/scripts/check.sh` generates the project, builds, runs all tests on the
iPad mini simulator, and fails on warnings. Live tests against a Kavita server are described
under [Working notes](#working-notes-for-the-session-doing-the-work).

## Scope

### Version 1

1. **Settings:** Kavita server address and API key. A connection status shows the username
   and Kavita version, or the error. A toggle turns progress sync on and off.
2. **Browse and Library, as in Mihon:**
   - **Browse** lists Kavita as a source. Opening it shows a grid of the server's series with
     covers, filterable by Kavita library, searchable by name, and sortable (name, date
     created, last chapter added, read progress). EPUB series are excluded, as on Android.
   - **Library** shows only the series you've added (from the series screen), stored locally.
3. **Series screen:** cover, summary, authors, genres and status, an "Add to library" /
   "In library" toggle, then the chapter list in
   **Kavita reading order**. Each row shows read/unread state and how far you've got. You can
   mark one or many chapters read or unread, and download chapters.
4. **Reader:**
   - Paged mode, left-to-right and right-to-left.
   - Vertical continuous (webtoon) mode.
   - Pinch and double-tap zoom.
   - On iPad, optional two-page spreads in landscape.
   - Tap zones for page turns, a page slider, and moving into the next or previous chapter at the ends.
   - The mode is remembered per series, with a default in settings.
5. **Progress sync:** two-way and page-level, **with exactly the Android rules** (see
   [Progress sync](#progress-sync-the-rules-to-port-exactly)). Includes an offline queue that
   is delivered later.
6. **Downloads:** save chapters for offline reading. Downloaded chapters open without a network,
   and progress made offline is queued. You can delete downloads per chapter or per series.

### Out of scope for version 1

Trackers (AniList and others), categories, backups, update notifications, extensions or other
sources, EPUB/text reading, Kavita reading lists and collections, and syncing with the Android
app other than through Kavita.

**Possible later additions:** a "continue reading" shelf (Kavita has an on-deck endpoint), a
widget, reading lists, and background library refresh.

## Mac setup (do this first)

1. Install **Xcode** (latest) from the App Store, open it once, and accept the licence and
   components.
2. Install Homebrew if needed, then `brew install xcodegen swiftlint`.
3. In Xcode → Settings → Accounts, sign in with your Apple ID; this creates a free "Personal Team".
4. Clone and switch to the branch: `git clone https://github.com/Grillza/mihonka && cd mihonka && git checkout ios`
5. Install Claude Code on the Mac and run it from the repo root. Point it at this file:
   *"Read ios/PLAN.md and start milestone 1."*

### Getting it onto the device

- **Simplest:** plug the iPhone or iPad into the Mac and run from Xcode with your Personal
  Team. On the device, enable Developer Mode and trust the developer certificate.
- **Sideload an .ipa:** build an archive (`xcodebuild archive` + `-exportArchive`, or a script
  in `ios/scripts/`) and install it with SideStore or AltStore.
- **Free Apple ID limits:** apps expire after **7 days** and must be re-signed (SideStore can do
  that on the device). You can have at most 3 sideloaded apps. A paid developer account ($99/yr)
  extends signing to a year.

## Project setup

```
ios/
  PLAN.md                    this file
  project.yml                XcodeGen spec: the .xcodeproj is generated, not committed
  Mihonka/                   app target
    App/                     MihonkaApp.swift, root navigation, dependency container
    Kavita/                  port of app/src/main/java/mihonka/kavita/: API, models, ordering, sync
    Data/                    database (GRDB), records, migrations, repositories
    Features/
      Settings/
      Library/               added series (Mihon-style favourites)
      Browse/                sources list; the Kavita source browses the server
      Series/
      Reader/                UIKit-backed paged and webtoon readers wrapped for SwiftUI
      Downloads/
    Resources/               Assets.xcassets, Info.plist entries, Localizable.xcstrings
  MihonkaTests/              XCTest, including ports of the Android Kavita tests
  scripts/                   build-ipa.sh, etc.
```

- **XcodeGen** (`project.yml`) generates `Mihonka.xcodeproj`. That keeps the project definition
  as reviewable text with no merge conflicts. Commit `project.yml` and git-ignore `*.xcodeproj`.
  After pulling, run `cd ios && xcodegen`.
- **Bundle id** `app.mihonka`, matching Android. Display name **Mihonka**.
- **Minimum iOS 18** (raised from 17 on 2026-10-10). That gives Observation (`@Observable`),
  the modern SwiftUI navigation APIs, `ScrollView` paging improvements, and the `Tab` API with
  `.sidebarAdaptable`. iPhone and iPad, all orientations.
- **Swift 6 language mode** with strict concurrency. Use `async/await` and actors throughout.
- **Dependencies** (Swift Package Manager), kept deliberately small:
  - [GRDB](https://github.com/groue/GRDB.swift) for SQLite. Predictable migrations and easy to
    test. Chosen over SwiftData for explicit control of the schema and of the sync queue.
  - [Nuke](https://github.com/kean/Nuke) for image loading, decoding and caching (covers and pages).
  - Nothing else unless a milestone clearly needs it.
- **Secrets:** store the API key in the **Keychain**, not UserDefaults. Store the server address in UserDefaults.

### App Transport Security (plain http)

People often run Kavita on plain `http://` on the LAN (e.g. `http://192.168.1.10:5000`). iOS
blocks that by default. Set these Info.plist keys:

- `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`, which covers local IPs and `.local`
  names. Also set `NSAllowsArbitraryLoads = YES`, because this is a personal sideloaded app and
  the server address is user-supplied. Add a comment saying that.
- `NSLocalNetworkUsageDescription`, e.g. "Mihonka connects to your Kavita server on your local
  network." This is required for the local-network permission prompt.
- HTTPS (Tailscale `*.ts.net`, a reverse proxy) is still the recommendation shown under the
  server field.

## The Kavita behaviour to port

The Android implementation in `app/src/main/java/mihonka/kavita/` is the source of truth:
`KavitaApi.kt`, `KavitaModels.kt`, `KavitaSource.kt`, `KavitaSync.kt`, `KavitaSyncWorker.kt`,
`KavitaPreferences.kt`. Its tests in `app/src/test/java/mihonka/kavita/` must be ported to
XCTest and pass. If this plan and that code disagree, the code wins; note the difference here.

### Authentication

Kavita's plugin flow:

1. `POST {api}/Plugin/authenticate?apiKey=<key>&pluginName=Mihonka` with body `{}` returns
   `{ username, token, kavitaVersion }`. A 401 means a bad API key.
2. Every request to the server sends `Authorization: Bearer <token>` and
   `User-Agent: Mihonka-iOS v<version> (app.mihonka)`.
3. On a **401**, sign in again **once** and retry. If it fails again, report "Kavita rejected
   the API key."
4. Requests whose path contains `/image` (case-insensitive) also get `apiKey=<key>` as a query
   parameter, because Kavita's image endpoints authenticate that way. Add it only if it isn't
   already present.
5. Cache the token per (api URL, API key) pair and re-authenticate when either changes. Model
   this as an `actor KavitaClient` so concurrent requests share a single sign-in.

### Server address normalisation (`normalizeApiUrl`)

Trim whitespace and trailing `/`. If there's no scheme, prefix `http://`. If the string contains
`/api` (case-insensitive), cut everything from there. Append `/api`. Return nil if the result is
empty or not a valid URL.

| Input | Result |
|---|---|
| `https://kavita.example.com` | `https://kavita.example.com/api` |
| ` https://kavita.example.com/ ` | `https://kavita.example.com/api` |
| `192.168.1.10:5000` | `http://192.168.1.10:5000/api` |
| `https://example.com/kavita/` | `https://example.com/kavita/api` |
| `https://kavita.example.com/api/opds/0f8c…` | `https://kavita.example.com/api` |
| (whitespace only) | nil |

### Endpoints used

All are relative to `{api}` = the normalised address.

| Purpose | Request |
|---|---|
| Sign in | `POST /Plugin/authenticate?apiKey=&pluginName=Mihonka`, body `{}` |
| Libraries | `GET /Library/libraries` → `[{id, name, type}]` |
| Series list (browse/search) | `POST /Series/all-v2?pageNumber=N&pageSize=30`, filter JSON body. Read the `Pagination` response header (`{currentPage, totalPages}`); if it's missing, assume more pages when the page came back full |
| Series | `GET /Series/{seriesId}` |
| Series metadata | `GET /Series/metadata?seriesId=` → summary, genres, tags, writers, coverArtists, pencillers, publicationStatus |
| Volumes + chapters | `GET /Series/volumes?seriesId=`. This is also the source of per-chapter `pagesRead` |
| One chapter | `GET /Chapter?chapterId=` |
| Progress of one chapter | `GET /Reader/get-progress?chapterId=` → `{pageNum}`. **If it returns 404** (older servers), find the chapter in `/Series/volumes` and use its `pagesRead` |
| Save progress | `POST /Reader/progress`, body `{volumeId, chapterId, pageNum, seriesId, libraryId}` |
| Mark read/unread | `POST /Reader/mark-multiple-read` or `/mark-multiple-unread`, body `{seriesId, volumeIds: [], chapterIds: [...]}` |
| Cover | `GET /Image/series-cover?seriesId=` (`apiKey` added automatically) |
| Page image | `GET /Reader/image?chapterId=&page=<0-based>&extractPdf=true` (`apiKey` added automatically) |

**The filter body must include every field.** Kavita treats a missing `combination` as "or",
which would turn a search into "everything". With Swift's `Codable`, encode all properties
explicitly, including the defaults.

```json
{
  "statements": [{ "comparison": 7, "field": 1, "value": "berserk" }],
  "combination": 1,
  "sortOptions": { "sortField": 1, "isAscending": true },
  "limitTo": 0
}
```

**Constants:**

- Comparison: MATCHES = 7, CONTAINS = 5, NOT_CONTAINS = 8.
- Field: SERIES_NAME = 1, LIBRARIES = 19, FORMATS = 21.
- Sort: NAME = 1, CREATED = 2, LAST_CHAPTER_ADDED = 4, READ_PROGRESS = 7.
- Format: UNKNOWN = 2, EPUB = 3.
- PublicationStatus: ONGOING = 0, HIATUS = 1, COMPLETED = 2. ENDED and CANCELLED come from
  `KavitaConstants` in `KavitaModels.kt`; copy the exact values from there.

**Browse rules:**

- Every series query adds `{comparison: 8, field: 21, value: "3"}` to exclude EPUBs.
- Search adds a SERIES_NAME MATCHES statement with the trimmed query.
- A library filter adds a LIBRARIES CONTAINS statement with the library id as a string.
- The default sort is NAME ascending; the "latest" view is LAST_CHAPTER_ADDED descending.

### Models and number parsing

These follow `KavitaModels.kt`. Decode leniently: every field has a default, and unknown keys
are ignored.

- `volume.volumeNumber = minNumber ?? number ?? 0`
- `chapter.chapterNumber = minNumber ?? Float(number with "," replaced by ".") ?? -100000`
- Special numbers (Kavita 0.8+):
  - `LOOSE_LEAF_VOLUME_NUMBER = -100000`: the volume holding chapters that belong to no volume.
  - `SPECIAL_VOLUME_NUMBER = 100000`: the volume holding specials.
  - `DEFAULT_CHAPTER_NUMBER = -100000`: a chapter that is really a whole-volume file.
- Dates: Kavita sends local times **without an offset**. A value starting with `0001` means
  "not set". Parse with an offset first; otherwise treat it as local time.

### Chapter list: order, names and numbers

This follows `KavitaSource.chapterList`. The iOS app displays chapters in Kavita reading order,
oldest first, but it still needs the same numbers so behaviour matches Android.

Sort volumes by `volumeNumber`, and the chapters within each volume by `chapterNumber`. Classify
each chapter:

| Case | Name | Number | Bucket |
|---|---|---|---|
| `chapter.isSpecial` **or** volume is SPECIAL (100000) | `displayTitle ?? "Special"` | `index - 200000` (index = position among specials) | specials |
| Whole volume: `chapterNumber == -100000`, or (`minNumber == nil` and `number == "0"`) | `"Volume " + volDisplay`, plus `" - " + titleName` if `titleName` is non-blank and differs from the volume `name` | `volumeNumber - 100000` | volumes |
| Otherwise | `"Vol. X "` (omitted if loose-leaf) + `"Ch. "` + `(range non-blank ? range : formatNumber(chapterNumber))` + `" - " + titleName` if `titleName` is non-blank and differs from `range` | `chapterNumber` | loose-leaf → loose; else volumes |

*(Corrected in milestone 4 from `KavitaSource.kt`: the original table left out `"Ch. "` and
the `titleName` conditions.)*

Definitions:

- **Loose-leaf volume:** `volumeNumber == -100000`, or (`minNumber == nil` and `volumeNumber == 0`).
- **volDisplay:** the volume `name` if it isn't blank or `"0"`, else `formatNumber(volumeNumber)`.
- **displayTitle:** the first non-blank of `titleName`, `title`, `range`.
- **formatNumber:** whole numbers without a decimal (`3`, not `3.0`).

**Reading order = volumes bucket, then loose chapters, then specials.**

Tests to port from `KavitaChapterNumbersTest.kt`:

- Volume and special numbers are always below -2.
- Every volume and special gets its own unique number, in order.
- Every special number is below every volume number.

Keep each chapter's `seriesId`, `libraryId`, `volumeId` and `pages` with the chapter record.
They're needed for every progress update; this is the equivalent of Android's chapter memo.

### Progress sync: the rules to port exactly

From `KavitaSync.kt`. Progress is per chapter:

- **`lastPageRead`:** the 0-based index of the page being viewed.
- **`read`:** a boolean.
- **Kavita's `pagesRead`:** on the server, a chapter counts as read once
  `pagesRead >= pages`, so the two map onto each other directly.

**The core rule:** the side that has read further wins, so reading on another device while
this one was offline is never undone. **The one exception** is marking chapters read or unread
by hand. That's deliberate, so it's sent as is.

**Pending queue.** Queued changes are stored in the database:

- **Entry fields:** `{chapterId, seriesId, libraryId, volumeId, pageNum, markedByUser, queuedAt}`.
- **One entry per chapter.** A new entry replaces the old one, but `markedByUser` stays true if
  either entry had it (`mergePending`). That way, reading on after "mark unread" keeps the
  mark's priority until it's delivered.
- **Removing a delivered entry:** remove it only if it hasn't been replaced in the meantime.
  Compare the whole entry.
- **`shouldSend(entry, serverPagesRead)`:** `entry.markedByUser || entry.pageNum > serverPagesRead`.
- **Delivering one entry:**
  1. Work out the server value. For a hand mark, use 0. Otherwise use the known server value,
     or else ask `get-progress`.
  2. If `shouldSend` is true, call `saveProgress` and remove the entry → Sent.
  3. If it's false, remove the entry → Dropped. The next pull brings the server's progress down.
  4. If there's a network or server error, keep the entry and schedule a retry → Failed.
- When flushing the queue, **stop at the first failure**, since the server is probably unreachable.

**Push triggers:**

- **Page change in the reader:** debounce **1.5 s per chapter**, then queue
  `pageNum = chapterRead ? pages : pageIndex` (not a hand mark) and deliver.
- **Marking read or unread from the series screen:** cancel any pending debounce for those
  chapters. Queue `pageNum = read ? pages : 0` with `markedByUser = true`. Then call
  `mark-multiple-read` or `-unread` for all of them in one request. Remove the entries on
  success; otherwise keep them and schedule a retry.
- Clamp `pageNum` to `0...pages`.

**Pull/reconcile (`syncSeries`)** runs:

- when a series is opened,
- when the reader opens (wait at most a short timeout, then continue with local progress),
- after the chapter list is refreshed,
- after queued changes are delivered.

Steps:

1. Fetch `/Series/volumes`. Reuse data fetched in the last 30 s if the chapter refresh just got
   it. Build `remote[chapterId]`.
2. **Deliver queued entries for this series first**, judged against `remote[...].pagesRead`.
   Stop at the first failure. Skip the chapters that were sent or are still queued in the
   comparison below.
3. For each local chapter that also exists remotely with `pages > 0`, where
   `serverRead = pagesRead >= pages`:

   | Local state | Action |
   |---|---|
   | `local.read && !serverRead` | Push read: collect, then send with `mark-multiple-read` |
   | `!local.read && serverRead` | Set local `read = true` |
   | `!local.read && server.pagesRead > local.lastPageRead` | Set local `lastPageRead = server.pagesRead` |
   | `!local.read && local.lastPageRead > server.pagesRead` | Push `saveProgress(min(lastPageRead, pages - 1))` |

4. Apply the local updates in one transaction.
5. **Queue the pushes before sending them**, so nothing is lost if the connection drops partway.
   Send them, then remove them from the queue. On failure, schedule a retry.

**Library sync:** reconcile every series in the library, then flush the queue. Run it on app
launch (if configured) and on pull-to-refresh in the library.

**Retries:** the Android app uses WorkManager. On iOS:

- `NWPathMonitor` flushes the queue when the network comes back.
- Flush on `scenePhase == .active` and when the app goes to the background.
- A `BGAppRefreshTask` handles opportunistic background delivery. Register its identifier in
  Info.plist (`BGTaskSchedulerPermittedIdentifiers`).

**Sync rule tests to port** from `KavitaSyncRulesTest.kt`:

- A page read offline is sent when it's further than the server's: 10 vs 4 → send.
- A page read offline never undoes progress on another device: 10 vs 20 → no; 10 vs 10 → no;
  20 vs 20 → no.
- Marking a chapter unread by hand always goes through: page 0, marked, vs 20 → send.
- Reading on after marking unread keeps the mark's priority until delivered.
- `mergePending(nil, p, false).markedByUser == false`.

Also add **engine tests** using a fake `URLProtocol` server, covering:

- the queue surviving a failed request,
- stopping at the first failure,
- pull rules 1–4,
- the 404 fallback for `get-progress`,
- re-authentication on 401.

## Local data model (GRDB)

| Table | Contents |
|---|---|
| `series` | Kavita series id (PK, column `id`), `libraryId`, name, summary, authors, genres, status, `inLibrary` flag, `readerMode` override, `lastOpenedAt`. No `coverUrl`: it's built from the id when shown, since it contains the server address and API key |
| `chapter` | Kavita `chapterId` (PK), `seriesId`, `volumeId`, `libraryId`, name, `number` (as above), `readingOrder` index, `pages`, `read`, `lastPageRead`, `dateUpload`, `isDownloaded` |
| `pendingProgress` | the sync queue described above, with `chapterId` as PK |
| `library` | Kavita libraries, for the filter |

Use migrations from day one (`DatabaseMigrator`).

**Decided:** the library is *series you've added*, like Mihon's favourites (`inLibrary = true`).
Kavita's full catalogue is browsed through the Kavita source under Browse. Series opened from
Browse but not added are still cached in `series` and `chapter` so the reader and sync work.

## Reader design

- A **UIKit core wrapped with `UIViewControllerRepresentable`:**
  - **Paged mode:** `UIPageViewController`, or a horizontal `UICollectionView` with paging.
    Each page is a `UIScrollView` for zoom: double-tap to zoom, and zoom resets when the page
    changes. Right-to-left mode uses `semanticContentAttribute = .forceRightToLeft`, or reverses
    the data source.
  - **Webtoon mode:** a vertical `UICollectionView` with images at full width and aspect-correct
    heights. Pinch zoom is done by wrapping the collection view in a zooming scroll view. Keep
    the reading position steady when images finish loading above the viewport; Android had a
    gap bug here, see commit d1c5c12bd.
  - **iPad spreads:** in landscape paged mode, pair pages two at a time with an option for
    "first page alone" (covers). Landscape-orientation (wide) images are shown on their own.
- **Overlay:** title, chapter name, page slider, mode switch, and previous/next chapter buttons.
  A single tap toggles it.
- **Image loading:** a Nuke pipeline. Prefetch ±3 pages. Load from disk for downloaded chapters.
  Limit memory use with downsampling to screen size, because long webtoon strips can be huge.
- **Progress hooks:** report the visible page index to the sync engine (debounced) and save
  `lastPageRead` locally right away. Mark the chapter read when its last page is reached.
- **Chapter transitions:** at either end of a chapter, show a short transition page naming the
  next or previous chapter, then continue into it.

## Downloads

- **Storage:** `Application Support/Downloads/<seriesId>/<chapterId>/<000>.<ext>`. Exclude it
  from iCloud backup (`isExcludedFromBackup`).
- **Download engine:** a background `URLSession` so downloads continue when the app is
  suspended. Run 2–3 page requests at a time, with a queue UI on the series screen and a global
  downloads list. Write a chapter's pages to a temp folder and move it into place only once all
  pages are complete, so a half-finished download never looks complete.
- **Image extension:** take it from the response `Content-Type` (Kavita can serve webp, avif,
  png or jpg). iOS 18 decodes webp and avif natively.
- **Offline:** downloaded chapters open with no network. Progress goes into the queue as usual.
- **Delete:** per chapter, per series, and "delete read chapters".

## Milestones

Each milestone ends with: builds with no warnings, tests pass, and it was run on a simulator
and, where relevant, on the device. Commit at the end of every milestone.

1. **Skeleton:** ✅ done
   - `project.yml`, app target, test target, GRDB and Nuke added, and the Info.plist keys
     (ATS, local network, background modes).
   - A root layout for Library / Browse / Downloads / Settings: a tab bar on iPhone and an
     adaptive tab bar/sidebar on iPad (`TabView` with `.sidebarAdaptable`).
   - `ios/scripts/build-ipa.sh` produces an unsigned `.ipa` that SideStore can sign.
2. **Kavita client and settings:** ✅ done
   - Port the models, `normalizeApiUrl`, auth and endpoints into `actor KavitaClient`.
   - The settings screen shows connection status. The API key is stored in the Keychain.
   - Port `KavitaUrlsTest` and the normalisation cases.
3. **Browse and Library:** ✅ done
   - Browse → Kavita source: a paged series grid with covers, search, library filter, sort and
     pull-to-refresh. EPUBs are excluded. The database stores Kavita libraries.
   - Library: a grid of the added series from the database, with pull-to-refresh running
     library sync. Adding and removing happens on the series screen (milestone 4).
4. **Series screen and chapter list:** ✅ done
   - Metadata, plus chapter ordering, naming and numbering exactly as specified above.
   - Port `KavitaChapterNumbersTest`. Mark read/unread for one chapter or a multi-selection
     (local only for now).
5. **Reader (paged):** ✅ done
   - Left-to-right and right-to-left, zoom, overlay and slider, and chapter transitions.
   - Local `lastPageRead` and `read` updates, and resuming at the last page.
6. **Progress sync:** ✅ done
   - The full engine: queue, debounced push, hand marks, reconcile on series and reader open,
     library sync, `NWPathMonitor` and scene-phase flushes, and `BGAppRefreshTask`.
   - Port `KavitaSyncRulesTest` and add the engine tests.
   - **Acceptance:**
     - Read on Android, open the same series on iOS → iOS shows the Android page.
     - Read further on iOS while offline, go back online → Kavita and Android get iOS's page.
     - Read further on Android meanwhile → it's never undone.
7. **Webtoon mode and iPad spreads,** with per-series reader settings and a default in settings. ✅ done
8. **Downloads:** engine, queue UI, offline reading, delete options. ✅ done
9. **Polish:** ✅ done
   - App icon (reuse `icons/`), empty and error states, and accessibility labels.
   - Dark mode check, iPad multitasking and keyboard shortcuts (arrow keys turn pages).
   - A README section in this file on building and installing.

## Working notes for the session doing the work

- **Read the Android files** listed in [The Kavita behaviour to port](#the-kavita-behaviour-to-port)
  before writing the Swift equivalents. Port behaviour, not structure: Swift idioms, actors,
  `Codable`.
- **Keep this file current.** Tick off milestones, record decisions made along the way, and note
  anything where iOS deliberately differs from Android.
- **Build and test from the CLI** so results are checkable: `ios/scripts/check.sh` generates the
  project, does a clean build, runs the tests on the iPad mini simulator, and fails on any
  warning in our sources. Day-to-day builds and tests are iPad-only to save time (the user's
  request, 2026-10-10); the app stays universal. Set `IPHONE_SIMULATOR="iPhone 18 Pro"` to add
  an iPhone run, and `IPAD_SIMULATOR` to pick another iPad. For quick builds use
  `-destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)'`, not
  `generic/platform=iOS Simulator`, which also compiles x86_64. Lint with `cd ios && swiftlint`.
- **Live tests** (`KavitaLiveTests`, `LiveUITests`) run against a real Kavita server and are
  skipped unless it's given: `TEST_RUNNER_KAVITA_LIVE_URL=… TEST_RUNNER_KAVITA_LIVE_KEY=…
  ios/scripts/check.sh` (add `TEST_RUNNER_SCREENSHOT_DIR=…` for Settings screenshots). Kavita's
  public demo works: `https://demo.kavitareader.com`, signing in as `demouser` / `Demouser64`
  through `POST /api/Account/login` returns an `apiKey`.
- **Don't touch the Android app** from this work, except to read it. Android changes go on their
  own branch.
- **Commits:** small, one per milestone or sub-step, on the `ios` branch.

## Progress log

### Milestone 1: skeleton (2026-10-10)

- Built with Xcode 27.0 (iOS 27 SDK, Swift 6.4) on the Mac, with a minimum of iOS 18.
- `Info.plist` is generated by XcodeGen from the `info:` section of `project.yml`, so the ATS
  comment lives there, and the generated plist is git-ignored along with the `.xcodeproj`.
- Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`), so "builds with no warnings" is enforced.
- The background refresh task identifier is `app.mihonka.progress-sync` (`UIBackgroundModes` = `fetch`).
- The test target links only the app. GRDB and Nuke come in through the host app, so they
  aren't duplicated, and tests can still `import GRDB`.
- Root layout: a single `TabView` using the `Tab` API with `.sidebarAdaptable`. That's a tab
  bar on iPhone, and on iPad a top tab bar that the user can expand into a sidebar.
- The dependency container in `App/` is left until milestone 2, when there's something to hold.
- `ios/scripts/build-ipa.sh [out-dir]` writes an unsigned `build/Mihonka.ipa`.
- Verified: tests pass and the app launches on the iPhone 18 Pro and iPad mini (A17 Pro)
  simulators (iOS 27.0). Not yet installed on a real device.

### Milestone 2: Kavita client and settings (2026-10-10)

- `Kavita/KavitaModels.swift`, `KavitaClient.swift` and `KavitaSettings.swift` port `KavitaModels.kt`,
  `KavitaApi.kt` and `KavitaPreferences.kt`. `App/AppModel.swift` is the dependency container,
  injected with `.environment`.
- **Deliberate difference from Android:** `normalizeApiUrl` only cuts at `/api` as a *path
  segment after the host*. Android cuts at the first `/api` anywhere, so `https://api.example.com`
  becomes `https://api` and `https://example.com/apiary` becomes `https://example.com`. This is
  probably worth fixing on Android too. An input with no host (`https://`) returns nil.
- Numbers are `Double` (Android uses `Float`); they're only compared locally.
- Models decode leniently through `KeyedDecodingContainer.lenient(_:default:)`: a missing, null
  or wrongly typed field takes its default. `KavitaUser.token` and each object's `id` are required.
  A chapter `number` sent as a JSON number is accepted too.
- Sign-in: `actor KavitaClient` keeps one session per (api URL, API key). Concurrent requests
  await the same sign-in `Task`. On a 401 it signs in again only if the refused token is still
  the current one, then retries once. The connection status reaches the UI through
  `connectionChanges` (an `AsyncStream` that keeps only the newest value).
- The API key is in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`, so background refresh
  can use it), cached in memory. The server address and the sync toggle are in UserDefaults.
- Settings saves and re-checks 300 ms after an edit, and on opening, as on Android.
- `KavitaUrlsTest`'s manga/chapter URL half isn't ported: iOS stores Kavita ids directly instead
  of encoding them in Mihon URLs. `seriesWebURL` is tested instead.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS` doesn't promote every diagnostic group (a main-actor
  isolation warning got through), so `check.sh` also fails on warnings found in the log.
- `Package.resolved` is now committed (GRDB 7.11.1, Nuke 12.9.0) through `.gitignore` exceptions.
- Verified: all tests pass on both simulators, and the live tests passed against the Kavita
  demo server (0.9.1.4). Settings shows "Connected to Kavita 0.9.1.4 as demouser".

### Milestone 3: Browse and Library (2026-10-10)

- `Data/AppDatabase.swift` holds the GRDB setup and migration `v1` (`library`, `series`), in
  `Application Support/mihonka.sqlite`. `Data/Records.swift` has the records and queries;
  views observe the database with `ValueObservation` (`for try await` in `.task`).
  `chapter` and `pendingProgress` come in their own migrations (milestones 4 and 6).
- Browse → Kavita (`KavitaBrowseView` + `KavitaBrowseModel`): a paged grid (30 per page, loads
  more near the end), search (debounced 350 ms), library filter, sort (name, recently added,
  last chapter added, reading progress) with an ascending toggle, and pull-to-refresh.
  `KavitaBrowseRequest.filter` ports Android's statements and always excludes EPUBs.
  Results for an older request are dropped, and series already shown are de-duplicated.
- Kavita libraries are saved to the database whenever Browse opens, so the filter works offline.
- **Long-press a cover in Browse to add it to the library, or remove it**, as in Mihon. Series
  in the library are dimmed with an "In library" badge. Removing keeps the cached row.
- Library: series with `inLibrary`, sorted by name. Pull-to-refresh currently refreshes names
  and libraries from Kavita; library sync (progress) joins it in milestone 6.
- Covers: Nuke's `LazyImage`, downsampled to the grid size, with the disk cache
  (`ImagePipeline(configuration: .withDataCache)`). `seriesCoverURL` / `pageImageURL` include the
  `apiKey` so Nuke can load them without the bearer token.
- Builds and tests are iPad-only by default (see the working notes); `check.sh` prints a
  summary from the result bundle, including skipped tests.
- Verified on the iPad mini simulator: 51 tests pass, including the live tests against the demo
  server. They browse Kavita (covers load), add a series by long-press, see it in Library with
  its cover, and remove it. Paging, search, filter and sort are covered by stub-server tests;
  the demo server has only 10 non-EPUB series, so paging wasn't exercised live.

### Milestone 4: series screen and chapter list (2026-10-10)

- `Kavita/KavitaChapters.swift` ports `KavitaSource.chapterList`, `mangaDetails` and `parseDate`.
  The chapter list is shown in Kavita reading order (Android reverses it to newest first).
  Dates: an offset or `Z` is honoured; otherwise the value is local time; `0001…` means not set.
- Migration `v2`: the `chapter` table (PK = Kavita chapter id, cascade-deleted with its series)
  and a `series.artists` column (Android's `artist`: pencillers, else cover artists).
- Opening a series (from Browse or Library) caches it and refreshes series, metadata and volumes
  in parallel, then saves everything in one transaction. **Local reading state is kept** for
  chapters already stored, and chapters gone from the server are deleted. **New chapters are
  seeded from the server's `pagesRead`** while sync is on (`read = pagesRead >= pages`, else
  `lastPageRead = pagesRead`). That's what the milestone 6 pull would do for a chapter with no
  local progress, and it makes progress visible right away.
- Series screen: cover, title, authors, artists, status, add/remove from library, a summary that
  expands on tap, and genres and tags as chips. Chapters show the upload date and "Page x of y"
  when part-read; read chapters are dimmed. Mark read/unread by swipe or press-and-hold, several
  at once with Select, plus "Mark Previous as Read" (as in Mihon). Marking unread also resets
  `lastPageRead` to 0. **Marks are local only** until milestone 6. Pull-to-refresh is there too.
- Not yet: tapping a chapter opens nothing (the reader is milestone 5), and downloading
  chapters waits for milestone 8.
- `KavitaChapterNumbersTest` is ported except its `calculateChapterGap` case, which tests
  Mihon's missing-chapter detection; iOS has none.
- Verified on the iPad mini simulator: 71 tests pass. The live UI test opens a demo series
  (8 chapters with dates and the server's progress), marks a chapter read then unread, and
  toggles the library button.

### Milestone 5: paged reader (2026-10-10)

- `Features/Reader/`: `ReaderModel` (chapter, page, direction, progress), `PagedReaderController`
  (UIKit) with `ReaderCells.swift`, `PagedReaderView` (the `UIViewControllerRepresentable`
  bridge) and `ReaderView` (full-screen SwiftUI with the overlay).
- **Paging is a horizontal `UICollectionView`**, not `UIPageViewController`: slider jumps,
  prefetching and size changes are simpler. Right to left uses
  `semanticContentAttribute = .forceRightToLeft` with a flow layout that sets
  `flipsHorizontallyInOppositeLayoutDirection`.
- Items are `[leading transition] + pages + [trailing transition]`. A tap or swipe past a
  transition page opens the neighbouring chapter: the previous one at its last page, the next
  at page 1. The overlay also has previous/next chapter buttons.
- Taps: the outer thirds turn pages in reading direction (in right to left, the left third is
  next); the middle toggles the overlay. A single tap waits for the double-tap to fail, so
  there's a short delay.
- Zoom: each page is its own `UIScrollView` (1×–4×, pinch or double-tap to 2.5× at the tapped
  point). The image is fitted and centred, and zoom resets when the page changes. **Known
  limitation:** while zoomed, a swipe pans the page instead of turning it; zoom out first.
- Images: Nuke with the shared disk cache, downsampled to twice the view size in pixels (never
  upscaled), and ±3 pages prefetched with `ImagePrefetcher`.
- Overlay: series and chapter name, close, reading direction (saved per series in
  `series.readerMode`: `ltr` / `rtl`, default **right to left** as in Mihon), a page slider, and
  the chapter buttons. The bottom bar follows the reading direction.
- Progress: every page shown is saved to the database at once (`lastPageRead`). Reaching the
  last page marks the chapter read, and going back never unmarks it. Opening a chapter resumes
  at `lastPageRead`, or page 1 if it's read. The series header has Start/Resume for the first
  chapter not read. Nothing goes to Kavita yet; that's milestone 6's debounced push.
- If the chapter list had no page count, it's fetched with `GET /Chapter`.
- Verified on the iPad mini simulator: the live UI test opens a demo chapter, sees page 1 load,
  turns to page 2 with a left tap, checks "2 of 57" in the overlay, goes to the next chapter,
  closes, and sees "Page 2 of 57" on the chapter row. Right-to-left layout of the bar and slider
  was checked by screenshot. Not yet tried on a real device: pinch zoom and rotation.

### Milestone 6: progress sync (2026-10-11)

- `Kavita/KavitaSync.swift` (`actor KavitaSync`) ports `KavitaSync.kt` rule for rule:
  `shouldSend`, `mergePending`, delivery (sent / dropped / failed), the 1.5 s per-chapter page
  debounce, hand marks in one `mark-multiple-read/-unread` request, `syncSeries` (queued
  entries first, then the four pull rules, pushes queued before sending), `syncLibrary` and
  `syncQueued`. The comparison is a separate `Reconciliation` value.
- The queue is the `pendingProgress` table (migration v3), one row per chapter. Removing a
  delivered entry compares the change itself (progress + `markedByUser`), not `queuedAt`, since
  SQLite rounds dates to milliseconds.
- Hooks: page changes from `ReaderModel.pageShown`; hand marks from `SeriesModel.setRead` (so
  "mark previous as read" too); `syncSeries` after every series refresh, reusing the volumes
  the refresh just fetched (instead of Android's 30 s cache); library sync on launch and on
  pull-to-refresh in the Library.
- **Reader open:** `ReaderModel.prepare()` pulls first and waits at most 4 s (Android's
  `KAVITA_PULL_TIMEOUT`), then opens at the stored page. A slow pull isn't cancelled; it still
  lands in the database.
- **Retries** (`App/SyncTriggers.swift`): a failed delivery asks for a retry; the app retries
  with backoff from 1 to 30 minutes, flushes when `NWPathMonitor` sees the network come back,
  when the scene becomes active, and when it goes to the background (with
  `beginBackgroundTask`, sending pages still in their debounce first). A `BGAppRefreshTask`
  (`app.mihonka.progress-sync`, via SwiftUI's `.backgroundTask`) is submitted whenever
  something is left queued.
- **Deliberate difference:** `syncQueued` reconciles every series with queued changes, not only
  library ones, because series opened from Browse keep their chapters locally here.
- Settings shows how many chapters are waiting to be sent, with **Send Now**. Turning sync back
  on flushes the queue.
- Tests: `KavitaSyncRulesTests` (port of `KavitaSyncRulesTest`) and `KavitaSyncTests` against a
  fake Kavita: debounce, finished chapters, drops, the `get-progress` 404 fallback, the queue
  surviving failures, stopping at the first failure, re-sign-in on 401, sync off, hand marks
  (and a failed one winning later), the four pull rules, clamping, queue-before-compare, and the
  reader's pull and its timeout.
- **Acceptance**, `KavitaSyncLiveTests` on the demo server, with "another device" played by
  direct API calls: a page set elsewhere shows up after opening the series; a page read while
  offline (server address pointed at a dead port) is queued and reaches the server once back;
  a smaller page queued here never undoes a further page from elsewhere, which is pulled
  instead. Not yet tried with the real Android app on the same server, nor background refresh
  on a device (`BGTaskScheduler` doesn't run in the simulator).

### Milestone 7: webtoon mode and iPad spreads (2026-10-11)

- `ReaderMode` (`ltr` / `rtl` / `webtoon`) replaces the reading direction, still stored per
  series in `series.readerMode`. `ReaderSettings` (UserDefaults, `@Observable`) holds the
  default mode (right to left), **two-page spreads** (off by default) and **first page alone**
  (on). Settings has a Reader section; the reader's top-bar menu picks the series' mode and, on
  iPad in paged modes, toggles spreads.
- Both readers implement a small `ReaderController` protocol and share one SwiftUI bridge,
  `ReaderPagesView<Controller>`.
- **Spreads** (`PagedReaderController`): with spreads on and the view wider than tall, items
  are page groups from `PageSpreads.pair` (cover alone if set; wide pages alone; a page left
  over before a wide one or at the end alone). A page found to be wide once loaded re-pairs the
  chapter, staying on the current page. Rotation re-pairs too. A spread reports its later page
  as the one shown (both are on screen). `PageCell` lays one or two images side by side at one
  height, first page on the right in right to left, and zooms them together.
- **Webtoon** (`WebtoonReaderController`): a vertical collection view at full width inside a
  zooming scroll view (1×–3×, pinch or double-tap). Heights start as a guess (3:2) and are
  corrected as images load; the three pages either side of the reading position are loaded
  ahead so most corrections happen off screen, and a correction above the screen's top shifts
  the scroll position by the change above the top, so the view doesn't jump (Android's gap
  bug). Images are scaled to the screen width in pixels, never up. The current page is the one
  at the middle of the screen, or the last once the end is in view. Taps: top third back, bottom
  third on (75% of a screen), middle overlay; at an end, or pulling 80 pt past it, moves to the
  neighbouring chapter.
- `check.sh` now passes `-collect-test-diagnostics never`: after a UI test failure, collecting
  simulator diagnostics took ten minutes.
- Tests: `PageSpreadsTests`, reader mode defaults; live UI test
  `testReadsInSpreadsAndInWebtoonMode` rotates to landscape and finds a loaded two-page spread
  (screenshot: pages 2–3 with page 2 on the right), then switches to webtoon and checks that
  scrolling moves the page on. Not yet tried on a device: webtoon pinch zoom feel and long
  strips.

### Milestone 8: downloads (2026-10-11)

- **Queue:** the `download` table (migration v4): chapter, series, state (queued /
  downloading / failed), pages done and total, error. A finished chapter leaves the queue and is
  marked `chapter.isDownloaded`. On launch, interrupted downloads go back to queued.
- **Engine:** `actor DownloadManager` works through the queue one chapter at a time, three
  pages at once. Pages go to `Downloads/<series>/<chapter>.partial/<000>.<ext>` (extension from
  the response's `Content-Type`, via `UTType`), and the folder is renamed to `<chapter>` once
  every page is there. Pages already in the partial folder are kept, so a retry or a relaunch
  only fetches what's missing. A failed page fails the chapter (shown with its error, and
  retryable). The root is excluded from backup.
- **Transport:** `BackgroundPageFetcher` uses a background `URLSession`
  (`app.mihonka.downloads`) with download tasks, so pages keep coming while the app is
  suspended; `AppDelegate` passes `handleEventsForBackgroundURLSession` to it. Page URLs carry
  the `apiKey`, so no token is needed. A file finished for a task from before a relaunch is
  thrown away; the queue fetches the page again. Tests use `SessionPageFetcher` on the fake
  server.
- **Offline reading:** `ReaderModel` reads a downloaded chapter's files (page count from the
  files, `file://` URLs, no Nuke disk-cache writes). Progress goes through the sync queue as
  usual.
- **UI:** each chapter row has a download button that shows queued, a progress ring
  (tap to cancel), failed (tap to retry) or downloaded. Rows' context menu: Download / Cancel /
  Delete Download. Select mode: Download. The series toolbar's download menu: Download Unread,
  Delete Read Downloads, Delete All Downloads. The Downloads tab lists the queue (swipe to
  cancel, Retry Failed) and the series on the device with chapter counts and sizes (swipe to
  delete, tap to open).
- **Bug fixed:** since milestone 3 the on-disk database never opened, because `URL.path()`
  percent-encodes and "Application Support" became "Application%20Support"; the app fell back
  to an in-memory database, so the library didn't survive a relaunch. Paths now use
  `path(percentEncoded: false)`, with a regression test.
- **Not handled yet:** chapters deleted on the server keep their downloaded files until the
  series' downloads are deleted.
- Tests: `DownloadTests` (pages and extensions, sequential chapters, page count lookup,
  failure and partial retry, cancel, delete all / read, skip duplicates, resume on launch,
  offline reader). Live UI test `testDownloadsAChapterAndReadsItOffline`: downloads the first
  demo chapter (57 pages), finds it under Downloads, points the server at a dead port, and
  opens the chapter with its pages loaded from the device.

### Milestone 9: polish (2026-10-11)

- **App icon:** the Android adaptive icon (`app/src/main/res/drawable/ic_launcher_*.xml`)
  converted to `ios/design/AppIcon.svg`, with the ring and glyph scaled up 1.55× since iOS
  shows the whole square, rendered to a 1024 px PNG without alpha. (The plan said `icons/`,
  but that folder holds Material Symbols and Simple Icons, not the app icon.) The accent colour
  is the icon's blue, `#0058A0`, with `#7EBBED` in dark mode.
- **Keyboard:** in paged mode ← and → turn pages the way they point (← is next in right to
  left), space and shift-space go on and back; in webtoon ↓/↑ and space scroll. Escape closes
  the reader. Covered in the live UI test.
- **Dark mode:** checked by screenshot (series, Settings, Downloads); everything uses system
  colours. Fixed along the way: the series title and Resume button inherited the header's
  secondary style (`.primary` is relative to the inherited style), and the "In library" badge
  now uses the background colour for its text so it reads on both tints.
- **Accessibility:** chapter counts are inflected ("1 chapter"), the decorative cover in the
  series header is hidden from VoiceOver; rows, reader pages, the slider, the reader menu and
  the download buttons have labels and values (checked through the UI tests' queries).
- **iPad multitasking:** all orientations are supported and full screen isn't required, so
  Split View and Stage Manager work; both readers re-lay out on size changes (paged also
  re-pairs spreads).
- Empty and error states: Library, Browse (including "not set up"), series, reader and
  Downloads each have one.
- README: [Building and installing](#building-and-installing-readme) at the top of this file.

**Still to try on a real device:** pinch zoom and rotation in both readers, background
downloads and background progress delivery (neither runs fully in the simulator), and
cross-device sync with the Android app on the same server.

## Open questions

Answer these as they come up, and record the answers here:

1. ~~Should the library show all Kavita series, or only ones you've added?~~ **Answered
   2026-10-10:** like Mihon. Kavita appears as a source under Browse, and you add the series
   you want to the library.
2. ~~Free Apple ID or a paid developer account?~~ **Answered:** a free Apple ID. The app must be
   re-signed every 7 days (SideStore can do that on the device). Don't rely on entitlements a
   free Personal Team can't sign, such as iCloud, push notifications or app groups. Background
   fetch and background `URLSession` are fine.
3. ~~Main iPad and iOS version?~~ **Answered:** the latest iPad mini on iOS 27. AVIF and WebP
   decode natively there. The minimum is iOS 18 (enough for the `Tab` API, without
   ruling out an iPhone that isn't on 27). Test on an iPad mini simulator as well as an
   iPhone one.
