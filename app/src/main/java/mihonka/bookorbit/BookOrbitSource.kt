package mihonka.bookorbit

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import logcat.LogPriority
import okhttp3.OkHttpClient
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.source.model.UnreadListingSource
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId

/**
 * BookOrbit built into the app, like Kavita. A BookOrbit series is a manga and each of its books
 * with a comic archive is a chapter, read page by page through BookOrbit's comic page API.
 * Manga URLs are `/series/{seriesId}` and chapter URLs `/book/{bookId}/file/{fileId}`, so the
 * ids needed for progress sync never take an extra request.
 */
@Inject
@SingleIn(AppScope::class)
class BookOrbitSource(
    private val api: BookOrbitApi,
) : HttpSource(), UnreadListingSource {

    override val id: Long = ID

    override val name: String = NAME

    override val lang: String = "other"

    override val supportsLatest: Boolean = true

    override val baseUrl: String
        get() = api.apiUrlOrNull()?.removeSuffix("/api/v1").orEmpty()

    override val client: OkHttpClient
        get() = api.client

    override fun toString(): String = name

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var libraries: List<BookOrbitLibraryDto> = emptyList()

    /** Loads the library list for the filter sheet, which has to be built synchronously. */
    fun refreshLibraries() {
        if (api.apiUrlOrNull() == null) return
        scope.launch {
            try {
                libraries = api.getLibraries().sortedBy { it.name.lowercase() }
            } catch (e: Exception) {
                logcat(LogPriority.WARN, e) { "Could not load BookOrbit libraries" }
            }
        }
    }

    // Browse

    override suspend fun getPopularManga(page: Int): MangasPage =
        browse(page, query = null, sort = SORT_NAME, ascending = true, libraryId = null)

    override suspend fun getLatestUpdates(page: Int): MangasPage =
        browse(page, query = null, sort = SORT_LAST_ADDED, ascending = false, libraryId = null)

    /**
     * BookOrbit can only filter for series not started or in progress, not both at once, so
     * the whole list is loaded newest first on the first page and the finished series dropped.
     */
    override suspend fun getUnreadManga(page: Int): MangasPage {
        if (page > 1) return MangasPage(emptyList(), false)
        val unread = mutableListOf<SManga>()
        var serverPage = 0
        while (true) {
            val result = api.getSeriesPage(serverPage, null, SORT_LAST_ADDED, ascending = false, libraryId = null)
            result.items.filter { it.readCount < it.bookCount }.mapTo(unread) { it.toSManga() }
            serverPage++
            if (result.items.isEmpty() || serverPage * BookOrbitApi.PAGE_SIZE >= result.total) break
        }
        return MangasPage(unread, false)
    }

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        var libraryId: Int? = null
        var sort = SORT_NAME
        var ascending = true
        filters.forEach { filter ->
            when (filter) {
                is LibraryFilter -> libraryId = filter.selected()?.id
                is SortFilter -> filter.state?.let { selection ->
                    sort = SortFilter.FIELDS[selection.index]
                    ascending = selection.ascending
                }
                else -> {}
            }
        }
        return browse(page, query, sort, ascending, libraryId)
    }

    private suspend fun browse(
        page: Int,
        query: String?,
        sort: String,
        ascending: Boolean,
        libraryId: Int?,
    ): MangasPage {
        // Mihon counts pages from 1, BookOrbit from 0.
        val result = api.getSeriesPage(page - 1, query, sort, ascending, libraryId)
        val hasNext = page * BookOrbitApi.PAGE_SIZE < result.total
        return MangasPage(result.items.map { it.toSManga() }, hasNext)
    }

    override fun getFilterList(): FilterList {
        if (libraries.isEmpty()) refreshLibraries()
        return FilterList(
            LibraryFilter(libraries),
            SortFilter(),
        )
    }

    private class LibraryFilter(val libraries: List<BookOrbitLibraryDto>) :
        Filter.Select<String>("Library", arrayOf("All") + libraries.map { it.name }) {
        fun selected(): BookOrbitLibraryDto? = libraries.getOrNull(state - 1)
    }

    private class SortFilter : Filter.Sort(
        "Sort",
        arrayOf("Name", "Recently added", "Number of books", "Reading progress"),
        Selection(0, true),
    ) {
        companion object {
            val FIELDS = arrayOf(SORT_NAME, SORT_LAST_ADDED, "bookCount", "readProgress")
        }
    }

    // Details and chapters

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        val seriesId = seriesId(manga.url)
        // One request carries both the series details and its books.
        val books = api.getSeriesBooks(seriesId)
        progressCache.put(seriesId, books.items)
        val details = if (fetchDetails) mangaDetails(manga, seriesId, books) else manga
        val chapterList = if (fetchChapters) chapterList(books.items) else chapters
        return SMangaUpdate(details, chapterList)
    }

    private fun mangaDetails(manga: SManga, seriesId: Int, books: BookOrbitSeriesBooksPageDto): SManga =
        SManga.create().apply {
            url = seriesUrl(seriesId)
            title = books.seriesInfo?.name ?: manga.title
            author = books.seriesInfo?.authors?.joinToString()?.takeIf { it.isNotEmpty() }
            genre = books.items.flatMap { it.genres }.distinct().joinToString().takeIf { it.isNotEmpty() }
            thumbnail_url = books.items.firstOrNull()?.let { api.thumbnailUrl(it.id) } ?: manga.thumbnail_url
            status = SManga.UNKNOWN
            initialized = true
        }

    private fun chapterList(books: List<BookOrbitBookDto>): List<SChapter> =
        books.mapNotNull { book ->
            // Ebooks and audiobooks have no page images to show.
            val file = book.comicFile ?: return@mapNotNull null
            SChapter.create().apply {
                url = chapterUrl(book.id, file.id)
                name = chapterName(book.title, book.seriesIndex)
                chapter_number = book.seriesIndex?.toFloatOrNull() ?: -1f
                date_upload = parseDate(book.addedAt) ?: parseDate(book.publishedDate) ?: 0L
                // BookOrbit names a book after its file unless metadata renames it, and its book
                // list sends no file paths, so the title stands in for the file name.
                book.title?.takeIf { it.isNotBlank() }?.let { memo = fileNameMemo(it) }
            }
        }
            // BookOrbit lists a series in reading order; Mihon wants the newest first.
            .asReversed()

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val fileId = fileId(chapter.url)
        val pages = api.getPageCount(fileId)
        return List(pages) { index -> Page(index, imageUrl = api.pageImageUrl(fileId, index)) }
    }

    override fun getMangaUrl(manga: SManga): String = api.seriesWebUrl(seriesId(manga.url))

    override fun getChapterUrl(chapter: SChapter): String = "$baseUrl/books/${bookId(chapter.url)}"

    private fun BookOrbitSeriesDto.toSManga(): SManga = SManga.create().also {
        it.url = seriesUrl(id)
        it.title = name
        it.author = authors.joinToString().takeIf { authors -> authors.isNotEmpty() }
        it.thumbnail_url = coverBookIds.firstOrNull()?.let(api::thumbnailUrl)
    }

    /**
     * Books as last fetched with the chapter list, so the progress sync that follows a refresh
     * doesn't fetch the same data again.
     */
    val progressCache = ProgressCache()

    class ProgressCache {
        private val entries = HashMap<Int, Pair<Long, List<BookOrbitBookDto>>>()

        @Synchronized
        fun put(seriesId: Int, books: List<BookOrbitBookDto>) {
            entries[seriesId] = System.currentTimeMillis() to books
        }

        /** Takes the cached books if they are at most [maxAgeMillis] old; each entry is used once. */
        @Synchronized
        fun take(seriesId: Int, maxAgeMillis: Long = 30_000): List<BookOrbitBookDto>? {
            val (time, books) = entries.remove(seriesId) ?: return null
            return books.takeIf { System.currentTimeMillis() - time <= maxAgeMillis }
        }
    }

    companion object {
        /** Fixed id, so library entries survive reinstalls and don't depend on a generated hash. */
        const val ID = 0x424F4F4B4F5242L // "BOOKORB"
        const val NAME = "BookOrbit"

        private const val SORT_NAME = "name"
        private const val SORT_LAST_ADDED = "lastAddedAt"

        fun seriesUrl(seriesId: Int) = "/series/$seriesId"

        fun chapterUrl(bookId: Int, fileId: Int) = "/book/$bookId/file/$fileId"

        fun seriesId(url: String): Int = url.substringAfterLast("/series/").substringBefore('/').toInt()

        fun bookId(url: String): Int = url.substringAfter("/book/").substringBefore('/').toInt()

        fun fileId(url: String): Int = url.substringAfterLast("/file/").substringBefore('?').toInt()

        fun bookIdOrNull(url: String): Int? = url.substringAfter("/book/", "").substringBefore('/').toIntOrNull()

        fun fileIdOrNull(url: String): Int? = url.substringAfterLast("/file/", "").substringBefore('?').toIntOrNull()

        /** "Vol. 3 - Title", or whichever half the book has. */
        fun chapterName(title: String?, seriesIndex: String?): String {
            val cleanTitle = title?.trim()?.takeIf { it.isNotEmpty() }
            return when {
                seriesIndex != null && cleanTitle != null -> "Vol. $seriesIndex - $cleanTitle"
                seriesIndex != null -> "Vol. $seriesIndex"
                else -> cleanTitle ?: "Untitled"
            }
        }

        private fun fileNameMemo(fileName: String): JsonObject =
            buildJsonObject { put(Chapter.MEMO_FILE_NAME, fileName) }

        private fun parseDate(value: String?): Long? {
            if (value.isNullOrBlank()) return null
            return runCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
                .recoverCatching {
                    LocalDate.parse(value.take(10)).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                }
                .getOrNull()
        }
    }
}
