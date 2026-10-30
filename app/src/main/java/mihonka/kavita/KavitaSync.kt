package mihonka.kavita

import android.content.Context
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
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
import kotlinx.serialization.json.JsonObject
import logcat.LogPriority
import mihonka.kavita.KavitaSource.Companion.memoInt
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
 * Two-way, page-level reading progress sync with Kavita.
 *
 * Mihon's `lastPageRead` and Kavita's `pagesRead` are both the index of the page being viewed,
 * and Kavita treats a chapter as read once `pagesRead` reaches its page count, so the two map
 * onto each other directly.
 *
 * The rule throughout is that the side that has read further wins, so reading on another device
 * while this one is offline is never undone. The one exception is marking chapters read or unread
 * by hand, which is a deliberate choice and is sent as is.
 *
 * - **Push**: page turns in the reader (debounced) and read/unread marks are queued, then sent.
 *   A page is only sent if it is further than what the server has. Whatever can't be delivered
 *   stays queued and [KavitaSyncWorker] delivers it as soon as there is a network again.
 * - **Pull**: [syncManga] runs when the reader opens, when a manga is opened, after every chapter
 *   refresh (which includes library updates), and after queued changes are delivered. A chapter
 *   read on either side ends up read on both; otherwise the higher page is kept on both.
 */
@Inject
@SingleIn(AppScope::class)
class KavitaSync(
    private val context: Context,
    private val preferences: KavitaPreferences,
    private val api: KavitaApi,
    private val source: KavitaSource,
    private val json: Json,
    private val getChaptersByMangaId: GetChaptersByMangaId,
    private val updateChapter: UpdateChapter,
    private val getFavorites: GetFavorites,
    private val syncPreferences: ProgressSyncPreferences,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pendingMutex = Mutex()
    private val debounceJobs = ConcurrentHashMap<Int, Job>()

    fun isEnabled(): Boolean = preferences.syncProgress.get() && preferences.isConfigured()

    /** While progress goes to a KOReader server, [mihonka.koreader.KoreaderSync] does it instead. */
    fun isEnabledFor(manga: Manga): Boolean =
        manga.source == KavitaSource.ID && isEnabled() && !syncPreferences.usesKoreader()

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
        val chapterId = KavitaSource.chapterIdOrNull(chapterUrl) ?: return

        debounceJobs.remove(chapterId)?.cancel()
        debounceJobs[chapterId] = scope.launch {
            delay(PAGE_DEBOUNCE_MILLIS)
            debounceJobs.remove(chapterId)
            val target = progressTarget(manga, chapterId, chapterMemo, pageCount) ?: return@launch
            val pageNum = if (chapterRead) target.pages else pageIndex
            val entry = enqueue(listOf(target.toDto(pageNum)), markedByUser = false).single()
            if (deliver(entry, serverPagesRead = null) == Delivery.Failed) scheduleRetry()
        }
    }

    /** Pushes chapters that were marked read or unread from the chapter list, library or updates. */
    fun onReadStatusChanged(manga: Manga, chapters: List<Chapter>, read: Boolean) {
        if (!isEnabledFor(manga) || chapters.isEmpty()) return
        scope.launch {
            val targets = chapters.mapNotNull { chapter ->
                val chapterId = KavitaSource.chapterIdOrNull(chapter.url) ?: return@mapNotNull null
                debounceJobs.remove(chapterId)?.cancel()
                progressTarget(manga, chapterId, chapter.memo, pageCount = null)
            }
            if (targets.isEmpty()) return@launch
            val entries = enqueue(targets.map { it.toDto(if (read) it.pages else 0) }, markedByUser = true)
            try {
                api.setChaptersRead(targets.first().seriesId, targets.map { it.chapterId }, read)
                removePending(entries)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                logcat(LogPriority.WARN, e) { "Kavita: could not mark ${entries.size} chapters read=$read, queued" }
                scheduleRetry()
            }
        }
    }

    /**
     * Delivers this series' queued changes, then reconciles it. [volumes] may carry data that was
     * just fetched; otherwise the copy the source cached while refreshing chapters is used, or the
     * server is asked.
     */
    suspend fun syncManga(manga: Manga, volumes: List<KavitaVolumeDto>? = null) {
        if (!isEnabledFor(manga)) return
        try {
            val seriesId = KavitaSource.seriesId(manga.url)
            val remoteVolumes = volumes ?: source.progressCache.take(seriesId) ?: api.getVolumes(seriesId)
            val remote = remoteVolumes.flatMap { volume -> volume.chapters }.associateBy { it.id }

            // Queued changes first, judged against what the server has right now. Those that were
            // sent, or still can't be, are left out of the comparison below; those the server has
            // overtaken were dropped and are pulled like any other chapter.
            val sent = mutableSetOf<Int>()
            for (entry in pendingFor(seriesId)) {
                val delivery = deliver(entry, remote[entry.progress.chapterId]?.pagesRead)
                if (delivery == Delivery.Sent) sent += entry.progress.chapterId
                if (delivery == Delivery.Failed) break
            }
            val skip = sent + pendingFor(seriesId).map { it.progress.chapterId }

            val localUpdates = mutableListOf<ChapterUpdate>()
            val readOnServer = mutableListOf<Target>()
            val partialPushes = mutableListOf<KavitaProgressDto>()

            getChaptersByMangaId.await(manga.id).forEach { local ->
                val chapterId = KavitaSource.chapterIdOrNull(local.url) ?: return@forEach
                if (chapterId in skip) return@forEach
                val server = remote[chapterId] ?: return@forEach
                if (server.pages <= 0) return@forEach

                val target = Target(
                    seriesId = seriesId,
                    libraryId = KavitaSource.libraryId(manga.url),
                    volumeId = server.volumeId,
                    chapterId = chapterId,
                    pages = server.pages,
                )
                val serverRead = server.pagesRead >= server.pages
                when {
                    local.read && !serverRead -> readOnServer += target
                    !local.read && serverRead -> localUpdates += ChapterUpdate(local.id) { read = true }
                    !local.read && server.pagesRead > local.lastPageRead ->
                        localUpdates += ChapterUpdate(local.id) { lastPageRead = server.pagesRead }
                    !local.read && local.lastPageRead > server.pagesRead ->
                        partialPushes += target.toDto(local.lastPageRead.coerceAtMost(server.pages - 1))
                }
            }

            if (localUpdates.isNotEmpty()) updateChapter.awaitAll(localUpdates)
            if (readOnServer.isNotEmpty() || partialPushes.isNotEmpty()) {
                // Queued before sending, so nothing is lost if the connection drops halfway.
                val entries = enqueue(readOnServer.map { it.toDto(it.pages) } + partialPushes, markedByUser = false)
                try {
                    if (readOnServer.isNotEmpty()) {
                        api.setChaptersRead(seriesId, readOnServer.map { it.chapterId }, read = true)
                    }
                    partialPushes.forEach { api.saveProgress(it) }
                    removePending(entries)
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    scheduleRetry()
                    throw e
                }
            }

            if (localUpdates.isNotEmpty() || readOnServer.isNotEmpty() || partialPushes.isNotEmpty()) {
                logcat(LogPriority.INFO) {
                    "Kavita: synced '${manga.title}': ${localUpdates.size} pulled, " +
                        "${readOnServer.size + partialPushes.size} pushed"
                }
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "Kavita: progress sync failed for '${manga.title}'" }
        }
    }

    /** Reconciles every Kavita manga in the library. Returns how many were synced. */
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
        val queuedSeries = pendingMutex.withLock { readPending() }.values.map { it.progress.seriesId }.toSet()
        if (queuedSeries.isEmpty()) return true
        getFavorites.await()
            .filter { it.source == KavitaSource.ID && KavitaSource.seriesId(it.url) in queuedSeries }
            .forEach { syncManga(it) }
        // Series that aren't in the library have nothing local to reconcile.
        flushPending()
        return pendingMutex.withLock { readPending() }.isEmpty()
    }

    /** Delivers queued changes; stops at the first failure since the server is likely unreachable. */
    private suspend fun flushPending() {
        val pending = pendingMutex.withLock { readPending() }.values
        for (entry in pending) {
            if (deliver(entry, serverPagesRead = null) == Delivery.Failed) return
        }
    }

    private enum class Delivery { Sent, Dropped, Failed }

    /**
     * Sends one queued change unless the server has already read further, in which case it is
     * dropped and the next pull brings the server's progress down instead.
     */
    private suspend fun deliver(entry: KavitaPendingProgress, serverPagesRead: Int?): Delivery {
        return try {
            val progress = entry.progress
            val onServer = if (entry.markedByUser) {
                0
            } else {
                serverPagesRead
                    ?: api.getPagesRead(progress.seriesId, progress.chapterId)
            }
            if (shouldSend(entry, onServer)) {
                api.saveProgress(progress)
                removePending(listOf(entry))
                Delivery.Sent
            } else {
                removePending(listOf(entry))
                Delivery.Dropped
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) {
                "Kavita: could not send progress for chapter ${entry.progress.chapterId}, queued"
            }
            scheduleRetry()
            Delivery.Failed
        }
    }

    private fun scheduleRetry() = KavitaSyncWorker.enqueue(context)

    private suspend fun pendingFor(seriesId: Int): List<KavitaPendingProgress> =
        pendingMutex.withLock { readPending() }.values.filter { it.progress.seriesId == seriesId }

    /** Queues changes, replacing older ones for the same chapter. Returns the entries as stored. */
    private suspend fun enqueue(
        progress: List<KavitaProgressDto>,
        markedByUser: Boolean,
    ): List<KavitaPendingProgress> = pendingMutex.withLock {
        val current = readPending()
        val entries = progress.map { mergePending(current[it.chapterId], it, markedByUser) }
        writePending(current + entries.associateBy { it.progress.chapterId })
        entries
    }

    /** Drops queued entries, but only if nothing newer replaced them in the meantime. */
    private suspend fun removePending(sent: List<KavitaPendingProgress>) = pendingMutex.withLock {
        val current = readPending()
        val remaining = current.filterNot { (chapterId, entry) ->
            sent.any {
                it.progress.chapterId == chapterId &&
                    it == entry
            }
        }
        if (remaining.size != current.size) writePending(remaining)
    }

    private fun readPending(): Map<Int, KavitaPendingProgress> {
        val raw = preferences.pendingProgress.get()
        if (raw.isBlank()) return emptyMap()
        return runCatching { json.decodeFromString<List<KavitaPendingProgress>>(raw) }
            .getOrElse { emptyList() }
            .associateBy { it.progress.chapterId }
    }

    private fun writePending(pending: Map<Int, KavitaPendingProgress>) {
        preferences.pendingProgress.set(if (pending.isEmpty()) "" else json.encodeToString(pending.values.toList()))
    }

    private data class Target(
        val seriesId: Int,
        val libraryId: Int,
        val volumeId: Int,
        val chapterId: Int,
        val pages: Int,
    ) {
        fun toDto(pageNum: Int) = KavitaProgressDto(
            volumeId = volumeId,
            chapterId = chapterId,
            pageNum = pageNum.coerceIn(0, pages),
            seriesId = seriesId,
            libraryId = libraryId,
        )
    }

    /**
     * Collects the ids Kavita wants with a progress update. They normally come from the chapter's
     * memo; chapters fetched before that existed cost one request.
     */
    private suspend fun progressTarget(manga: Manga, chapterId: Int, memo: JsonObject, pageCount: Int?): Target? {
        val seriesId = memo.memoInt(KavitaSource.MEMO_SERIES_ID) ?: KavitaSource.seriesId(manga.url)
        val libraryId = memo.memoInt(KavitaSource.MEMO_LIBRARY_ID) ?: KavitaSource.libraryId(manga.url)
        var volumeId = memo.memoInt(KavitaSource.MEMO_VOLUME_ID)
        var pages = memo.memoInt(KavitaSource.MEMO_PAGES) ?: pageCount
        if (volumeId == null || pages == null) {
            val chapter = try {
                api.getChapter(chapterId)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                logcat(LogPriority.WARN, e) { "Kavita: could not look up chapter $chapterId" }
                return null
            }
            volumeId = chapter.volumeId
            pages = chapter.pages
        }
        return Target(seriesId, libraryId, volumeId, chapterId, pages)
    }

    companion object {
        private const val PAGE_DEBOUNCE_MILLIS = 1_500L

        /** A deliberate read/unread mark always goes through; a page only if it's further than the server's. */
        fun shouldSend(entry: KavitaPendingProgress, serverPagesRead: Int): Boolean =
            entry.markedByUser || entry.progress.pageNum > serverPagesRead

        /**
         * A page read after marking a chapter by hand keeps the mark's priority until it is
         * delivered, so reading on from "mark unread" isn't overruled by the server.
         */
        fun mergePending(
            previous: KavitaPendingProgress?,
            progress: KavitaProgressDto,
            markedByUser: Boolean,
        ): KavitaPendingProgress = KavitaPendingProgress(progress, markedByUser || previous?.markedByUser == true)
    }
}

/** A progress change waiting to reach the server. */
@Serializable
data class KavitaPendingProgress(
    val progress: KavitaProgressDto,
    val markedByUser: Boolean = false,
)
