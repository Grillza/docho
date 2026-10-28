# Mihonka for iOS: plan, part 2

Version 1 ([PLAN.md](PLAN.md), milestones 1–9) is finished and runs on the iPad. Part 2 brings
the iOS app up to the Android app:

1. **A download indicator** while chapters download, like Android's download notification.
2. **The same sync settings and options as Android:** Kavita, BookOrbit and KOReader sync, and
   the "Sync progress with" choice.
3. **Android's settings mirrored** where they make sense on iOS.
4. **Tachiyomi/Mihon extensions**, run the way Tachimanga runs them: the Android extension APK,
   converted on the device and run in a JVM embedded in the app.
5. **Komga** as a built-in source with page-by-page progress sync, like Kavita and BookOrbit, so
   the app covers the common self-hosted servers when it's published.

Like part 1, this file is the hand-off point for a session on the Mac. Read PLAN.md's
[working notes](PLAN.md#working-notes-for-the-session-doing-the-work) first; they still apply
(`ios/scripts/check.sh`, iPad-first testing, small commits on `ios`, Android is the reference).
Work through the [milestones](#milestones) in order and keep the progress log at the end current.

## Decisions

These replace part 1's where they disagree. Part 1's "Kavita only, no extension runtime" and
"code sharing: none" are superseded by the first three rows.

| Decision | Choice | Why |
|---|---|---|
| Sources | **Kavita, BookOrbit, Komga, and installed extensions** | Matches Android, plus Komga for a published app |
| Built-in sources | **Swift**, as Kavita is now. BookOrbit is ported like Kavita was, and Komga written the same way from [Part H](#part-h-komga) | Kavita's Swift port works and is tested, and its sync queue lives in GRDB. Built-ins must work offline and start instantly, which a JVM doesn't |
| Extensions | **An embedded JVM runs the unmodified Android extension APKs** (dex2jar on the device, then a class loader), with Suwayomi's Android compatibility layer | It's how Tachimanga does it ([research](#how-tachimanga-runs-extensions)), and the only way to use the existing extension repos without rewriting extensions |
| Extension runtime origin | **Fork [oneechan-runtime](https://github.com/leros1337/oneechan-runtime)** to `Grillza/mihonka-runtime` and use the fork, behind our own Swift protocol. Take upstream fixes by merging deliberately. If the trial (milestone 16) fails, rebuild the host in the fork from its `jvm-ios` approach and Suwayomi's `AndroidCompat`; don't start from scratch | It already does the hard parts for a Swift app. Writing our own gains nothing in App Review, but a week-old, one-author upstream is a risk for an app we keep, so we own the copy we ship (MPL-2.0 allows it) |
| JVM | **Eclipse OpenJ9 only** (what oneechan builds), never OpenJDK's HotSpot | OpenJ9's licence (EPL-2.0/Apache-2.0) works on the App Store; HotSpot's GPLv2 is the kind of licence that got VLC pulled. See [App Store route](#app-store-route) |
| App ↔ JVM | **JSON calls over JNI** through a small C shim, with **page images and HTTP bodies as raw bytes**. All networking goes through **URLSession** | Keeps the Swift side in charge of networking, cookies and Cloudflare (WKWebView), as Tachimanga and oneechan both do |
| Sync choice | **"Sync progress with: Default (each series with its source) or KOReader"**, app-wide, as on Android | Same behaviour on both apps against the same servers |
| Download indicator | **An in-app download bar, plus the system's progress Live Activity through `BGContinuedProcessingTask` on iOS/iPadOS 26+.** No widget extension | iPadOS 26 shows a cancellable progress Live Activity for user-started tasks with no extra target. A widget extension would add an app ID, which counts against a free Apple ID's limits |
| Source ids | **The Android ids:** Kavita `0x4B415649544131` ("KAVITA1"), BookOrbit `0x424F4F4B4F5242` ("BOOKORB"). Komga, which Android doesn't have yet, gets `0x4B4F4D47413031` ("KOMGA01"); Android uses the same id if it adds Komga. Extensions use the id their `Source` reports | Keeps the door open for backups shared between the apps |
| Distribution | **Sideloaded with a free Apple ID for now; the App Store is the goal later.** Everything is built so it could pass review: see [App Store route](#app-store-route) | The JVM is an interpreter, so it needs no JIT entitlement either way |

## How Tachimanga runs extensions

Tachimanga is an iOS reader that installs ordinary Tachiyomi extension APKs. Its app isn't open
source, but its server is ([tachimanga/Tachidesk-Server](https://github.com/tachimanga/Tachidesk-Server)):

- The app (Flutter) embeds a fork of **Tachidesk/Suwayomi server**, the Kotlin program that runs
  Tachiyomi extensions on desktops. It ships `libs/sqlite-jdbc-ios-3.41.0.0.jar` and an
  `android.jar`, so this is a real JVM running on iOS.
- **Extensions are normal APKs.** Their [extension guide](https://tachimanga.app/help/guides/extensions_guide.html)
  is Tachiyomi's, ending in "Build APK(s)". On install, `PackageTools.dex2jar` converts the APK
  to a jar, which is loaded with a (child-first) `URLClassLoader` (`Extension.kt`, `PackageTools.kt`).
- **Android APIs** come from Suwayomi's `AndroidCompat` layer.
- **Networking is native:** `CallNativeNetInterceptor` hands OkHttp requests to iOS through JNI
  (`NativeNet.java`: `static native byte[][] call_utf8(byte[] jsonUtf8, Buffer buffer)`).
- iOS doesn't allow JIT compilation, so the JVM must be an **interpreter**. Which JVM Tachimanga
  uses isn't public. OpenJDK can now build a static interpreter-only `libjvm` for iOS
  ([InfoQ](https://www.infoq.com/news/2025/11/java-on-ios),
  [OpenJDK mobile-dev](https://mail.openjdk.org/pipermail/mobile-dev/2025-May/000947.html)), and
  oneechan-runtime uses Eclipse OpenJ9 in interpreter mode.

oneechan-runtime (MPL-2.0 per its README) packages the same design for a Swift app:
`jvm-ios/` builds OpenJ9 with the OpenJDK 21 class library as static libraries (about 40 minutes
the first time) and `package.sh` bundles them. `extension-host/` holds the host jar, built on
Suwayomi's `AndroidCompat` and the Tachiyomi source API. The app talks to it with versioned
JSON-RPC over JNI, and supplies URLSession networking, WKWebView for Cloudflare and extension
WebViews, and JavaScriptCore for QuickJS. Its `contract/fixtures` are shared with Swift tests.

## Part A: download indicator

**What Android does** (`DownloadNotifier.kt`): while downloading, an ongoing notification shows
"Series - Chapter" (cut to 30 characters) and a progress bar of pages downloaded out of pages,
with **Pause** and **Cancel** actions. When the queue is paused, it shows "Paused" with Resume
and Cancel. When the queue finishes, it shows "Download completed". Errors and warnings get their
own notifications, and tapping one opens the manga.

**iOS:**

1. **Download bar (all iOS versions).** While the queue isn't empty, show a compact bar above the
   tab bar on every tab except the reader:
   - It shows the series and chapter name, "Page 12 of 40", a progress bar, and "+3 queued".
   - It has pause/resume and cancel buttons. Tapping the bar opens the Downloads tab.
   - Use `tabViewBottomAccessory` on iOS 26+, and a `safeAreaInset(edge: .bottom)` overlay on 18–25.
   - The Downloads tab gets a badge with the queue count.
2. **Pause and resume**, which iOS lacks today: a `paused` flag on the queue, kept across
   launches. While paused, finish the current page and start no new ones.
3. **System progress on iOS/iPadOS 26+.** When the user starts downloads (a chapter, a selection,
   or "Download unread"), submit a `BGContinuedProcessingTaskRequest`:
   - Use the identifier `app.mihonka.downloads.<uuid>`, permitted as `app.mihonka.downloads.*` in
     `BGTaskSchedulerPermittedIdentifiers`.
   - The title is "Downloading", and the subtitle is "Series - Chapter". Its `progress` counts the
     pages of everything queued.
   - The system shows it as a Live Activity on the Lock Screen and Home Screen, which the user can
     cancel. Treat a cancel or expiry as **Pause**; the background URLSession keeps pages already
     in flight.
   - End the task when the queue empties or pauses. This API is meant for work the user starts,
     which downloads are. Automatic downloads must not use it.
4. **Notifications for finished and failed downloads.** These are local notifications, which work
   with a free Apple ID. Send "Download completed" when the queue empties while the app isn't in
   front, and "Download failed: Series - Chapter" with the error. Tapping one opens the series.
   Ask for permission the first time a download is started.

**Tests:** cover the queue → bar state mapping (queued, downloading, paused, failed, done), pause
surviving a relaunch, the progress totals, and the task ending on empty or pause. Then check on
the iPad that the Live Activity appears and that cancelling it pauses the queue.

## Part B: data model for more than one source

Today `series.id` and `chapter.id` are Kavita's ids. Migration **v5**:

- Add `source` (Int64) and `remoteKey` (String) to `series` and `chapter`, unique per
  `(source, remoteKey)`. Existing rows get Kavita's source id and their Kavita id as the key.
- **Keep the existing local ids** so download folders (`Downloads/<seriesId>/<chapterId>`) and
  queued progress stay valid. New rows take autoincrement ids above them. This needs a table
  rebuild, since SQLite can't add `AUTOINCREMENT` to an existing primary key.
- `remoteKey` is what each source understands:
  - Kavita: its id.
  - BookOrbit: Android's URLs, `/series/{id}` and `/book/{bookId}/file/{fileId}`.
  - Komga: `/series/{seriesId}` and `/book/{bookId}` (Komga ids are strings).
  - Extensions: the `SManga.url` and `SChapter.url`.
- Add a `memo` JSON column to `chapter` (Android's chapter memo), holding Kavita's
  series/library/volume ids, BookOrbit's ids, KOReader hashes and the file name used for sorting.
- `pendingProgress` gets a `source` column, and each sync engine only reads its own entries.
- Kavita code keeps using Kavita ids through `remoteKey`, and the stored ids stay valid.

**Tests:** a v4 database with series, chapters, downloads and queued progress migrates with
nothing lost and every download still opening.

## Part C: BookOrbit

Port `app/src/main/java/mihonka/bookorbit/` the way Kavita was ported (PLAN.md's approach: port
behaviour, not structure; the Android code wins over this summary):

- **Sign-in:** like BookOrbit's iPhone app, as a "native" client. The password is exchanged for an
  access token plus a refresh token. The refresh token is kept in the Keychain, so the account
  keeps one session instead of gaining one on every launch. `BookOrbitApi.kt` has the endpoints.
- **Browse:** Popular (name), Latest (last added), search, a library filter, and sort (name,
  recently added, number of books, reading progress).
- **Series and chapters:** each book with a comic file (`cbz`, `cbr`, `cb7`, `cbt`) is a chapter
  named "Vol. N - Title". Ebooks and audiobooks are left out. The newest is last in reading order.
- **Pages:** fetched by number from BookOrbit's comic page API, with the page count from its API.
- **Progress sync:** `BookOrbitSync.kt`, with the same rules as Kavita (the side that has read
  further wins, hand marks always go through, an offline queue). It sends the page number
  (1-based) and percentage that BookOrbit's own reader uses.
- **Unread listing** (Android's newest feature, see [Part F](#part-f-recent-android-features)).

## Part D: Sync settings, as on Android

Android's **Settings → Sync** (`SettingsSyncScreen.kt` and the `*SettingsGroup.kt` files next to
it) becomes the iOS Settings' first screen, **Sync**, using the same wording:

| Group | Items |
|---|---|
| **Reading progress** | **Sync progress with:** "Default - Sync with source" / "KOReader". The KOReader summary: "every series syncs with the KOReader sync server below instead of its source. Works for Kavita, BookOrbit, Komga and downloaded archives; online sources have no files to match, so they don't sync." |
| **Kavita** | Server address ("e.g. https://kavita.example.com"), API key ("Saved (hidden)"; "Copy it from Kavita: your user settings, under API Key / OPDS"), Connection ("Connected to Kavita 0.8.x as name", "Couldn't connect: …", tap to check), **Sync reading progress**, **Sync library now** ("Synced N Kavita series"), Browse Kavita, and iOS's "Waiting to be sent: N / Send Now" |
| **BookOrbit** | Server address ("The address you open BookOrbit at, e.g. http://bookorbit.lan:3010"), username and password ("The account you sign in to BookOrbit with"), Connection, Sync reading progress, Sync library now, Browse BookOrbit, waiting to be sent |
| **Komga** | Server address ("e.g. http://komga.lan:25600"), API key ("Create one in Komga: your account settings → API Keys"), Connection ("Connected to Komga as name"), Sync reading progress, Sync library now, Browse Komga, waiting to be sent. No Android equivalent yet; same wording pattern |
| **KOReader sync** | Server address ("The address KOReader uses, e.g. http://bookorbit.lan:3010/api/v1/koreader"), username, password ("In BookOrbit, create it under Settings → KOReader"), Connection ("Signed in as …"), Sync library now ("Only runs while sync is set to KOReader"), and the matching note |

**KOReader sync** (port of `mihonka/koreader/` and `sync/ProgressSync.kt`):

- **Routing:** one `ProgressSync` sends page changes, read marks and reconciliation to whichever
  sync applies to a series. In KOReader mode the sources' own syncs stand down.
- **Matching:** KOReader matches books by a **partial MD5 of the file** (`KoreaderHash.kt`). The
  hash comes from a document provider per source:
  - **Kavita:** its stored `koreaderHash` for single-file chapters, or one computed from ranged
    requests to the download endpoint.
  - **BookOrbit:** its stored file hash.
  - **Komga:** Komga's file download (`GET /api/v1/books/{id}/file`) only serves whole files,
    and its API doesn't share the KOReader hash it can store. As on Android (0.24.0,
    `KomgaKoreaderDocuments.kt`, `KoreaderHash.compute(InputStream, size)`), hash the file while
    it streams, reading up to the last sample and keeping nothing, and cache the hash per book.
    Only once the user allows it: choosing KOReader while Komga is set up shows a notice ("Komga
    and KOReader sync", with "I understand, sync Komga", "Don't sync Komga" and "Don't show this
    again"), and "Match Komga books" under KOReader sync changes it later. (Komga also runs a
    KOReader sync server at `{server}/koreader`, usable by KOReader itself.)
  - **Extensions:** no file, so they don't sync in KOReader mode.
  - iOS downloads are loose pages, not the archive, so they can't be hashed. Use the source's
    hash instead, even for a downloaded chapter.
- **Queue and rules:** an offline queue and the same "further wins, hand marks go through" rules.
  Reconciling covers only the chapters about to be read when a chapter opens, because KOReader
  needs one request per chapter.

**Tests:** port the Android sync rule tests that exist, and add stub-server tests for BookOrbit
sign-in and refresh, and for KOReader hashing (a known file and its expected partial MD5), push,
pull and mode switching.

## Part E: other Android settings on iOS

"Where appropriate" means: include it if it changes something the iOS app does, and leave it out
if it's Android-only or belongs to a feature iOS doesn't have.

| Android | iOS | Notes |
|---|---|---|
| **Reader:** default reading mode | ✅ have | Add "Vertical" (paged top-to-bottom) if wanted |
| Reader: show page number, keep screen on, background colour (black/white/grey/auto), fullscreen | **Add** | `isIdleTimerDisabled` while reading |
| Reader: tap zones (default/L-shaped/kindle/edge/off) and invert | **Add** | Per mode, as on Android |
| Reader: skip chapters marked read, always show chapter transition | **Add** | |
| Reader: scale type, zoom start position, double tap to zoom, disable zoom out | **Add** (the useful subset) | iOS has fit-screen only today |
| Reader: split wide pages, rotate wide pages | Later | Spreads already handle wide pages |
| Reader: crop borders | Later | Needs image analysis |
| Reader: e-ink flash, volume keys, cutout area, rotation lock | Skip | No iOS equivalent |
| **Library:** chapter swipe actions (left/right) | **Add** | iOS swipes are fixed today |
| Library: mark duplicate read chapter as read, hide missing chapter indicators | Add with Part F | Only once iOS shows chapter numbers and gaps |
| Library: automatic updates, smart update | **Add, limited** | `BGAppRefreshTask` runs when iOS decides, not on a schedule. Say so |
| Library: categories | Later | Out of scope in part 1 |
| **Downloads:** only on Wi-Fi | **Add** | `allowsExpensiveNetworkAccess = false` |
| Downloads: concurrent page downloads | **Add** | iOS uses 3 today |
| Downloads: delete after reading / after marking read, auto-download new chapters, download ahead while reading | **Add** | |
| Downloads: save as CBZ, split tall images | Skip | iOS stores pages |
| **Browse:** hide entries already in library | **Add** | |
| Browse: extension repos, allowed content warnings | **Add with Part G** | |
| **Appearance:** theme (system/light/dark), relative timestamps, date format | **Add** | Pure black and app language come from iOS itself |
| Tracking, backup, security, advanced | Skip for now | Backups could follow later, since the source ids match |

Group these as on Android: Sync, Reader, Library, Downloads, Browse, Appearance, About. Store
them in UserDefaults through the existing `@Observable` settings pattern (`ReaderSettings.swift`),
and keep secrets in the Keychain.

## Part F: recent Android features

These landed on Android on 2026-10-29 (version 0.22.0) and should match on iOS:

- **Chapter sort and filter,** from the series screen's menu:
  - Sort by source order, chapter number, upload date, alphabetically, or **by file name**.
  - File-name sort uses natural order, so v2 comes before v10. It reads the chapter memo's
    `fileName`: Kavita's file path (`files[].filePath`, folder removed), or BookOrbit's book
    title, which BookOrbit takes from the file name; or Komga's book `url` (the file path), folder
    removed. Otherwise it falls back to the chapter name.
    This is what keeps a series like JoJo, whose volume numbers restart per part, in order.
  - Ascending/descending, and filters for unread, downloaded and bookmarked.
  - Part 1 shows Kavita reading order only, which stays the default ("by source").
- **Unread listing in Browse:** next to Popular and Latest, Kavita, BookOrbit and Komga offer
  **Unread**: series not finished, most recently added first.
  - **Kavita:** filter `{comparison: 9 (NOT_EQUAL), field: 20 (READ_PROGRESS), value: "100"}`,
    sort LAST_CHAPTER_ADDED (4) descending. That's Kavita's own "unread" filter.
  - **Komga:** filter by read status unread or in progress, sorted `lastModified` descending
    (what Komga's own "latest" uses). Unlike BookOrbit, this runs on the server.
  - **BookOrbit:** its series API can only filter one status at a time, so load all series
    sorted by `lastAddedAt` descending, keeping those with `readCount < bookCount`.

## Part G: extensions

### What the user sees

- **Browse** gets Extensions next to Sources, as in Mihon:
  - **Repos:** add one by its URL, which is an `index.min.json` (Settings → Browse → Extension
    repos).
  - **Extensions:** available and installed, by language, with install, update and uninstall.
    Extensions from unknown signers need to be trusted first, as on Android. Content warnings
    filter the list per the Browse setting.
  - An installed extension's sources appear under Sources with Popular, Latest (if supported),
    search, filters and source settings.
- Series from extensions behave like Kavita's: add to the library, read, download, sort and
  filter, and local read progress. There's no server sync for extensions, as on Android without
  trackers.

### How it fits together

```
SwiftUI ── ExtensionSource (Swift, implements the app's Source protocol)
              │ async calls
           ExtensionHost (actor) ── C shim ── JNI ── host jar in the JVM
              ▲                                     ├─ extension loader (APK → dex2jar → jar, class loader)
              │ native services                     ├─ AndroidCompat (SharedPreferences, Context, …)
              │                                     └─ Tachiyomi source API (lib 1.4–1.6)
   URLSession · WKWebView (Cloudflare, WebView) · JavaScriptCore (QuickJS)
```

- **A Swift `Source` protocol** is introduced first (milestone 11): popular, latest, unread
  (optional), search with filters, details, chapters, pages and image request. Kavita and
  BookOrbit adopt it, so the Browse and series screens stop being Kavita-specific. Extensions are
  then one more implementation.
- **`ExtensionHost` actor:** starts the JVM lazily, the first time an extension source is used,
  with a visible "Starting extensions…" state, and keeps it running. It owns one serial JNI
  thread. Calls are JSON in and out, and images and HTTP bodies cross as raw bytes.
- **Networking:** extension OkHttp requests go to URLSession. Cookies are shared with a WKWebView
  that solves Cloudflare challenges, as Mihon's Cloudflare interceptor does.
- **Filters and source settings:** the host describes them as JSON (Header, Separator, Select,
  Text, CheckBox, TriState, Group, Sort; and the extension's preference screen). SwiftUI renders
  them generically. Settings are stored per extension by AndroidCompat's SharedPreferences.
- **Files:** APKs, converted jars and extension preferences live in `Application Support/Extensions/`,
  excluded from backup. Conversion happens once per install or update.
- **Supported lib versions:** 1.4 to 1.6 (Android's `ExtensionLoader.SUPPORTED_LIB_VERSIONS`).

### Risks to check in the trial

- **Speed:** an interpreter is many times slower than Android's ART. Most extension work is
  waiting on the network, but parsing big pages with Jsoup and the JVM's start-up could be slow.
  Measure both.
- **Size:** the JVM and class library add tens of MB. Strip unused modules with `jlink` where the
  runtime allows.
- **Memory:** the iPad mini is fine. Measure peak use while browsing an extension and reading.
- **Compatibility:** extensions that lean on Android APIs AndroidCompat doesn't cover, or on
  WebView/QuickJS. Note which ones fail; don't chase them all.
- **Free Apple ID:** nothing here needs an entitlement. Rebuilding with the runtime must still
  produce an .ipa SideStore can sign. Check this early.
- **Licences:** see [App Store route](#app-store-route).

## App Store route

The app is sideloaded for now, but Part 2 is built so it could go to the App Store later. Who
wrote the runtime doesn't matter to App Review; what the app does and what it ships with does.

### What App Review will look at

- **Downloaded code (guideline 2.5.2):** apps may not download or run code that adds or changes
  their features. Extensions are that, whoever's runtime runs them. Tachimanga is on the App
  Store with the same design, and seems to pass because it ships with nothing and the user
  brings the repos or extension files. Mihonka does the same:
  - **No repos or extensions built in, suggested, or linked** from the app or its App Store page.
    Adding a repo means typing or pasting its URL.
  - **Extensions are off until turned on** (Settings → Browse → Extensions). With them off,
    nothing about extensions shows in Browse.
  - **The app is complete without them:** Kavita, BookOrbit, KOReader sync, the reader and
    downloads all work with extensions off. That's the version to describe and screenshot.
  - Review is a judgement call, and an approved app can still be pulled later. The app must stay
    useful if extensions have to go.
- **Copyright (guideline 5.2):** apps tied to pirated content get rejected or removed. This is
  the usual way apps like this disappear. The listing, screenshots and review notes talk only
  about the user's own Kavita and BookOrbit servers. No source names, no manga titles that
  aren't public domain, no sample content.
- **Review notes:** give the reviewer a demo Kavita account (Kavita's public demo,
  `demo.kavitareader.com`, or a server set up for review) so they can use the app without
  setting anything up.

### Licences

| Part | Licence | On the App Store |
|---|---|---|
| Mihonka iOS (our code) | Apache-2.0, like Mihon | Fine |
| OpenJ9 (the JVM) | EPL-2.0 / Apache-2.0 | Fine. **Use only OpenJ9**, never OpenJDK's HotSpot, which is GPLv2 |
| OpenJDK class library | GPLv2 with the Classpath Exception | Linking is allowed by the exception. Ship its licence and `NOTICE` |
| Suwayomi `AndroidCompat`, oneechan-runtime and our fork | MPL-2.0 | Fine. The fork is public, so changes to MPL files are published as the licence requires |
| dex2jar | Apache-2.0 | Fine |
| Extensions | Their own licences | Not shipped; the user installs them |

Add an **Acknowledgements** screen like Android's (0.24.0, `mihonka/acknowledgements/AcknowledgementsScreen.kt`,
in the More tab where Mihon had Support Us): sections for what the app is built on, servers and
sync, libraries, icons and tools, each linking to its GitHub repository, then the full licence
texts. On iOS, list the Swift packages (GRDB, Nuke), the runtime's parts from the table above, and
the licences generated from the runtime's `NOTICE` at build time.

### The fork

- **`Grillza/mihonka-runtime`**, a GitHub fork of oneechan-runtime, public, MPL-2.0. It's added to
  this repo as a submodule at `ios/Vendor/mihonka-runtime`, pinned to a commit.
- `main` follows our needs. Upstream changes come in by merging, after the contract tests pass,
  never automatically.
- The **JSON protocol** between Swift and the host is ours from day one. Keep oneechan's
  "only add, never change" rule and its `contract/fixtures`, and run them in `check.sh`.
- Strip what Mihonka doesn't use (the desktop dev host, unused JDK modules via `jlink`) to keep
  the app smaller.
- A short `ios/Vendor/README.md` records the pinned commit, how to rebuild the JVM
  (`jvm-ios/package.sh`, about 40 minutes the first time) and how to take upstream changes.

### Before submitting

- Join the **Apple Developer Program** ($99 a year). A free Apple ID can't publish. With a paid
  account the 7-day re-signing goes away too, and TestFlight becomes available.
- Change the bundle id if `app.mihonka` is taken, and fill in the App Privacy details (no
  tracking; server addresses and credentials stay on the device, in the Keychain).
- Archive with Xcode's distribution signing instead of `build-ipa.sh`.
- Check the app size: the JVM and class library add tens of MB, which is fine but should be
  measured (milestone 16).
- Run through the review checklist above with extensions off, then on.

## Part H: Komga

Komga is a self-hosted comics server, like Kavita. **Android has it since 0.23.0**
(`app/src/main/java/mihonka/komga/`, with `KomgaSourceTest` and `KomgaSyncRulesTest`), so port
it like Kavita and BookOrbit: the Android code wins over this summary. Every request below was
checked against a Komga 1.29 server. Each Komga series is a series, and each book a chapter.

### Connection

- **Server address:** normalise it like Kavita's (scheme defaults to `http://`, trailing `/` and
  anything from `/api` cut), then add `/api`.
- **Sign-in:** an **API key** sent as the `X-API-Key` header on every request. Users create keys
  in Komga under their account settings (`/api/v2/users/me/api-keys`). Keep it in the Keychain.
  Komga also accepts basic auth, but an API key avoids keeping a password.
- **Connection check:** `GET /api/v2/users/me` shows "Connected to Komga as <email>", or the
  error. A 401 means a bad key ("Komga rejected the API key.").
- Image requests (covers, pages) need the header too, so load them through a Nuke pipeline that
  adds it rather than putting the key in the URL.

### Browse and chapters

| Purpose | Request |
|---|---|
| Libraries | `GET /api/v1/libraries` |
| Series (popular, search, filters) | `POST /api/v1/series/list?page=N&size=50&sort=…` with `{"condition": {"allOf": [{"deleted": {"operator": "isFalse"}}, …]}, "fullTextSearch": "…"}` (Komga 1.19+; `GET /api/v1/series` is deprecated). Library filter: `{"libraryId": {"operator": "is", "value": "<id>"}}`. Sort `metadata.titleSort`, `created`, `lastModified` or `booksCount`, `,asc`/`,desc`. The response is a Spring page: `content` and `last` |
| Latest | the same, sorted `lastModified,desc` |
| Unread | the same, plus `{"anyOf": [{"readStatus": {"operator": "is", "value": "UNREAD"}}, {"readStatus": {"operator": "is", "value": "IN_PROGRESS"}}]}`, sorted `lastModified,desc` |
| Series details | `GET /api/v1/series/{id}`: title, summary, authors, genres, tags, status |
| Books (chapters) | `POST /api/v1/books/list?unpaged=true&sort=metadata.numberSort,asc` with `{"condition": {"allOf": [{"seriesId": {"operator": "is", "value": "<id>"}}, {"deleted": {"operator": "isFalse"}}]}}` |
| Page list | `GET /api/v1/books/{id}/pages` (numbers start at **1**) |
| Page image | `GET /api/v1/books/{id}/pages/{n}` |
| Cover | `GET /api/v1/series/{id}/thumbnail` |

- **Which books:** `media.status` READY with pages, and `media.mediaProfile` DIVINA (comic
  archives) or PDF. EPUBs are left out unless `media.epubDivinaCompatible`, as Kavita and
  BookOrbit leave out ebooks.
- **Names and numbers:** "#N - Title" from `metadata.number` and `metadata.title` (Komga defaults
  the title to the file name, and the number to the book's position), or just "#N" when the title
  is the number, or the title alone when there's no number. The chapter number is
  `metadata.numberSort`. The memo keeps `fileName` (from `url`, folder removed; accounts that
  aren't admins only get the name) for the file-name sort.
- **Order:** by `metadata.numberSort`, which is Komga's own reading order.

### Progress sync

Komga stores progress per book as `readProgress: {page, completed, …}`, with `page` starting at
1. The same rules as Kavita and BookOrbit apply: whichever side has read further wins, hand marks
always go through, and an offline queue keeps what couldn't be sent.

| Action | Request |
|---|---|
| Read up to a page | `PATCH /api/v1/books/{id}/read-progress` with `{"page": lastPageRead + 1}`. Komga marks the book completed when the page is the last one, and refuses pages outside `1…pagesCount` |
| Mark read (hand mark) | the same with `{"completed": true}` |
| Mark unread (hand mark) | `DELETE /api/v1/books/{id}/read-progress` |
| Pull | the books list carries each book's `readProgress` and `media.pagesCount`, so one request covers a series |

- **Mapping:** Komga's `page` (1-based, the page reached) is compared with `lastPageRead + 1`. A
  book with no `readProgress` is page 0. `completed` is read.
- **Several books at once:** Komga has no "mark many" call per book list, but has
  `POST /api/v1/series/{id}/read-progress` (whole series read) and `DELETE` on the same path
  (whole series unread). Use them for "mark all"; otherwise send one request per book, queued
  first like the others.
- **Unread mark then reading:** same as Kavita: the mark keeps its priority until it's delivered.

### Tests

Stub-server tests like Kavita's: sign-in with the `X-API-Key` header and the 401 message,
browse/search/latest/unread bodies, book filtering and naming, page URLs (1-based), and the sync
rules (push further, never undo further progress elsewhere, hand marks, the series-wide calls,
the queue surviving failures). A live test against a Komga server if one is given
(`TEST_RUNNER_KOMGA_LIVE_URL`, `TEST_RUNNER_KOMGA_LIVE_KEY`), skipped otherwise. The user
doesn't run Komga, so set one up in Docker for the live test (`gotson/komga`, a few public-domain
CBZs).

## Milestones

Same rules as part 1: no warnings, tests pass, run on the simulator and (where relevant) the
iPad, and commit at the end of each.

10. **Download indicator** (Part A): bar, pause/resume, `BGContinuedProcessingTask`,
    notifications. Accept: start "Download unread" on a series, lock the iPad, see progress, and
    cancel it to pause; the bar shows the same on unlock.
11. **Source abstraction and data model v5** (Part B, plus the Swift `Source` protocol). Kavita
    moves onto both with no change in behaviour. Accept: an existing install upgrades with its
    library, progress, queue and downloads intact.
12. **Sync settings screen and BookOrbit** (Parts C and D minus KOReader). Accept: BookOrbit
    browse, read and two-way sync with the Android app on the same server; the Sync screen
    matches Android's.
13. **KOReader sync** (Part D). Accept: in KOReader mode, a page read on iOS shows up in KOReader
    or BookOrbit's KOReader progress for the same file, and back again.
14. **Komga** (Part H): source, settings group, progress sync, Unread listing and file names.
    Accept: against a Komga server in Docker, browse and read a series; progress set in Komga's
    web reader shows up in the app and the other way round; marking unread in the app clears it
    in Komga.
15. **Settings mirror and recent Android features** (Parts E and F). Accept: the JoJo series
    sorts by file name on iOS as on Android, and Unread lists unfinished series on both servers.
16. **Extension runtime trial (go/no-go):**
    - Fork oneechan-runtime to `Grillza/mihonka-runtime` and add the fork as a submodule at
      `ios/Vendor/mihonka-runtime`, pinned to a commit ([The fork](#the-fork)). Build its
      `jvm-ios` (OpenJ9), link it, and wrap it in `ExtensionHost`.
    - Install one simple extension and one Cloudflare-protected one from a repo. Browse page 1
      and open a chapter's page list.
    - **Measure:** JVM cold start, first-page time, peak memory and the .ipa size.
    - **Go** if both work on the iPad, start-up is under ~5 s and the .ipa still signs with
      SideStore. **No-go:** record why, and either rebuild the host in the fork (same protocol)
      or stop at Kavita and BookOrbit.
17. **Extensions in the app:** repos, extension list, install/update/uninstall, trust, content
    warnings, and sources under Browse with filters and settings.
18. **Reading and downloading from extensions:** library, series screen, reader, downloads and
    the download indicator, plus Cloudflare and WebView handling.
19. **Polish:** empty and error states for extension failures ("This extension needs an Android
    feature Mihonka for iOS doesn't have"), accessibility, the README in PLAN.md updated for
    sources and extensions, the extensions switch (off by default), and the Acknowledgements
    screen ([App Store route](#app-store-route)).
20. **App Store readiness** (only when the paid account exists): bundle id, privacy details,
    distribution signing, review notes with a demo account, a TestFlight build, and the
    checklist under [Before submitting](#before-submitting).

## Open questions

1. Is losing extension sources acceptable if the trial (milestone 16) fails, or is rebuilding
   the host in the fork worth weeks of work?
2. Should extension series take part in KOReader mode at all? Android says no, since there's no
   file to match. This plan follows Android.
3. Pause semantics for the system Live Activity: the plan treats cancel as pause. Should it
   cancel the queue instead, as Android's Cancel does?
4. App Store name: "Mihonka" or something without Mihon in it? Mihon is Apache-2.0, so the code
   is fine, but a name close to Mihon's may draw attention in review.

## Progress log

*(Add an entry per milestone, as in part 1.)*
