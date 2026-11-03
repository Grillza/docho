package docho.dochosync

import android.content.Context
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import docho.dochosync.SyncValues.bool
import docho.dochosync.SyncValues.long
import docho.dochosync.SyncValues.string
import docho.dochosync.SyncValues.strings
import docho.rename.ChapterRenames
import docho.rename.ChapterRenames.Companion.withKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import logcat.LogPriority
import mihon.domain.source.interactor.UpdateMangaFromRemote
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.category.model.Category
import tachiyomi.domain.category.model.NewCategory
import tachiyomi.domain.category.repository.CategoryRepository
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.model.ChapterUpdate
import tachiyomi.domain.chapter.repository.ChapterRepository
import tachiyomi.domain.history.model.HistoryUpdate
import tachiyomi.domain.history.repository.HistoryRepository
import tachiyomi.domain.manga.model.Manga
import tachiyomi.domain.manga.model.MangaUpdate
import tachiyomi.domain.manga.repository.MangaRepository
import tachiyomi.domain.source.service.SourceManager
import java.io.File
import kotlin.time.Clock
import kotlin.time.Instant

/**
 * Keeps the library, categories, chapter renames and types, read state and history the same on
 * every device signed in to a Dōchō Sync server.
 *
 * Each sync works out what changed here by comparing every record with how it was when last
 * synced, sends that, and applies what other devices changed. The server keeps the newest write
 * of each record. The very first sync of a device merges instead, so neither device's reading is
 * lost: a chapter read on either is read, the library and categories are joined.
 */
@Inject
@SingleIn(AppScope::class)
class DochoSync(
    private val context: Context,
    private val preferences: DochoSyncPreferences,
    private val api: DochoSyncApi,
    private val json: Json,
    private val mangaRepository: MangaRepository,
    private val chapterRepository: ChapterRepository,
    private val categoryRepository: CategoryRepository,
    private val historyRepository: HistoryRepository,
    private val chapterRenames: ChapterRenames,
    private val sourceManager: SourceManager,
    private val updateMangaFromRemote: UpdateMangaFromRemote,
    private val seriesEdits: docho.edit.SeriesEdits,
) {

    sealed interface Status {
        data object Idle : Status
        data object Syncing : Status
        data class Done(val sent: Int, val received: Int) : Status
        data class Failed(val reason: String) : Status
    }

    private val mutableStatus = MutableStateFlow<Status>(Status.Idle)
    val status: StateFlow<Status> = mutableStatus.asStateFlow()

    private val mutex = Mutex()

    /** What was last synced (canonical values by record id) and records waiting to be applied. */
    @Serializable
    private data class State(
        val synced: Map<String, String> = emptyMap(),
        val pending: Map<String, SyncRecord> = emptyMap(),
    )

    private val stateFile get() = File(context.filesDir, "docho-sync-state.json")

    fun isEnabled(): Boolean = preferences.isConfigured()

    suspend fun sync(): Status = withContext(Dispatchers.IO) {
        if (!preferences.isConfigured()) return@withContext Status.Idle
        mutex.withLock {
            mutableStatus.value = Status.Syncing
            val result = try {
                if (preferences.token.get().isBlank()) {
                    val signedIn = api.signIn()
                    if (signedIn is DochoSyncConnection.Failed) throw java.io.IOException(signedIn.reason)
                }
                runSync()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                logcat(LogPriority.WARN, e) { "Dōchō Sync failed" }
                Status.Failed(e.message ?: e.javaClass.simpleName)
            }
            if (result is Status.Done) {
                preferences.lastSyncAt.set(System.currentTimeMillis())
                preferences.lastError.delete()
            } else if (result is Status.Failed) {
                preferences.lastError.set(result.reason)
            }
            mutableStatus.value = result
            result
        }
    }

    /** Forgets what was synced, so the next sync is a first sync again; for a new server or account. */
    fun resetState() {
        stateFile.delete()
        preferences.since.delete()
    }

    private suspend fun runSync(): Status {
        var state = loadState()
        val me = preferences.deviceId()
        val firstSync = preferences.since.get() == 0L && state.synced.isEmpty()
        var since = preferences.since.get()
        val synced = state.synced.toMutableMap()
        val pending = state.pending.toMutableMap()
        val added = mutableListOf<Manga>()
        var received = 0

        // Records that couldn't be applied before, such as chapters that hadn't been fetched yet
        val appliedPending = applyAll(pending.values.toList(), firstSync = false, added = added)
        appliedPending.forEach { pending.remove(it) }

        if (firstSync) {
            // Take everything the server has first, and put it together with what's here
            val remote = mutableListOf<SyncRecord>()
            do {
                val page = api.sync(since, emptyList())
                remote += page.changes
                since = page.seq
            } while (page.more)
            val live = remote.filterNot { it.isDeleted }
            received += live.size
            val applied = applyAll(live, firstSync = true, added = added)
            live.forEach { record ->
                val id = SyncValues.id(record.kind, record.key)
                if (id !in applied) pending[id] = record
            }
            refreshAdded(added)
            applyAll(pending.values.toList(), firstSync = true, added = mutableListOf()).forEach { pending.remove(it) }
            // Records that came out the same here as on the server are already in sync
            val current = snapshot()
            for (record in live) {
                val id = SyncValues.id(record.kind, record.key)
                val here = current[id] ?: continue
                if (SyncValues.canonical(here.second) == SyncValues.canonical(record.value)) {
                    synced[id] = SyncValues.canonical(record.value)
                }
            }
            added.clear()
        }

        val current = snapshot()
        val changes = syncChanges(current, synced, pending.keys, System.currentTimeMillis())
        val remote = mutableListOf<SyncRecord>()
        var outgoing: List<SyncRecord> = changes
        do {
            // Large first syncs go in parts, so no request gets too big
            val batch = outgoing.take(BATCH)
            outgoing = outgoing.drop(BATCH)
            val page = api.sync(since, batch)
            remote += page.changes
            since = page.seq
        } while (page.more || outgoing.isNotEmpty())
        for (change in changes) {
            val id = SyncValues.id(change.kind, change.key)
            if (change.isDeleted) synced.remove(id) else synced[id] = SyncValues.canonical(change.value)
        }

        // What other devices changed. Ours come back too, where they won, and are skipped
        val theirs = remote.filter { it.device != me }
            .groupBy { SyncValues.id(it.kind, it.key) }
            .map { (_, records) -> records.last() }
        received += theirs.size
        val applied = applyAll(theirs, firstSync = false, added = added)
        refreshAdded(added)
        for (record in theirs) {
            val id = SyncValues.id(record.kind, record.key)
            if (id !in applied && !record.isDeleted) pending[id] = record else pending.remove(id)
        }
        applyAll(pending.values.toList(), firstSync = false, added = mutableListOf()).forEach { pending.remove(it) }
        val after = snapshot()
        for (record in theirs) {
            val id = SyncValues.id(record.kind, record.key)
            if (id in pending) continue
            val here = after[id]
            if (here == null) synced.remove(id) else synced[id] = SyncValues.canonical(here.second)
        }

        state = State(synced, pending)
        saveState(state)
        preferences.since.set(since)
        return Status.Done(sent = changes.size, received = received)
    }

    // Snapshot of this device

    private suspend fun snapshot(): Map<String, Pair<String, JsonElement>> {
        val records = HashMap<String, Pair<String, JsonElement>>()
        fun put(kind: String, key: String, value: JsonElement) {
            records[SyncValues.id(kind, key)] = kind to value
        }

        categoryRepository.getAll().filterNot { it.isSystemCategory }.forEach {
            put(SyncValues.CATEGORY, it.name, SyncValues.category())
        }
        val favorites = mangaRepository.getFavorites()
        val ids = favorites.map { it.id }
        val categories = if (ids.isEmpty()) emptyMap() else categoryRepository.getCategoriesByMangaIds(ids)
        val chapters = if (ids.isEmpty()) emptyMap() else chapterRepository.getChaptersByMangaIds(ids)
        val history = if (ids.isEmpty()) emptyMap() else historyRepository.getHistoryByMangaIds(ids)
        val mangaUrlByChapter = HashMap<String, String>()
        for (manga in favorites) {
            put(
                SyncValues.MANGA,
                SyncValues.key(manga.source, manga.url),
                SyncValues.manga(
                    title = manga.title,
                    categories = categories[manga.id].orEmpty().filterNot { it.isSystemCategory }.map { it.name },
                    addedAt = manga.favoriteAt?.toEpochMilliseconds() ?: 0,
                ),
            )
            val mangaChapters = chapters[manga.id].orEmpty()
            val byId = mangaChapters.associateBy { it.id }
            for (chapter in mangaChapters) {
                val key = SyncValues.key(manga.source, chapter.url)
                mangaUrlByChapter[key] = manga.url
                put(
                    SyncValues.CHAPTER,
                    key,
                    SyncValues.chapter(manga.url, chapter.read, chapter.bookmark, chapter.lastPageRead.toLong()),
                )
            }
            for (entry in history[manga.id].orEmpty()) {
                val chapter = byId[entry.chapterId] ?: continue
                val readAt = entry.readAt?.toEpochMilliseconds() ?: continue
                val key = SyncValues.key(manga.source, chapter.url)
                put(SyncValues.HISTORY, key, SyncValues.history(manga.url, readAt))
            }
        }
        for ((key, rename) in chapterRenames.renames.get()) {
            put(
                SyncValues.RENAME,
                key,
                SyncValues.rename(rename.name, rename.number, rename.original, rename.at, mangaUrlByChapter[key]),
            )
        }
        for ((key, kind) in chapterRenames.kinds.get()) {
            put(SyncValues.KIND, key, SyncValues.kind(kind, mangaUrlByChapter[key]))
        }
        for ((key, details) in seriesEdits.edits.get()) {
            if (!details.isEmpty) put(SyncValues.DETAILS, key, docho.edit.SeriesEdits.toJson(details))
        }
        return records
    }

    // Applying other devices' changes

    /** Applies [records], returning the ids of those applied (or with nothing to apply). */
    private suspend fun applyAll(
        records: List<SyncRecord>,
        firstSync: Boolean,
        added: MutableList<Manga>,
    ): Set<String> {
        if (records.isEmpty()) return emptySet()
        val applied = HashSet<String>()
        // Categories before series, series before their chapters
        val order = listOf(
            SyncValues.CATEGORY,
            SyncValues.MANGA,
            SyncValues.DETAILS,
            SyncValues.RENAME,
            SyncValues.KIND,
            SyncValues.CHAPTER,
            SyncValues.HISTORY,
        )
        for (record in records.sortedBy { order.indexOf(it.kind) }) {
            val done = try {
                apply(record, firstSync, added)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                logcat(LogPriority.WARN, e) { "Dōchō Sync couldn't apply ${record.kind} ${record.key}" }
                false
            }
            if (done) applied += SyncValues.id(record.kind, record.key)
        }
        return applied
    }

    private suspend fun apply(record: SyncRecord, firstSync: Boolean, added: MutableList<Manga>): Boolean {
        val value = record.value as? JsonObject
        return when (record.kind) {
            SyncValues.CATEGORY -> {
                if (value == null) {
                    if (!firstSync) findCategory(record.key)?.let { categoryRepository.delete(it.id) }
                } else {
                    ensureCategories(listOf(record.key))
                }
                true
            }
            SyncValues.MANGA -> applyManga(record.key, value, firstSync, added)
            SyncValues.CHAPTER -> {
                if (value == null) return true
                val chapter = findChapter(record.key, value.string("manga")) ?: return false
                val merged = if (firstSync) {
                    SyncValues.mergeChapter(
                        SyncValues.chapter("", chapter.read, chapter.bookmark, chapter.lastPageRead.toLong()),
                        value,
                    )
                } else {
                    value
                }
                chapterRepository.update(
                    ChapterUpdate(chapter.id) {
                        read = merged.bool("read")
                        bookmark = merged.bool("bookmark")
                        lastPageRead = (merged.long("page") ?: 0).toInt()
                    },
                )
                true
            }
            SyncValues.HISTORY -> {
                if (value == null) return true
                val chapter = findChapter(record.key, value.string("manga")) ?: return false
                val readAt = value.long("readAt") ?: return true
                val local = historyRepository.getHistoryByMangaId(chapter.mangaId)
                    .find { it.chapterId == chapter.id }?.readAt?.toEpochMilliseconds() ?: 0
                if (readAt > local) {
                    historyRepository.upsertHistory(HistoryUpdate(chapter.id, Instant.fromEpochMilliseconds(readAt), 0))
                }
                true
            }
            SyncValues.RENAME -> {
                val (sourceId, url) = SyncValues.parseKey(record.key) ?: return true
                if (value == null) {
                    chapterRenames.remove(sourceId, url)
                    return true
                }
                val name = value.string("name") ?: return true
                val number = value.string("number")?.toDoubleOrNull() ?: -1.0
                chapterRenames.put(
                    sourceId,
                    url,
                    url,
                    ChapterRenames.Rename(name, number, value.string("original"), value.long("at") ?: 0),
                )
                findChapter(record.key, value.string("manga"))?.let {
                    chapterRepository.rename(it.id, it.url, name, number, it.memo)
                }
                true
            }
            SyncValues.KIND -> {
                val (sourceId, url) = SyncValues.parseKey(record.key) ?: return true
                val kind = value?.string("kind")
                if (kind == null) {
                    chapterRenames.removeKind(sourceId, url)
                    return true
                }
                chapterRenames.putKind(sourceId, url, kind)
                findChapter(record.key, value.string("manga"))?.let {
                    chapterRepository.rename(it.id, it.url, it.name, it.chapterNumber, it.withKind(kind).memo)
                }
                true
            }
            SyncValues.DETAILS -> {
                val (sourceId, url) = SyncValues.parseKey(record.key) ?: return true
                // Kept even for series not here yet: they take the edits when they're added.
                val details = value?.let(docho.edit.SeriesEdits::fromJson)
                seriesEdits.put(sourceId, url, details)
                val manga = mangaRepository.getMangaByUrlAndSourceId(url, sourceId) ?: return true
                // Unlocked fields come back from the source on its next refresh.
                if (details != null) seriesEdits.write(manga, details)
                true
            }
            else -> true
        }
    }

    private suspend fun applyManga(
        key: String,
        value: JsonObject?,
        firstSync: Boolean,
        added: MutableList<Manga>,
    ): Boolean {
        val (sourceId, url) = SyncValues.parseKey(key) ?: return true
        val existing = mangaRepository.getMangaByUrlAndSourceId(url, sourceId)
        if (value == null) {
            if (!firstSync && existing != null && existing.favorite) {
                mangaRepository.update(MangaUpdate(existing.id) { favoriteAt = null })
            }
            return true
        }
        val addedAt = value.long("addedAt")?.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds)
            ?: Clock.System.now()
        val manga = existing ?: mangaRepository.insertNetworkManga(
            listOf(
                Manga.create().copy(
                    source = sourceId,
                    url = url,
                    title = value.string("title").orEmpty(),
                    favoriteAt = addedAt,
                ),
            ),
        ).first().also { added += it }
        if (!manga.favorite) {
            mangaRepository.update(MangaUpdate(manga.id) { favoriteAt = addedAt })
            if (existing != null && chapterRepository.getChapterByMangaId(manga.id).isEmpty()) added += manga
        }
        var names = value.strings("categories")
        if (firstSync) {
            val here = categoryRepository.getCategoriesByMangaId(manga.id).filterNot { it.isSystemCategory }
            names = (names + here.map { it.name })
                .distinct()
        }
        val categories = ensureCategories(names)
        mangaRepository.setMangaCategories(manga.id, categories.map { it.id })
        return true
    }

    /** Fetches the details and chapters of series that came from another device. */
    private suspend fun refreshAdded(added: List<Manga>) {
        for (manga in added.distinctBy { it.id }) {
            val source = sourceManager.get(manga.source) ?: continue
            val fresh = mangaRepository.getMangaById(manga.id)
            updateMangaFromRemote(source, fresh, fetchDetails = true, fetchChapters = true).onFailure {
                logcat(LogPriority.WARN, it) { "Dōchō Sync couldn't fetch ${manga.title}" }
            }
        }
    }

    private suspend fun ensureCategories(names: List<String>): List<Category> {
        if (names.isEmpty()) return emptyList()
        var all = categoryRepository.getAll()
        val missing = names.filter { name -> all.none { it.name == name } }
        if (missing.isNotEmpty()) {
            missing.forEach { categoryRepository.insert(NewCategory(it, 0)) }
            all = categoryRepository.getAll()
        }
        return names.mapNotNull { name -> all.find { it.name == name } }
    }

    private suspend fun findCategory(name: String): Category? =
        categoryRepository.getAll().find { it.name == name && !it.isSystemCategory }

    private suspend fun findChapter(key: String, mangaUrl: String?): Chapter? {
        val (sourceId, url) = SyncValues.parseKey(key) ?: return null
        val manga = mangaRepository.getMangaByUrlAndSourceId(mangaUrl ?: return null, sourceId) ?: return null
        return chapterRepository.getChapterByUrlAndMangaId(url, manga.id)
    }

    private fun loadState(): State = runCatching {
        json.decodeFromString(State.serializer(), stateFile.readText())
    }.getOrDefault(State())

    private fun saveState(state: State) {
        val temp = File(stateFile.path + ".tmp")
        temp.writeText(json.encodeToString(State.serializer(), state))
        temp.renameTo(stateFile)
    }

    private companion object {
        const val BATCH = 5_000
    }
}
