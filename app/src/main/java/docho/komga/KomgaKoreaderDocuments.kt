package docho.komga

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import docho.koreader.KoreaderChapterRef
import docho.koreader.KoreaderDocument
import docho.koreader.KoreaderDocumentCache
import docho.koreader.KoreaderDocumentProvider
import kotlinx.coroutines.CancellationException
import logcat.LogPriority
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.manga.model.Manga
import java.util.concurrent.ConcurrentHashMap

/**
 * Komga chapters for KOReader sync. Komga can store KOReader's hash but doesn't share it, and
 * only sends whole files, so a book is matched by downloading its file once and hashing it on
 * the way through. That only happens once the user has agreed to it
 * ([KomgaPreferences.koreaderDownloads]); the result is cached, as it only changes with the file.
 */
@Inject
@SingleIn(AppScope::class)
class KomgaKoreaderDocuments(
    private val api: KomgaApi,
    private val preferences: KomgaPreferences,
    private val cache: KoreaderDocumentCache,
) : KoreaderDocumentProvider {

    override val sourceId: Long = KomgaSource.ID

    /** Books whose file couldn't be hashed; not retried until restart. */
    private val unhashable: MutableSet<String> = ConcurrentHashMap.newKeySet()

    override suspend fun documents(manga: Manga, chapters: List<KoreaderChapterRef>): Map<String, KoreaderDocument> {
        if (!preferences.koreaderDownloads.get()) return emptyMap()
        return chapters.mapNotNull { ref ->
            val bookId = KomgaSource.bookIdOrNull(ref.url) ?: return@mapNotNull null
            if (bookId in unhashable) return@mapNotNull null
            val key = "komga:$bookId"
            val document = cache.get(key) ?: try {
                val pages = ref.pageCount?.takeIf { it > 0 } ?: api.getBook(bookId).media.pagesCount
                KoreaderDocument(api.koreaderHash(bookId), pages).also { cache.put(key, it) }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                logcat(LogPriority.WARN, e) { "KOReader: could not hash Komga book $bookId" }
                unhashable += bookId
                return@mapNotNull null
            }
            ref.url to document
        }.toMap()
    }
}
