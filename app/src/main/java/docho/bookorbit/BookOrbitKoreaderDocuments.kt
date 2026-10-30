package docho.bookorbit

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

/**
 * BookOrbit chapters for KOReader sync. BookOrbit stores KOReader's hash for each file, as that
 * is how it matches KOReader's own progress; it comes with the book's details, and the page
 * count from the comic page API. Both are cached, as neither changes unless the file does.
 */
@Inject
@SingleIn(AppScope::class)
class BookOrbitKoreaderDocuments(
    private val api: BookOrbitApi,
    private val cache: KoreaderDocumentCache,
) : KoreaderDocumentProvider {

    override val sourceId: Long = BookOrbitSource.ID

    override suspend fun documents(manga: Manga, chapters: List<KoreaderChapterRef>): Map<String, KoreaderDocument> =
        chapters.mapNotNull { ref ->
            val bookId = BookOrbitSource.bookIdOrNull(ref.url) ?: return@mapNotNull null
            val fileId = BookOrbitSource.fileIdOrNull(ref.url) ?: return@mapNotNull null
            val key = "bookorbit:$fileId"
            val document = cache.get(key) ?: try {
                val hash = api.getBook(bookId).files.find { it.id == fileId }?.fileHash?.lowercase()
                    ?: return@mapNotNull null
                val pages = ref.pageCount?.takeIf { it > 0 } ?: api.getPageCount(fileId)
                KoreaderDocument(hash, pages).also { cache.put(key, it) }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                logcat(LogPriority.WARN, e) { "KOReader: could not look up BookOrbit file $fileId" }
                return@mapNotNull null
            }
            ref.url to document
        }.toMap()
}
