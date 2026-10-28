package mihonka.sync

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.serialization.json.JsonObject
import mihonka.bookorbit.BookOrbitSync
import mihonka.kavita.KavitaSync
import mihonka.koreader.KoreaderSync
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.manga.model.Manga

/**
 * Sends a manga's reading progress to wherever it is synced: the server of the source it is read
 * from, or the KOReader sync server when Settings → Sync says so. At most one of them is enabled
 * for any manga.
 */
@Inject
@SingleIn(AppScope::class)
class ProgressSync(
    private val kavitaSync: KavitaSync,
    private val koreaderSync: KoreaderSync,
    private val bookOrbitSync: BookOrbitSync,
) {

    fun isEnabled(): Boolean = kavitaSync.isEnabled() || koreaderSync.isEnabled() || bookOrbitSync.isEnabled()

    fun isEnabledFor(manga: Manga): Boolean =
        kavitaSync.isEnabledFor(manga) || koreaderSync.isEnabledFor(manga) || bookOrbitSync.isEnabledFor(manga)

    fun onPageChanged(
        manga: Manga,
        chapterUrl: String,
        chapterMemo: JsonObject,
        pageIndex: Int,
        pageCount: Int,
        chapterRead: Boolean,
    ) {
        kavitaSync.onPageChanged(manga, chapterUrl, chapterMemo, pageIndex, pageCount, chapterRead)
        koreaderSync.onPageChanged(manga, chapterUrl, chapterMemo, pageIndex, pageCount, chapterRead)
        bookOrbitSync.onPageChanged(manga, chapterUrl, pageIndex, pageCount, chapterRead)
    }

    fun onReadStatusChanged(manga: Manga, chapters: List<Chapter>, read: Boolean) {
        kavitaSync.onReadStatusChanged(manga, chapters, read)
        koreaderSync.onReadStatusChanged(manga, chapters, read)
        bookOrbitSync.onReadStatusChanged(manga, chapters, read)
    }

    /**
     * Reconciles a manga. [chapterIds] narrows it to the chapters about to be read, which only
     * matters for KOReader: Kavita and BookOrbit get a whole series in one request, KOReader one
     * chapter each.
     */
    suspend fun syncManga(manga: Manga, chapterIds: Set<Long>? = null) {
        kavitaSync.syncManga(manga)
        koreaderSync.syncManga(manga, chapterIds)
        bookOrbitSync.syncManga(manga)
    }
}
