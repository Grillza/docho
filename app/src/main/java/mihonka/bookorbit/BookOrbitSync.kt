package mihonka.bookorbit

import android.content.Context
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import logcat.LogPriority
import mihonka.sync.ProgressSyncPreferences
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.chapter.interactor.GetChaptersByMangaId
import tachiyomi.domain.chapter.interactor.UpdateChapter
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.model.ChapterUpdate
import tachiyomi.domain.manga.interactor.GetFavorites
import tachiyomi.domain.manga.model.Manga
import java.util.concurrent.ConcurrentHashMap

/**
 * Two-way, page-level reading progress sync with BookOrbit, for series read from the BookOrbit
 * source. It follows the same rules as [mihonka.kavita.KavitaSync]: the side that has read
 * further wins, except for chapters marked read or unread by hand, and whatever can't be sent is
 * queued for [BookOrbitSyncWorker].
 *
 * Positions are BookOrbit's: a 1-based page number and a percentage from 0 to 100, the same as
 * its own comic reader writes, so a page reached here opens there too. A series' books carry
 * their read status and percentage, so reconciling one only asks for the exact page of books
 * that are part read.
 */
@Inject
@SingleIn(AppScope::class)
class BookOrbitSync(
    private val context: Context,
    private val preferences: BookOrbitPreferences,
    private val syncPreferences: ProgressSyncPreferences,
    private val api: BookOrbitApi,
    private val source: BookOrbitSource,
    private val json: Json,
    private val getChaptersByMangaId: GetChaptersByMangaId,
    private val updateChapter: UpdateChapter,
    private val getFavorites: GetFavorites,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pendingMutex = Mutex()
    private val debounceJobs = ConcurrentHashMap<Int, Job>()

    /** Page counts by file id, learned from the reader or asked for when a page has to be sent. */
    private val pageCounts = ConcurrentHashMap<Int, Int>()

    fun isEnabled(): Boolean = preferences.syncProgress.get() && preferences.isConfigured()

    /** While progress goes to a KOReader server, [mihonka.koreader.KoreaderSync] does it instead. */
    fun isEnabledFor(manga: Manga): Boolean =
        manga.source == BookOrbitSource.ID && isEnabled() && !syncPreferences.usesKoreader()

    /** Called by the reader on every page change; the latest page per chapter is sent after a short pause. */
    fun onPageChanged(manga: Manga, chapterUrl: String, pageIndex: Int, pageCount: Int, chapterRead: Boolean) {
        if (!isEnabledFor(manga) || pageCount <= 0) return
        val bookId = BookOrbitSource.bookIdOrNull(chapterUrl) ?: return
        val fileId = BookOrbitSource.fileIdOrNull(chapterUrl) ?: return
        pageCounts[fileId] = pageCount

        debounceJobs.remove(fileId)?.cancel()
        debounceJobs[fileId] = scope.launch {
            delay(PAGE_DEBOUNCE_MILLIS)
            debounceJobs.remove(fileId)
            val progress = BookOrbitPendingProgress(
                seriesId = BookOrbitSource.seriesId(manga.url),
                bookId = bookId,
                fileId = fileId,
                page = if (chapterRead) pageCount else pageIndex + 1,
                pages = pageCount,
                read = chapterRead,
            )
            val entry = enqueue(listOf(progress), markedByUser = false).single()
            if (deliver(entry, serverPercentage = null) == Delivery.Failed) scheduleRetry()
        }
    }

    /** Pushes chapters that were marked read or unread from the chapter list, library or updates. */
    fun onReadStatusChanged(manga: Manga, chapters: List<Chapter>, read: Boolean) {
        if (!isEnabledFor(manga) || chapters.isEmpty()) return
        scope.launch {
            val seriesId = BookOrbitSource.seriesId(manga.url)
            val progress = chapters.mapNotNull { chapter ->
                val bookId = BookOrbitSource.bookIdOrNull(chapter.url) ?: return@mapNotNull null
                val fileId = BookOrbitSource.fileIdOrNull(chapter.url) ?: return@mapNotNull null
                debounceJobs.remove(fileId)?.cancel()
                val pages = pageCounts[fileId] ?: 0
                BookOrbitPendingProgress(seriesId, bookId, fileId, page = if (read) pages else 0, pages, read)
            }
            val entries = enqueue(progress, markedByUser = true)
            for (entry in entries) {
                if (deliver(entry, serverPercentage = null) == Delivery.Failed) break
            }
        }
    }

    /** Delivers this series' queued changes, then reconciles it with the server. */
    suspend fun syncManga(manga: Manga) {
        if (!isEnabledFor(manga)) return
        try {
            val seriesId = BookOrbitSource.seriesId(manga.url)
            val books = (source.progressCache.take(seriesId) ?: api.getSeriesBooks(seriesId).items)
                .mapNotNull { book -> book.comicFile?.let { it.id to book } }
                .toMap()

            // Queued changes first. Those that were sent, or still can't be, are left out of the
            // comparison below; those the server has overtaken were dropped and are pulled.
            val sent = mutableSetOf<Int>()
            for (entry in pendingFor(seriesId)) {
                val delivery = deliver(entry, serverPercentage = null)
                if (delivery == Delivery.Sent) sent += entry.fileId
                if (delivery == Delivery.Failed) break
            }
            val skip = sent + pendingFor(seriesId).map { it.fileId }

            val semaphore = Semaphore(PARALLEL_REQUESTS)
            val decisions = coroutineScope {
                getChaptersByMangaId.await(manga.id).map { local ->
                    async {
                        val fileId = BookOrbitSource.fileIdOrNull(local.url) ?: return@async null
                        val book = books[fileId] ?: return@async null
                        if (fileId in skip) return@async null
                        semaphore.withPermit { reconcile(seriesId, local, book, fileId) }
                    }
                }.awaitAll().filterNotNull()
            }

            val localUpdates = decisions.mapNotNull { it.localUpdate }
            val pushes = decisions.mapNotNull { it.push }
            if (localUpdates.isNotEmpty()) updateChapter.awaitAll(localUpdates)
            if (pushes.isNotEmpty()) {
                // Queued before sending, so nothing is lost if the connection drops halfway.
                val entries = enqueue(pushes.map { it.first }, markedByUser = false)
                for ((entry, push) in entries.zip(pushes)) {
                    if (deliver(entry, push.second) == Delivery.Failed) break
                }
            }

            if (localUpdates.isNotEmpty() || pushes.isNotEmpty()) {
                logcat(LogPriority.INFO) {
                    "BookOrbit: synced '${manga.title}': ${localUpdates.size} pulled, ${pushes.size} pushed"
                }
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "BookOrbit: progress sync failed for '${manga.title}'" }
        }
    }

    private class Decision(
        val localUpdate: ChapterUpdate? = null,
        /** The change to send, and the percentage the server has now. */
        val push: Pair<BookOrbitPendingProgress, Double>? = null,
    )

    private suspend fun reconcile(seriesId: Int, local: Chapter, book: BookOrbitBookDto, fileId: Int): Decision? {
        val serverRead = book.isRead
        val serverPercentage = if (serverRead) 100.0 else book.readingProgress ?: 0.0
        return when {
            local.read && !serverRead -> Decision(
                push =
                BookOrbitPendingProgress(
                    seriesId,
                    book.id,
                    fileId,
                    pageCounts[fileId] ?: 0,
                    pageCounts[fileId] ?: 0,
                    read = true,
                ) to
                    serverPercentage,
            )
            !local.read && serverRead -> Decision(localUpdate = ChapterUpdate(local.id) { read = true })
            local.read -> null
            serverPercentage <= 0.0 && local.lastPageRead <= 0L -> null
            else -> {
                // Part read on at least one side: compare exact pages.
                val serverPage = if (serverPercentage > 0.0) api.getProgress(fileId).pageNumber ?: 0 else 0
                val serverLastPageRead = (serverPage - 1).coerceAtLeast(0).toLong()
                when {
                    serverLastPageRead > local.lastPageRead ->
                        Decision(localUpdate = ChapterUpdate(local.id) { lastPageRead = serverLastPageRead })
                    local.lastPageRead > serverLastPageRead -> {
                        val pages = pageCount(fileId)
                        val page = (local.lastPageRead.toInt() + 1).coerceAtMost(pages)
                        Decision(
                            push =
                            BookOrbitPendingProgress(seriesId, book.id, fileId, page, pages) to serverPercentage,
                        )
                    }
                    else -> null
                }
            }
        }
    }

    private suspend fun pageCount(fileId: Int): Int =
        pageCounts[fileId] ?: api.getPageCount(fileId).also { pageCounts[fileId] = it }

    /** Reconciles every BookOrbit series in the library. Returns how many were synced. */
    suspend fun syncLibrary(): Int {
        if (!isEnabled()) return 0
        val mangas = getFavorites.await().filter { isEnabledFor(it) }
        mangas.forEach { syncManga(it) }
        flushPending()
        return mangas.size
    }

    /**
     * Delivers everything queued and reconciles the library series it belonged to, so progress
     * made on other devices meanwhile comes down too. Returns whether the queue is now empty.
     */
    suspend fun syncQueued(): Boolean {
        if (!isEnabled()) return true
        val queuedSeries = pendingMutex.withLock { readPending() }.values.map { it.seriesId }.toSet()
        if (queuedSeries.isEmpty()) return true
        getFavorites.await()
            .filter { isEnabledFor(it) && BookOrbitSource.seriesId(it.url) in queuedSeries }
            .forEach { syncManga(it) }
        // Series that aren't in the library have nothing local to reconcile.
        flushPending()
        return pendingMutex.withLock { readPending() }.isEmpty()
    }

    /** Delivers queued changes; stops at the first failure since the server is likely unreachable. */
    private suspend fun flushPending() {
        val pending = pendingMutex.withLock { readPending() }.values
        for (entry in pending) {
            if (deliver(entry, serverPercentage = null) == Delivery.Failed) return
        }
    }

    private enum class Delivery { Sent, Dropped, Failed }

    /**
     * Sends one queued change unless the server has already read further, in which case it is
     * dropped and the next pull brings the server's position down instead.
     */
    private suspend fun deliver(entry: BookOrbitPendingProgress, serverPercentage: Double?): Delivery {
        return try {
            val onServer = if (entry.markedByUser) 0.0 else serverPercentage ?: api.getProgress(entry.fileId).percentage
            if (shouldSend(entry, onServer)) {
                send(entry)
                removePending(listOf(entry))
                Delivery.Sent
            } else {
                removePending(listOf(entry))
                Delivery.Dropped
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "BookOrbit: could not send progress for file ${entry.fileId}, queued" }
            scheduleRetry()
            Delivery.Failed
        }
    }

    private suspend fun send(entry: BookOrbitPendingProgress) {
        when {
            entry.read -> {
                api.saveProgress(entry.fileId, BookOrbitProgressDto(entry.pages.takeIf { it > 0 }, 100.0))
                // Reaching 100% normally marks the book read; a mark by hand makes sure of it.
                if (entry.markedByUser) api.setStatus(entry.bookId, BookOrbitBookDto.STATUS_READ)
            }
            entry.page <= 0 -> api.markUnread(entry.bookId, entry.fileId)
            else -> api.saveProgress(entry.fileId, BookOrbitProgressDto(entry.page, entry.percentage))
        }
    }

    private fun scheduleRetry() = BookOrbitSyncWorker.enqueue(context)

    private suspend fun pendingFor(seriesId: Int): List<BookOrbitPendingProgress> =
        pendingMutex.withLock { readPending() }.values.filter { it.seriesId == seriesId }

    /** Queues changes, replacing older ones for the same file. Returns the entries as stored. */
    private suspend fun enqueue(
        progress: List<BookOrbitPendingProgress>,
        markedByUser: Boolean,
    ): List<BookOrbitPendingProgress> = pendingMutex.withLock {
        val current = readPending()
        val entries = progress.map { mergePending(current[it.fileId], it, markedByUser) }
        writePending(current + entries.associateBy { it.fileId })
        entries
    }

    /** Drops queued entries, but only if nothing newer replaced them in the meantime. */
    private suspend fun removePending(sent: List<BookOrbitPendingProgress>) = pendingMutex.withLock {
        val current = readPending()
        val remaining = current.filterNot { (fileId, entry) -> sent.any { it.fileId == fileId && it == entry } }
        if (remaining.size != current.size) writePending(remaining)
    }

    private fun readPending(): Map<Int, BookOrbitPendingProgress> {
        val raw = preferences.pendingProgress.get()
        if (raw.isBlank()) return emptyMap()
        return runCatching { json.decodeFromString<List<BookOrbitPendingProgress>>(raw) }
            .getOrElse { emptyList() }
            .associateBy { it.fileId }
    }

    private fun writePending(pending: Map<Int, BookOrbitPendingProgress>) {
        preferences.pendingProgress.set(if (pending.isEmpty()) "" else json.encodeToString(pending.values.toList()))
    }

    companion object {
        private const val PAGE_DEBOUNCE_MILLIS = 1_500L
        private const val PARALLEL_REQUESTS = 4

        /** BookOrbit stores percentages with some rounding, so tiny differences aren't "further". */
        private const val PERCENT_EPSILON = 0.01

        /** A deliberate read/unread mark always goes through; a page only if it's further than the server's. */
        fun shouldSend(entry: BookOrbitPendingProgress, serverPercentage: Double): Boolean =
            entry.markedByUser || entry.percentage > serverPercentage + PERCENT_EPSILON

        /**
         * A page read after marking a chapter by hand keeps the mark's priority until it is
         * delivered, so reading on from "mark unread" isn't overruled by the server.
         */
        fun mergePending(
            previous: BookOrbitPendingProgress?,
            progress: BookOrbitPendingProgress,
            markedByUser: Boolean,
        ): BookOrbitPendingProgress = progress.copy(markedByUser = markedByUser || previous?.markedByUser == true)
    }
}

/**
 * A position waiting to reach BookOrbit: [page] of [pages], 1-based, where 0 means unread. A
 * chapter marked read before its page count was known has [read] set and no pages.
 */
@Serializable
data class BookOrbitPendingProgress(
    val seriesId: Int,
    val bookId: Int,
    val fileId: Int,
    val page: Int,
    val pages: Int,
    val read: Boolean = false,
    val markedByUser: Boolean = false,
) {
    /** The position as BookOrbit's percentage, which is how its comic reader computes it. */
    val percentage: Double
        get() = when {
            read -> 100.0
            pages <= 0 || page <= 0 -> 0.0
            else -> page.coerceAtMost(pages) * 100.0 / pages
        }
}
