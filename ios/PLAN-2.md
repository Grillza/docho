# Mihonka for iOS: plan, part 2

Version 1 ([PLAN.md](PLAN.md), milestones 1–9) is finished and runs on the iPad. Part 2 brings
the iOS app up to the Android app:

1. **A download indicator** while chapters download, like Android's download notification.
2. **The same sync settings and options as Android:** Kavita, BookOrbit and KOReader sync, and
   the "Sync progress with" choice.
3. **Android's settings mirrored** where they make sense on iOS.
4. **Tachiyomi/Mihon extensions**, run the way Tachimanga runs them: the Android extension APK,
   converted on the device and run in a JVM embedded in the app.

Like part 1, this file is the hand-off point for a session on the Mac. Read PLAN.md's
[working notes](PLAN.md#working-notes-for-the-session-doing-the-work) first; they still apply
(`ios/scripts/check.sh`, iPad-first testing, small commits on `ios`, Android is the reference).
Work through the [milestones](#milestones) in order and keep the progress log at the end current.

## Decisions

These replace part 1's where they disagree. Part 1's "Kavita only, no extension runtime" and
"code sharing: none" are superseded by the first three rows.

| Decision | Choice | Why |
|---|---|---|
| Sources | **Kavita, BookOrbit, and installed extensions** | Matches Android |
| Built-in sources | **Swift**, as Kavita is now. BookOrbit is ported like Kavita was | Kavita's Swift port works and is tested, and its sync queue lives in GRDB. Built-ins must work offline and start instantly, which a JVM doesn't |
| Extensions | **An embedded JVM runs the unmodified Android extension APKs** (dex2jar on the device, then a class loader), with Suwayomi's Android compatibility layer | It's how Tachimanga does it ([research](#how-tachimanga-runs-extensions)), and the only way to use the existing extension repos without rewriting extensions |
| Extension runtime origin | **Try [oneechan-runtime](https://github.com/leros1337/oneechan-runtime) first**, pinned to a commit, behind our own Swift protocol. If the trial (milestone 15) fails, build our own host from its `jvm-ios` approach and Suwayomi's `AndroidCompat` | It already does the hard parts for a Swift app, but it's a week old with one author, so it mustn't leak into the rest of the app |
| App ↔ JVM | **JSON calls over JNI** through a small C shim, with **page images and HTTP bodies as raw bytes**. All networking goes through **URLSession** | Keeps the Swift side in charge of networking, cookies and Cloudflare (WKWebView), as Tachimanga and oneechan both do |
| Sync choice | **"Sync progress with: Default (each series with its source) or KOReader"**, app-wide, as on Android | Same behaviour on both apps against the same servers |
| Download indicator | **An in-app download bar, plus the system's progress Live Activity through `BGContinuedProcessingTask` on iOS/iPadOS 26+.** No widget extension | iPadOS 26 shows a cancellable progress Live Activity for user-started tasks with no extra target. A widget extension would add an app ID, which counts against a free Apple ID's limits |
| Source ids | **The Android ids:** Kavita `0x4B415649544131` ("KAVITA1"), BookOrbit `0x424F4F4B4F5242` ("BOOKORB"). Extensions use the id their `Source` reports | Keeps the door open for backups shared between the apps |
| Distribution | Unchanged: sideloaded with a free Apple ID | The JVM is an interpreter, so it needs no JIT entitlement |

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
| **Reading progress** | **Sync progress with:** "Default - Sync with source" / "KOReader". The KOReader summary: "every series syncs with the KOReader sync server below instead of its source. Works for Kavita, BookOrbit and downloaded archives; online sources have no files to match, so they don't sync." |
| **Kavita** | Server address ("e.g. https://kavita.example.com"), API key ("Saved (hidden)"; "Copy it from Kavita: your user settings, under API Key / OPDS"), Connection ("Connected to Kavita 0.8.x as name", "Couldn't connect: …", tap to check), **Sync reading progress**, **Sync library now** ("Synced N Kavita series"), Browse Kavita, and iOS's "Waiting to be sent: N / Send Now" |
| **BookOrbit** | Server address ("The address you open BookOrbit at, e.g. http://bookorbit.lan:3010"), username and password ("The account you sign in to BookOrbit with"), Connection, Sync reading progress, Sync library now, Browse BookOrbit, waiting to be sent |
| **KOReader sync** | Server address ("The address KOReader uses, e.g. http://bookorbit.lan:3010/api/v1/koreader"), username, password ("In BookOrbit, create it under Settings → KOReader"), Connection ("Signed in as …"), Sync library now ("Only runs while sync is set to KOReader"), and the matching note |

**KOReader sync** (port of `mihonka/koreader/` and `sync/ProgressSync.kt`):

- **Routing:** one `ProgressSync` sends page changes, read marks and reconciliation to whichever
  sync applies to a series. In KOReader mode the sources' own syncs stand down.
- **Matching:** KOReader matches books by a **partial MD5 of the file** (`KoreaderHash.kt`). The
  hash comes from a document provider per source:
  - **Kavita:** its stored `koreaderHash` for single-file chapters, or one computed from ranged
    requests to the download endpoint.
  - **BookOrbit:** its stored file hash.
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
    title, which BookOrbit takes from the file name. Otherwise it falls back to the chapter name.
    This is what keeps a series like JoJo, whose volume numbers restart per part, in order.
  - Ascending/descending, and filters for unread, downloaded and bookmarked.
  - Part 1 shows Kavita reading order only, which stays the default ("by source").
- **Unread listing in Browse:** next to Popular and Latest, Kavita and BookOrbit offer
  **Unread**: series not finished, most recently added first.
  - **Kavita:** filter `{comparison: 9 (NOT_EQUAL), field: 20 (READ_PROGRESS), value: "100"}`,
    sort LAST_CHAPTER_ADDED (4) descending. That's Kavita's own "unread" filter.
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
- **Licences:** OpenJDK's class library is GPLv2 with the Classpath Exception, OpenJ9 is
  EPL-2.0/Apache-2.0, and Suwayomi and oneechan are MPL-2.0. Fine for a personal sideloaded app;
  keep their `NOTICE`/licence files in the bundle.

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
14. **Settings mirror and recent Android features** (Parts E and F). Accept: the JoJo series
    sorts by file name on iOS as on Android, and Unread lists unfinished series on both servers.
15. **Extension runtime trial (go/no-go):**
    - Vendor oneechan-runtime at a pinned commit as a git submodule (`ios/Vendor/oneechan-runtime`).
      Build its `jvm-ios`, link it, and wrap it in `ExtensionHost`.
    - Install one simple extension and one Cloudflare-protected one from a repo. Browse page 1
      and open a chapter's page list.
    - **Measure:** JVM cold start, first-page time, peak memory and the .ipa size.
    - **Go** if both work on the iPad, start-up is under ~5 s and the .ipa still signs with
      SideStore. **No-go:** record why, and either build our own host (same protocol) or stop at
      Kavita and BookOrbit.
16. **Extensions in the app:** repos, extension list, install/update/uninstall, trust, content
    warnings, and sources under Browse with filters and settings.
17. **Reading and downloading from extensions:** library, series screen, reader, downloads and
    the download indicator, plus Cloudflare and WebView handling.
18. **Polish:** empty and error states for extension failures ("This extension needs an Android
    feature Mihonka for iOS doesn't have"), accessibility, and the README in PLAN.md updated for
    sources and extensions.

## Open questions

1. Is losing extension sources acceptable if the trial (milestone 15) fails, or is building our
   own runtime worth weeks of work?
2. Should extension series take part in KOReader mode at all? Android says no, since there's no
   file to match. This plan follows Android.
3. Pause semantics for the system Live Activity: the plan treats cancel as pause. Should it
   cancel the queue instead, as Android's Cancel does?

## Progress log

*(Add an entry per milestone, as in part 1.)*
