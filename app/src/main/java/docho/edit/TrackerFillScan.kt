package docho.edit

import android.content.Context
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import logcat.LogPriority
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.manga.model.Manga
import tachiyomi.domain.manga.repository.MangaRepository
import tachiyomi.domain.track.interactor.GetTracks
import java.io.File
import kotlin.time.Duration.Companion.seconds

/**
 * Scans the library against the trackers signed in on this device, and keeps what it finds as a
 * list to review, in a file as a scan can take hours. Nothing changes on a series until it's
 * resolved here, which saves ordinary edits ([SeriesEdits]) that reach everything through Dōchō Sync.
 */
@Inject
@SingleIn(AppScope::class)
class TrackerFillScan(
    private val context: Context,
    private val fill: TrackerFill,
    private val memory: TrackerFillMemory,
    private val seriesEdits: SeriesEdits,
    private val mangaRepository: MangaRepository,
    private val getTracks: GetTracks,
) {

    data class Progress(
        val running: Boolean = false,
        val total: Int = 0,
        val done: Int = 0,
        val unchanged: Int = 0,
        val failed: Int = 0,
        val finished: Boolean = false,
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val file get() = File(context.filesDir, "tracker_fill_items.json")
    private val lock = Mutex()

    private val _progress = MutableStateFlow(Progress())
    val progress: StateFlow<Progress> = _progress.asStateFlow()

    private val _items = MutableStateFlow<List<FillItem>?>(null)

    /** The review list; null until [load]. */
    val items: StateFlow<List<FillItem>?> = _items.asStateFlow()

    fun canScan() = fill.canFill()

    /** Reads the list, bringing it up to date with what changed since, here or on another device. */
    suspend fun load() = withContext(Dispatchers.IO) {
        lock.withLock {
            val stored = _items.value ?: read()
            val pruned = stored.mapNotNull { item ->
                val manga = mangaRepository.getMangaByUrlAndSourceId(item.url, item.sourceId) ?: return@mapNotNull null
                val remembered = memory.get(item.key)
                TrackerFillRules.prune(item, manga.toCurrent(), remembered?.status, remembered?.ignored.orEmpty())
            }
            store(pruned)
        }
    }

    private fun read(): List<FillItem> = try {
        if (file.exists()) json.decodeFromString(file.readText()) else emptyList()
    } catch (e: Exception) {
        logcat(LogPriority.WARN, e) { "Couldn't read the tracker fill's list" }
        emptyList()
    }

    private fun store(items: List<FillItem>) {
        val sorted = items.sortedWith(compareBy({ it.problem == FillProblem.READY }, { it.title.lowercase() }))
        _items.value = sorted
        file.writeText(json.encodeToString(sorted))
    }

    private suspend fun change(transform: (List<FillItem>) -> List<FillItem>) = lock.withLock {
        store(transform(_items.value ?: read()))
    }

    /** Runs a scan, which replaces the list. [compareAll] also looks up series with no empty fields. */
    suspend fun run(compareAll: Boolean, forgetChoices: Boolean, onProgress: suspend (Progress) -> Unit) {
        if (forgetChoices) memory.forgetChoices()
        change { emptyList() }
        _progress.value = Progress(running = true)
        try {
            val series = mangaRepository.getFavorites().filter { manga ->
                val remembered = memory.get(TrackerFillRules.run { "${manga.source}|${manga.url}" })
                manga.source != SERIES_GROUPS_SOURCE &&
                    TrackerFillRules.SKIPPED !in remembered?.ignored.orEmpty() &&
                    (compareAll || manga.toCurrent().hasEmptyFields || remembered?.status == manga.status)
            }
            _progress.update { it.copy(total = series.size) }
            onProgress(_progress.value)
            for (manga in series) {
                scan(manga, compareAll)
                _progress.update { it.copy(done = it.done + 1) }
                onProgress(_progress.value)
            }
        } finally {
            _progress.update { it.copy(running = false, finished = true) }
        }
    }

    private suspend fun scan(manga: Manga, compareAll: Boolean) {
        val key = "${manga.source}|${manga.url}"
        val current = manga.toCurrent()
        val lookup = lookUp(manga, current, compareAll)
        if (lookup.failed > 0) _progress.update { it.copy(failed = it.failed + lookup.failed) }
        val remembered = memory.get(key)
        val item = when {
            // Nothing is missing, so not knowing which series it is doesn't matter
            lookup.matches.isEmpty() && !current.hasEmptyFields -> null
            lookup.several.isNotEmpty() -> FillItem(
                manga.source,
                manga.url,
                manga.title,
                FillProblem.SEVERAL_MATCHES,
                candidates = lookup.several + lookup.matches,
            )
            lookup.matches.isNotEmpty() -> {
                val changes = TrackerFillRules.review(current, lookup.matches, remembered?.status, remembered?.ignored.orEmpty())
                val problem = TrackerFillRules.problemOf(changes)
                if (problem == null) _progress.update { it.copy(unchanged = it.unchanged + 1) }
                problem?.let { FillItem(manga.source, manga.url, manga.title, it, changes) }
            }
            // A tracker that couldn't be reached says nothing about whether there's a match
            lookup.failed > 0 && lookup.suggestions.isEmpty() -> null
            else -> FillItem(manga.source, manga.url, manga.title, FillProblem.NO_MATCH, candidates = lookup.suggestions)
        }
        if (item != null) change { it + item }
    }

    private class Lookup(
        val matches: List<TrackerFill.Match>,
        val failed: Int,
        val several: List<TrackerFill.Match> = emptyList(),
        val suggestions: List<TrackerFill.Match> = emptyList(),
    )

    /** The entries a series is linked to; else exact title matches, until nothing's missing. */
    private suspend fun lookUp(manga: Manga, current: FillCurrent, compareAll: Boolean): Lookup {
        val tracks = getTracks.await(manga.id)
        if (tracks.isNotEmpty()) {
            val linked = fill.linked(manga)
            delay(PAUSE * tracks.size)
            if (linked.isNotEmpty()) return Lookup(linked, 0)
        }
        val matches = mutableListOf<TrackerFill.Match>()
        val suggestions = mutableListOf<TrackerFill.Match>()
        var failed = 0
        val wanted = TrackerFillRules.comparable(manga.title)
        for (tracker in fill.trackersInScanOrder()) {
            try {
                val results = tracker.search(manga.title)
                val exact = if (wanted.isEmpty()) {
                    emptyList()
                } else {
                    results.filter { TrackerFillRules.comparable(it.title) == wanted }
                }
                when {
                    exact.size == 1 -> matches += fill.withDetails(tracker, exact.single())
                    exact.size > 1 -> return Lookup(
                        matches,
                        failed,
                        several = exact.take(RESULTS_PER_TRACKER).map { fill.withDetails(tracker, it) },
                    )
                    else -> suggestions += results.take(SUGGESTIONS_PER_TRACKER).map { fill.withoutDetails(tracker, it) }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                logcat(LogPriority.WARN, e) { "Couldn't search for ${manga.title} on ${tracker.name}" }
                failed++
            }
            delay(PAUSE)
            if (isComplete(current, matches, compareAll)) break
        }
        return Lookup(matches, failed, suggestions = suggestions)
    }

    private fun isComplete(current: FillCurrent, matches: List<TrackerFill.Match>, compareAll: Boolean) =
        ((!compareAll && !TrackerFillRules.isEmptyName(current.author)) || matches.any { it.author.isNotBlank() }) &&
            ((!compareAll && !TrackerFillRules.isEmptyName(current.artist)) || matches.any { it.artist.isNotBlank() }) &&
            (current.description.isNotBlank() || matches.any { it.description.isNotBlank() }) &&
            matches.any { it.status != TrackerFillRules.UNKNOWN }

    // The review list

    private fun Manga.toCurrent() = FillCurrent(author.orEmpty(), artist.orEmpty(), description.orEmpty(), status)

    private suspend fun itemFor(key: String): FillItem {
        load()
        return _items.value.orEmpty().firstOrNull { it.key == key }
            ?: throw IllegalArgumentException("That series isn't on the list any more")
    }

    /**
     * Settles an item: each field takes its choice, or keeps what it has if there's none ([choices]
     * by field). Options not taken are remembered, so they aren't asked about again.
     */
    suspend fun resolve(key: String, choices: Map<String, String?>) {
        val item = itemFor(key)
        val manga = mangaRepository.getMangaByUrlAndSourceId(item.url, item.sourceId)
            ?: throw IllegalArgumentException("That series isn't on the list any more")
        var details = seriesEdits.get(item.sourceId, item.url) ?: SeriesEdits.Details()
        val ignore = mutableMapOf<String, List<String>>()
        for (change in item.changes) {
            val value = choices[change.field]
            if (value != null) {
                details = when (change.field) {
                    TrackerFillRules.AUTHOR -> details.copy(author = value)
                    TrackerFillRules.ARTIST -> details.copy(artist = value)
                    TrackerFillRules.DESCRIPTION -> details.copy(description = value)
                    else -> details.copy(status = value.toLong())
                }
            }
            ignore[change.field] = if (change.field == TrackerFillRules.DESCRIPTION) {
                if (value == null) listOf(TrackerFillRules.KEPT) else emptyList()
            } else {
                change.options.map { it.value }.filter { it != value }.map { TrackerFillRules.optionKey(change.field, it) }
            }
        }
        if (item.picked) ignore[TrackerFillRules.SKIPPED] = listOf(TrackerFillRules.KEPT)
        if (choices.values.any { it != null }) seriesEdits.edit(manga, details)
        memory.remember(key, choices[TrackerFillRules.STATUS]?.toLongOrNull(), ignore)
        change { list -> list.filterNot { it.key == key } }
    }

    /** Takes an item off the list, keeping what the series has; one with no match isn't scanned again. */
    suspend fun skip(key: String) {
        val item = itemFor(key)
        if (item.changes.isEmpty()) {
            memory.remember(key, null, mapOf(TrackerFillRules.SKIPPED to listOf(TrackerFillRules.KEPT)))
            change { list -> list.filterNot { it.key == key } }
        } else {
            resolve(key, emptyMap())
        }
    }

    /** Applies everything with nothing to decide. Returns how many series that was, and how many failed. */
    suspend fun applyReady(): Pair<Int, Int> {
        load()
        var applied = 0
        var failed = 0
        for (item in _items.value.orEmpty().filter { it.problem == FillProblem.READY }) {
            try {
                resolve(item.key, item.changes.associate { it.field to it.options.first().value })
                applied++
            } catch (e: Exception) {
                logcat(LogPriority.WARN, e) { "Couldn't save details for ${item.title}" }
                failed++
            }
        }
        return applied to failed
    }

    /** Takes every conflict off the list, keeping what the series have. */
    suspend fun dismissConflicts() {
        load()
        _items.value.orEmpty().filter { it.problem != FillProblem.READY }.forEach { skip(it.key) }
    }

    /** Takes one of an item's candidates as the series. */
    suspend fun pick(key: String, index: Int) {
        val item = itemFor(key)
        val candidate = item.candidates.getOrNull(index) ?: return
        val match = if (candidate.complete) candidate else fill.completed(candidate)
        val manga = mangaRepository.getMangaByUrlAndSourceId(item.url, item.sourceId) ?: return
        val changes = TrackerFillRules.review(manga.toCurrent(), listOf(match), memory.get(key)?.status)
        val problem = TrackerFillRules.problemOf(changes)
        if (problem == null) memory.remember(key, null, mapOf(TrackerFillRules.SKIPPED to listOf(TrackerFillRules.KEPT)))
        change { list ->
            list.mapNotNull { other ->
                when {
                    other.key != key -> other
                    problem == null -> null
                    else -> other.copy(problem = problem, changes = changes, candidates = emptyList(), picked = true)
                }
            }
        }
    }

    /** Replaces an item's candidates with search results for [query]. */
    suspend fun searchFor(key: String, query: String) {
        val found = fill.search(query.trim())
        change { list ->
            list.map { other ->
                if (other.key != key) {
                    other
                } else {
                    other.copy(
                        problem = if (found.isEmpty()) FillProblem.NO_MATCH else FillProblem.SEVERAL_MATCHES,
                        changes = emptyList(),
                        candidates = found,
                    )
                }
            }
        }
    }

    private companion object {
        /** Trackers are asked one at a time with a pause between, not to run into their rate limits. */
        val PAUSE = 2.seconds
        const val RESULTS_PER_TRACKER = 5
        const val SUGGESTIONS_PER_TRACKER = 3

        /** Dōchō Server's Series Groups: not a series on any tracker. */
        const val SERIES_GROUPS_SOURCE = 0x0D0C000000000000L
    }
}
