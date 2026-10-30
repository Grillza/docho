package doki.komga

import android.content.Context
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import doki.sync.ProgressSyncPreferences
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import logcat.LogPriority
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.chapter.interactor.GetChaptersByMangaId
import tachiyomi.domain.chapter.interactor.UpdateChapter
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.model.ChapterUpdate
import tachiyomi.domain.manga.interactor.GetFavorites
import tachiyomi.domain.manga.model.Manga
import java.util.concurrent.ConcurrentHashMap

/**
 * Two-way, page-level reading progress sync with Komga, for series read from the Komga source.
 * It follows the same rules as [doki.kavita.KavitaSync] and [doki.bookorbit.BookOrbitSync]:
 * the side that has read further wins, except for chapters marked read or unread by hand, and
 * whatever can't be sent is queued for [KomgaSyncWorker].
 *
 * Komga keeps one position per book: the page reached, counting from 1, and whether the book is
 * finished. A series' book list carries every book's position, so reconciling a series takes one
 * request.
 */
@Inject
@SingleIn(AppScope::class)
class KomgaSync(
    private val context: Context,
    private val preferences: KomgaPreferences,
    private val syncPreferences: ProgressSyncPreferences,
    private val api: KomgaApi,
    private val source: KomgaSource,
    private val json: Json,
    private val getChaptersByMangaId: GetChaptersByMangaId,
    private val updateChapter: UpdateChapter,
    private val getFavorites: GetFavorites,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pendingMutex = Mutex()
    private val debounceJobs = ConcurrentHashMap<String, Job>()

    /** Page counts by book id, learned from the reader or the book list. */
    private val pageCounts = ConcurrentHashMap<String, Int>()

    fun isEnabled(): Boolean = preferences.syncProgress.get() && preferences.isConfigured()

    /** Komga books can't be matched by a KOReader server, so KOReader mode leaves them unsynced. */
    fun isEnabledFor(manga: Manga): Boolean =
        manga.source == KomgaSource.ID && isEnabled() && !syncPreferences.usesKoreader()

    /** Called by the reader on every page change; the latest page per chapter is sent after a short pause. */
    fun onPageChanged(manga: Manga, chapterUrl: String, pageIndex: Int, pageCount: Int, chapterRead: Boolean) {
        if (!isEnabledFor(manga) || pageCount <= 0) return
        val bookId = KomgaSource.bookIdOrNull(chapterUrl) ?: return
        pageCounts[bookId] = pageCount

        debounceJobs.remove(bookId)?.cancel()
        debounceJobs[bookId] = scope.launch {
            delay(PAGE_DEBOUNCE_MILLIS)
            debounceJobs.remove(bookId)
            val progress = KomgaPendingProgress(
                seriesId = KomgaSource.seriesId(manga.url),
                bookId = bookId,
                page = if (chapterRead) pageCount else pageIndex + 1,
                pages = pageCount,
                read = chapterRead,
            )
            val entry = enqueue(listOf(progress), markedByUser = false).single()
            if (deliver(entry, serverPosition = null) == Delivery.Failed) scheduleRetry()
        }
    }

    /** Pushes chapters that were marked read or unread from the chapter list, library or updates. */
    fun onReadStatusChanged(manga: Manga, chapters: List<Chapter>, read: Boolean) {
        if (!isEnabledFor(manga) || chapters.isEmpty()) return
        scope.launch {
            val seriesId = KomgaSource.seriesId(manga.url)
            val progress = chapters.mapNotNull { chapter ->
                val bookId = KomgaSource.bookIdOrNull(chapter.url) ?: return@mapNotNull null
                debounceJobs.remove(bookId)?.cancel()
                val pages = pageCounts[bookId] ?: 0
                KomgaPendingProgress(seriesId, bookId, page = if (read) pages else 0, pages, read)
            }
            val entries = enqueue(progress, markedByUser = true)
            for (entry in entries) {
                if (deliver(entry, serverPosition = null) == Delivery.Failed) break
            }
        }
    }

    /** Delivers this series' queued changes, then reconciles it with the server. */
    suspend fun syncManga(manga: Manga) {
        if (!isEnabledFor(manga)) return
        try {
            val seriesId = KomgaSource.seriesId(manga.url)
            val books = (source.progressCache.take(seriesId) ?: api.getSeriesBooks(seriesId))
                .filter { it.hasPages }
                .associateBy { it.id }
            books.values.forEach { pageCounts[it.id] = it.media.pagesCount }

            // Queued changes first, judged against the positions just fetched. Those that were
            // sent, or still can't be, are left out of the comparison below; those the server has
            // overtaken were dropped and are pulled.
            val sent = mutableSetOf<String>()
            for (entry in pendingFor(seriesId)) {
                val delivery = deliver(entry, books[entry.bookId]?.let(::serverPosition))
                if (delivery == Delivery.Sent) sent += entry.bookId
                if (delivery == Delivery.Failed) break
            }
            val skip = sent + pendingFor(seriesId).map { it.bookId }

            val decisions = getChaptersByMangaId.await(manga.id).mapNotNull { local ->
                val bookId = KomgaSource.bookIdOrNull(local.url) ?: return@mapNotNull null
                val book = books[bookId] ?: return@mapNotNull null
                if (bookId in skip) return@mapNotNull null
                reconcile(seriesId, local, book)
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
                    "Komga: synced '${manga.title}': ${localUpdates.size} pulled, ${pushes.size} pushed"
                }
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "Komga: progress sync failed for '${manga.title}'" }
        }
    }

    private class Decision(
        val localUpdate: ChapterUpdate? = null,
        /** The change to send, and the position the server has now. */
        val push: Pair<KomgaPendingProgress, Int>? = null,
    )

    private fun reconcile(seriesId: String, local: Chapter, book: KomgaBookDto): Decision? {
        val pages = book.media.pagesCount
        val serverPage = book.readProgress?.page ?: 0
        return when {
            local.read && !book.isRead -> Decision(
                push = KomgaPendingProgress(seriesId, book.id, pages, pages, read = true) to serverPosition(book),
            )
            !local.read && book.isRead -> Decision(localUpdate = ChapterUpdate(local.id) { read = true })
            local.read -> null
            serverPage <= 0 && local.lastPageRead <= 0 -> null
            else -> {
                val serverLastPageRead = (serverPage - 1).coerceAtLeast(0)
                when {
                    serverLastPageRead > local.lastPageRead ->
                        Decision(localUpdate = ChapterUpdate(local.id) { lastPageRead = serverLastPageRead })
                    local.lastPageRead > serverLastPageRead -> {
                        val page = (local.lastPageRead + 1).coerceAtMost(pages)
                        Decision(push = KomgaPendingProgress(seriesId, book.id, page, pages) to serverPosition(book))
                    }
                    else -> null
                }
            }
        }
    }

    /** Reconciles every Komga series in the library. Returns how many were synced. */
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
            .filter { isEnabledFor(it) && KomgaSource.seriesId(it.url) in queuedSeries }
            .forEach { syncManga(it) }
        // Series that aren't in the library have nothing local to reconcile.
        flushPending()
        return pendingMutex.withLock { readPending() }.isEmpty()
    }

    /** Delivers queued changes; stops at the first failure since the server is likely unreachable. */
    private suspend fun flushPending() {
        val pending = pendingMutex.withLock { readPending() }.values
        for (entry in pending) {
            if (deliver(entry, serverPosition = null) == Delivery.Failed) return
        }
    }

    private enum class Delivery { Sent, Dropped, Failed }

    /**
     * Sends one queued change unless the server has already read further, in which case it is
     * dropped and the next pull brings the server's position down instead.
     */
    private suspend fun deliver(entry: KomgaPendingProgress, serverPosition: Int?): Delivery {
        return try {
            val onServer = if (entry.markedByUser) 0 else serverPosition ?: serverPosition(api.getBook(entry.bookId))
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
            logcat(LogPriority.WARN, e) { "Komga: could not send progress for book ${entry.bookId}, queued" }
            scheduleRetry()
            Delivery.Failed
        }
    }

    private suspend fun send(entry: KomgaPendingProgress) {
        when {
            entry.read -> api.markRead(entry.bookId)
            entry.page <= 0 -> api.markUnread(entry.bookId)
            else -> api.saveProgress(entry.bookId, entry.page)
        }
    }

    private fun scheduleRetry() = KomgaSyncWorker.enqueue(context)

    private suspend fun pendingFor(seriesId: String): List<KomgaPendingProgress> =
        pendingMutex.withLock { readPending() }.values.filter { it.seriesId == seriesId }

    /** Queues changes, replacing older ones for the same book. Returns the entries as stored. */
    private suspend fun enqueue(
        progress: List<KomgaPendingProgress>,
        markedByUser: Boolean,
    ): List<KomgaPendingProgress> = pendingMutex.withLock {
        val current = readPending()
        val entries = progress.map { mergePending(current[it.bookId], it, markedByUser) }
        writePending(current + entries.associateBy { it.bookId })
        entries
    }

    /** Drops queued entries, but only if nothing newer replaced them in the meantime. */
    private suspend fun removePending(sent: List<KomgaPendingProgress>) = pendingMutex.withLock {
        val current = readPending()
        val remaining = current.filterNot { (bookId, entry) -> sent.any { it.bookId == bookId && it == entry } }
        if (remaining.size != current.size) writePending(remaining)
    }

    private fun readPending(): Map<String, KomgaPendingProgress> {
        val raw = preferences.pendingProgress.get()
        if (raw.isBlank()) return emptyMap()
        return runCatching { json.decodeFromString<List<KomgaPendingProgress>>(raw) }
            .getOrElse { emptyList() }
            .associateBy { it.bookId }
    }

    private fun writePending(pending: Map<String, KomgaPendingProgress>) {
        preferences.pendingProgress.set(if (pending.isEmpty()) "" else json.encodeToString(pending.values.toList()))
    }

    companion object {
        private const val PAGE_DEBOUNCE_MILLIS = 1_500L

        /** How far a book is on the server, in the same terms as [KomgaPendingProgress.position]. */
        fun serverPosition(book: KomgaBookDto): Int {
            val progress = book.readProgress ?: return 0
            return if (progress.completed) Int.MAX_VALUE else progress.page
        }

        /** A deliberate read/unread mark always goes through; a page only if it's further than the server's. */
        fun shouldSend(entry: KomgaPendingProgress, serverPosition: Int): Boolean =
            entry.markedByUser || entry.position > serverPosition

        /**
         * A page read after marking a chapter by hand keeps the mark's priority until it is
         * delivered, so reading on from "mark unread" isn't overruled by the server.
         */
        fun mergePending(
            previous: KomgaPendingProgress?,
            progress: KomgaPendingProgress,
            markedByUser: Boolean,
        ): KomgaPendingProgress = progress.copy(markedByUser = markedByUser || previous?.markedByUser == true)
    }
}

/**
 * A position waiting to reach Komga: [page] of [pages], counting from 1, where 0 means unread. A
 * chapter marked read before its page count was known has [read] set and no pages.
 */
@Serializable
data class KomgaPendingProgress(
    val seriesId: String,
    val bookId: String,
    val page: Int,
    val pages: Int,
    val read: Boolean = false,
    val markedByUser: Boolean = false,
) {
    /** How far this is, comparable with [KomgaSync.serverPosition]: a finished book beats any page. */
    val position: Int
        get() = if (read) Int.MAX_VALUE else page
}
