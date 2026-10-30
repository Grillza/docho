package mihonka.koreader

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
import kotlinx.serialization.json.JsonObject
import logcat.LogPriority
import mihonka.bookorbit.BookOrbitKoreaderDocuments
import mihonka.kavita.KavitaKoreaderDocuments
import mihonka.komga.KomgaKoreaderDocuments
import mihonka.sync.ProgressSyncPreferences
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.chapter.interactor.GetChaptersByMangaId
import tachiyomi.domain.chapter.interactor.UpdateChapter
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.model.ChapterUpdate
import tachiyomi.domain.manga.interactor.GetFavorites
import tachiyomi.domain.manga.model.Manga
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.roundToInt

/**
 * Two-way, page-level reading progress sync with a KOReader sync server. While Settings → Sync
 * is set to KOReader it is the only sync: every series whose source can name the file behind
 * its chapters ([KoreaderDocumentProvider]) syncs here, and Kavita's and BookOrbit's own syncs
 * stand down. It follows the same rules as [mihonka.kavita.KavitaSync]: the side that has read
 * further wins, except for chapters marked read or unread by hand, and whatever can't be sent is
 * queued for [KoreaderSyncWorker].
 *
 * KOReader identifies a document by a partial MD5 of its file, and the server finds the book by
 * that hash, so a chapter only matches if the server has the very same file.
 *
 * Positions use KOReader's form for paged documents: the 1-based page number, with the chapter
 * read once its last page is reached. Mihon's `lastPageRead` is the 0-based index of that page.
 * The kosync protocol only has per-document requests, so a series is reconciled one chapter at a
 * time, a few at once.
 */
@Inject
@SingleIn(AppScope::class)
class KoreaderSync(
    private val context: Context,
    private val preferences: KoreaderPreferences,
    private val syncPreferences: ProgressSyncPreferences,
    private val api: KoreaderApi,
    kavitaDocuments: KavitaKoreaderDocuments,
    bookOrbitDocuments: BookOrbitKoreaderDocuments,
    komgaDocuments: KomgaKoreaderDocuments,
    localDocuments: LocalKoreaderDocuments,
    private val json: Json,
    private val getChaptersByMangaId: GetChaptersByMangaId,
    private val updateChapter: UpdateChapter,
    private val getFavorites: GetFavorites,
) {

    private val providers: Map<Long, KoreaderDocumentProvider> =
        listOf(kavitaDocuments, bookOrbitDocuments, komgaDocuments, localDocuments).associateBy { it.sourceId }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pendingMutex = Mutex()
    private val debounceJobs = ConcurrentHashMap<String, Job>()

    /** Documents the server said it has no book for; they aren't sent again until restart. */
    private val unknownDocuments: MutableSet<String> = ConcurrentHashMap.newKeySet()

    fun isEnabled(): Boolean = preferences.isConfigured()

    fun isEnabledFor(manga: Manga): Boolean =
        isEnabled() && syncPreferences.usesKoreader() && manga.source in providers

    private suspend fun document(manga: Manga, ref: KoreaderChapterRef): KoreaderDocument? =
        providers[manga.source]?.documents(manga, listOf(ref))?.get(ref.url)

    /** Called by the reader on every page change; the latest page per chapter is sent after a short pause. */
    fun onPageChanged(
        manga: Manga,
        chapterUrl: String,
        chapterMemo: JsonObject,
        pageIndex: Int,
        pageCount: Int,
        chapterRead: Boolean,
    ) {
        if (!isEnabledFor(manga)) return

        debounceJobs.remove(chapterUrl)?.cancel()
        debounceJobs[chapterUrl] = scope.launch {
            delay(PAGE_DEBOUNCE_MILLIS)
            debounceJobs.remove(chapterUrl)
            val document = document(manga, KoreaderChapterRef(chapterUrl, chapterMemo, pageCount.takeIf { it > 0 }))
                ?: return@launch
            val page = if (chapterRead) document.pages else pageIndex + 1
            val entry = enqueue(listOf(document.toPending(manga.id, page)), markedByUser = false).single()
            if (deliver(entry, serverPosition = null) == Delivery.Failed) scheduleRetry()
        }
    }

    /** Pushes chapters that were marked read or unread from the chapter list, library or updates. */
    fun onReadStatusChanged(manga: Manga, chapters: List<Chapter>, read: Boolean) {
        if (!isEnabledFor(manga) || chapters.isEmpty()) return
        scope.launch {
            chapters.forEach { debounceJobs.remove(it.url)?.cancel() }
            val documents = providers[manga.source]
                ?.documents(manga, chapters.map { KoreaderChapterRef(it.url, it.memo, pageCount = null) })
                ?.values
                .orEmpty()
            val entries = enqueue(
                documents.map { it.toPending(manga.id, if (read) it.pages else 0) },
                markedByUser = true,
            )
            for (entry in entries) {
                if (deliver(entry, serverPosition = null) == Delivery.Failed) break
            }
        }
    }

    /**
     * Delivers this manga's queued changes, then reconciles its chapters, or only [chapterIds]
     * when given (opening the reader only needs the chapter about to be read).
     */
    suspend fun syncManga(manga: Manga, chapterIds: Set<Long>? = null) {
        if (!isEnabledFor(manga)) return
        try {
            // Queued changes first. Those that were sent, or still can't be, are left out of the
            // comparison below; those the server has overtaken were dropped and are pulled.
            val sent = mutableSetOf<String>()
            for (entry in pendingFor(manga.id)) {
                val delivery = deliver(entry, serverPosition = null)
                if (delivery == Delivery.Sent) sent += entry.document
                if (delivery == Delivery.Failed) break
            }
            val skip = sent + pendingFor(manga.id).map { it.document }

            val locals = getChaptersByMangaId.await(manga.id)
                .filter { chapterIds == null || it.id in chapterIds }
            val documents = providers.getValue(manga.source)
                .documents(manga, locals.map { KoreaderChapterRef(it.url, it.memo, pageCount = null) })
            val semaphore = Semaphore(PARALLEL_REQUESTS)
            val decisions = coroutineScope {
                locals.map { local ->
                    async {
                        val document = documents[local.url] ?: return@async null
                        semaphore.withPermit { reconcile(manga, local, document, skip) }
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
                    "KOReader: synced '${manga.title}': ${localUpdates.size} pulled, ${pushes.size} pushed"
                }
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "KOReader: progress sync failed for '${manga.title}'" }
        }
    }

    private class Decision(
        val localUpdate: ChapterUpdate? = null,
        /** The change to send, and the position the server has now. */
        val push: Pair<KoreaderPendingProgress, Int>? = null,
    )

    private suspend fun reconcile(
        manga: Manga,
        local: Chapter,
        target: KoreaderDocument,
        skip: Set<String>,
    ): Decision? {
        if (target.hash in skip || target.hash in unknownDocuments) return null

        val server = position(api.getProgress(target.hash), target.pages)
        val serverRead = server >= target.pages
        val serverLastPageRead = (server - 1).coerceAtLeast(0)
        return when {
            local.read && !serverRead ->
                Decision(push = target.toPending(manga.id, target.pages) to server)
            !local.read && serverRead ->
                Decision(localUpdate = ChapterUpdate(local.id) { read = true })
            !local.read && serverLastPageRead > local.lastPageRead ->
                Decision(localUpdate = ChapterUpdate(local.id) { lastPageRead = serverLastPageRead })
            !local.read && local.lastPageRead > serverLastPageRead ->
                Decision(push = target.toPending(manga.id, local.lastPageRead + 1) to server)
            else -> null
        }
    }

    /** Reconciles every library series that syncs with KOReader. Returns how many were synced. */
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
        val queuedMangas = pendingMutex.withLock { readPending() }.values.map { it.mangaId }.toSet()
        if (queuedMangas.isEmpty()) return true
        getFavorites.await()
            .filter { it.id in queuedMangas }
            .forEach { syncManga(it) }
        // Series that aren't in the library, or no longer sync here, have nothing to reconcile.
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
    private suspend fun deliver(entry: KoreaderPendingProgress, serverPosition: Int?): Delivery {
        if (entry.document in unknownDocuments) {
            removePending(listOf(entry))
            return Delivery.Dropped
        }
        return try {
            val onServer = if (entry.markedByUser) {
                0
            } else {
                serverPosition ?: position(api.getProgress(entry.document), entry.pages)
            }
            if (shouldSend(entry, onServer)) {
                api.updateProgress(entry.toDto(preferences.deviceId()))
                removePending(listOf(entry))
                Delivery.Sent
            } else {
                removePending(listOf(entry))
                Delivery.Dropped
            }
        } catch (e: KoreaderUnknownDocumentException) {
            logcat(LogPriority.INFO) { "KOReader: the server has no book for document ${entry.document}" }
            unknownDocuments += entry.document
            removePending(listOf(entry))
            Delivery.Dropped
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "KOReader: could not send progress for document ${entry.document}, queued" }
            scheduleRetry()
            Delivery.Failed
        }
    }

    private fun scheduleRetry() = KoreaderSyncWorker.enqueue(context)

    private suspend fun pendingFor(mangaId: Long): List<KoreaderPendingProgress> =
        pendingMutex.withLock { readPending() }.values.filter { it.mangaId == mangaId }

    /** Queues changes, replacing older ones for the same document. Returns the entries as stored. */
    private suspend fun enqueue(
        progress: List<KoreaderPendingProgress>,
        markedByUser: Boolean,
    ): List<KoreaderPendingProgress> = pendingMutex.withLock {
        val current = readPending()
        val entries = progress.map { mergePending(current[it.document], it, markedByUser) }
        writePending(current + entries.associateBy { it.document })
        entries
    }

    /** Drops queued entries, but only if nothing newer replaced them in the meantime. */
    private suspend fun removePending(sent: List<KoreaderPendingProgress>) = pendingMutex.withLock {
        val current = readPending()
        val remaining = current.filterNot { (document, entry) -> sent.any { it.document == document && it == entry } }
        if (remaining.size != current.size) writePending(remaining)
    }

    private fun readPending(): Map<String, KoreaderPendingProgress> {
        val raw = preferences.pendingProgress.get()
        if (raw.isBlank()) return emptyMap()
        return runCatching { json.decodeFromString<List<KoreaderPendingProgress>>(raw) }
            .getOrElse { emptyList() }
            .associateBy { it.document }
    }

    private fun writePending(pending: Map<String, KoreaderPendingProgress>) {
        preferences.pendingProgress.set(if (pending.isEmpty()) "" else json.encodeToString(pending.values.toList()))
    }

    private fun KoreaderDocument.toPending(mangaId: Long, page: Int) = KoreaderPendingProgress(
        document = hash,
        mangaId = mangaId,
        page = page.coerceIn(0, pages),
        pages = pages,
    )

    companion object {
        private const val PAGE_DEBOUNCE_MILLIS = 1_500L
        private const val PARALLEL_REQUESTS = 6
        const val DEVICE_NAME = "Doki"

        /**
         * The server's position as a page number from 0 (not started) to [pages] (read). The page
         * is used when the server sent one; otherwise it is estimated from the percentage.
         */
        fun position(progress: KoreaderProgressDto?, pages: Int): Int {
            if (progress == null) return 0
            val percentage = progress.percentage ?: 0.0
            if (percentage >= 1.0) return pages
            val page = progress.progress?.trim()?.toIntOrNull() ?: (percentage * pages).roundToInt()
            return page.coerceIn(0, pages)
        }

        /** A deliberate read/unread mark always goes through; a page only if it's further than the server's. */
        fun shouldSend(entry: KoreaderPendingProgress, serverPosition: Int): Boolean =
            entry.markedByUser || entry.page > serverPosition

        /**
         * A page read after marking a chapter by hand keeps the mark's priority until it is
         * delivered, so reading on from "mark unread" isn't overruled by the server.
         */
        fun mergePending(
            previous: KoreaderPendingProgress?,
            progress: KoreaderPendingProgress,
            markedByUser: Boolean,
        ): KoreaderPendingProgress = progress.copy(markedByUser = markedByUser || previous?.markedByUser == true)
    }
}

/**
 * A position waiting to reach the server: [page] of [pages], where 0 means unread and [pages]
 * means read.
 */
@Serializable
data class KoreaderPendingProgress(
    val document: String,
    val mangaId: Long,
    val page: Int,
    val pages: Int,
    val markedByUser: Boolean = false,
) {
    fun toDto(deviceId: String) = KoreaderProgressDto(
        document = document,
        // KOReader has no page 0; an unread chapter is at the start of page 1.
        progress = page.coerceAtLeast(1).toString(),
        percentage = if (pages > 0) page.toDouble() / pages else 0.0,
        device = KoreaderSync.DEVICE_NAME,
        deviceId = deviceId,
    )
}
