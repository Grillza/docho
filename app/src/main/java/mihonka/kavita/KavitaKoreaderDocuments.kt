package mihonka.kavita

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CancellationException
import logcat.LogPriority
import mihonka.kavita.KavitaSource.Companion.memoInt
import mihonka.kavita.KavitaSource.Companion.memoString
import mihonka.koreader.KoreaderChapterRef
import mihonka.koreader.KoreaderDocument
import mihonka.koreader.KoreaderDocumentCache
import mihonka.koreader.KoreaderDocumentProvider
import mihonka.koreader.KoreaderHash
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.manga.model.Manga
import java.util.concurrent.ConcurrentHashMap

/**
 * Kavita chapters for KOReader sync. Kavita stores KOReader's hash for every file it has
 * (re)scanned since it gained the feature, and the chapter list puts it in each chapter's memo.
 * Older files have none, so their hash is computed from the few blocks it covers, fetched with
 * ranged requests, and cached.
 */
@Inject
@SingleIn(AppScope::class)
class KavitaKoreaderDocuments(
    private val api: KavitaApi,
    private val source: KavitaSource,
    private val cache: KoreaderDocumentCache,
) : KoreaderDocumentProvider {

    override val sourceId: Long = KavitaSource.ID

    /** Kavita chapters whose file couldn't be hashed; not retried until restart. */
    private val unhashable: MutableSet<Int> = ConcurrentHashMap.newKeySet()

    override suspend fun documents(manga: Manga, chapters: List<KoreaderChapterRef>): Map<String, KoreaderDocument> {
        val fromMemo = chapters.associate { ref ->
            val hash = ref.memo.memoString(KavitaSource.MEMO_KOREADER_HASH)
            val pages = ref.memo.memoInt(KavitaSource.MEMO_PAGES)?.takeIf { it > 0 } ?: ref.pageCount
            ref.url to if (hash != null && pages != null && pages > 0) KoreaderDocument(hash, pages) else null
        }
        val missing = chapters.filter { fromMemo[it.url] == null }
        if (missing.isEmpty()) return fromMemo.mapNotNull { (url, document) -> document?.let { url to it } }.toMap()

        val remote = try {
            remoteChapters(manga, missing)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "KOReader: could not look up Kavita chapters of '${manga.title}'" }
            emptyMap()
        }
        return chapters.mapNotNull { ref ->
            val document = fromMemo[ref.url] ?: run {
                val chapterId = KavitaSource.chapterIdOrNull(ref.url) ?: return@run null
                val chapter = remote[chapterId] ?: return@run null
                val pages = chapter.pages.takeIf { it > 0 } ?: ref.pageCount ?: return@run null
                val hash = ref.memo.memoString(KavitaSource.MEMO_KOREADER_HASH)
                    ?: chapter.koreaderHash
                    ?: computedHash(chapter)
                    ?: return@run null
                KoreaderDocument(hash, pages)
            }
            document?.let { ref.url to it }
        }.toMap()
    }

    /** One chapter is looked up on its own; more come with the series' volumes in one request. */
    private suspend fun remoteChapters(manga: Manga, chapters: List<KoreaderChapterRef>): Map<Int, KavitaChapterDto> {
        if (chapters.size == 1) {
            val chapterId = KavitaSource.chapterIdOrNull(chapters.single().url) ?: return emptyMap()
            return mapOf(chapterId to api.getChapter(chapterId))
        }
        val seriesId = KavitaSource.seriesId(manga.url)
        return (source.progressCache.take(seriesId) ?: api.getVolumes(seriesId))
            .flatMap { it.chapters }
            .associateBy { it.id }
    }

    private suspend fun computedHash(chapter: KavitaChapterDto): String? {
        // KOReader opens each file of a chapter as its own document, and a chapter of loose
        // images isn't a file at all, so neither can be matched.
        val file = chapter.files.singleOrNull() ?: return null
        if (file.format == KavitaSeriesDto.FORMAT_IMAGE || chapter.id in unhashable) return null

        val key = "kavita:${chapter.id}"
        cache.get(key)?.let { return it.hash }
        return try {
            val hash = KoreaderHash.compute { offset, length ->
                api.readFileRange(chapter.id, offset, length).let { it.data to it.totalSize }
            }
            cache.put(key, KoreaderDocument(hash, chapter.pages))
            hash
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            logcat(LogPriority.WARN, e) { "KOReader: could not hash Kavita chapter ${chapter.id}" }
            unhashable += chapter.id
            null
        }
    }
}
