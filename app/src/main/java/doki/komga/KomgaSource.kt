package doki.komga

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
 * Komga built into the app, like Kavita and BookOrbit. A Komga series is a manga and each of its
 * books that Komga serves as pages (comic archives, PDFs and image-based EPUBs) is a chapter.
 * Manga URLs are `/series/{seriesId}` and chapter URLs `/book/{bookId}`; Komga ids are strings.
 */
@Inject
@SingleIn(AppScope::class)
class KomgaSource(
    private val api: KomgaApi,
) : HttpSource(), UnreadListingSource {

    override val id: Long = ID

    override val name: String = NAME

    override val lang: String = "other"

    override val supportsLatest: Boolean = true

    override val baseUrl: String
        get() = api.apiUrlOrNull()?.removeSuffix("/api").orEmpty()

    override val client: OkHttpClient
        get() = api.client

    override fun toString(): String = name

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile
    private var libraries: List<KomgaLibraryDto> = emptyList()

    /** Loads the library list for the filter sheet, which has to be built synchronously. */
    fun refreshLibraries() {
        if (api.apiUrlOrNull() == null) return
        scope.launch {
            try {
                libraries = api.getLibraries().sortedBy { it.name.lowercase() }
            } catch (e: Exception) {
                logcat(LogPriority.WARN, e) { "Could not load Komga libraries" }
            }
        }
    }

    // Browse

    override suspend fun getPopularManga(page: Int): MangasPage =
        browse(page, query = null, sort = SORT_TITLE, libraryId = null)

    override suspend fun getLatestUpdates(page: Int): MangasPage =
        browse(page, query = null, sort = SORT_LAST_MODIFIED, libraryId = null)

    /** Komga filters by read status itself: series not started or part read, latest first. */
    override suspend fun getUnreadManga(page: Int): MangasPage =
        browse(page, query = null, sort = SORT_LAST_MODIFIED, libraryId = null, unreadOnly = true)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        var libraryId: String? = null
        var sort = SORT_TITLE
        filters.forEach { filter ->
            when (filter) {
                is LibraryFilter -> libraryId = filter.selected()?.id
                is SortFilter -> filter.state?.let { selection ->
                    sort = SortFilter.FIELDS[selection.index] + if (selection.ascending) ",asc" else ",desc"
                }
                else -> {}
            }
        }
        return browse(page, query, sort, libraryId)
    }

    private suspend fun browse(
        page: Int,
        query: String?,
        sort: String,
        libraryId: String?,
        unreadOnly: Boolean = false,
    ): MangasPage {
        // Mihon counts pages from 1, Komga from 0.
        val result = api.getSeriesPage(page - 1, query, sort, libraryId, unreadOnly)
        return MangasPage(result.content.map { it.toSManga() }, !result.last)
    }

    override fun getFilterList(): FilterList {
        if (libraries.isEmpty()) refreshLibraries()
        return FilterList(
            LibraryFilter(libraries),
            SortFilter(),
        )
    }

    private class LibraryFilter(val libraries: List<KomgaLibraryDto>) :
        Filter.Select<String>("Library", arrayOf("All") + libraries.map { it.name }) {
        fun selected(): KomgaLibraryDto? = libraries.getOrNull(state - 1)
    }

    private class SortFilter : Filter.Sort(
        "Sort",
        arrayOf("Title", "Recently added", "Recently updated", "Number of books"),
        Selection(0, true),
    ) {
        companion object {
            val FIELDS = arrayOf("metadata.titleSort", "created", "lastModified", "booksCount")
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
        val details = if (fetchDetails) api.getSeries(seriesId).toSManga(details = true) else manga
        val chapterList = if (fetchChapters) {
            val books = api.getSeriesBooks(seriesId)
            progressCache.put(seriesId, books)
            chapterList(books)
        } else {
            chapters
        }
        return SMangaUpdate(details, chapterList)
    }

    private fun chapterList(books: List<KomgaBookDto>): List<SChapter> =
        books.filter { it.hasPages }
            .map { book ->
                SChapter.create().apply {
                    url = chapterUrl(book.id)
                    name = chapterName(book.metadata.title.ifBlank { book.name }, book.metadata.number)
                    chapter_number = book.metadata.numberSort
                    date_upload = parseDate(book.created) ?: parseDate(book.metadata.releaseDate) ?: 0L
                    memo = buildJsonObject { put(Chapter.MEMO_FILE_NAME, book.fileName) }
                }
            }
            // Komga lists a series in reading order; Mihon wants the newest first.
            .asReversed()

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val bookId = bookId(chapter.url)
        return api.getPages(bookId).mapIndexed { index, page ->
            Page(index, imageUrl = api.pageImageUrl(bookId, page.number))
        }
    }

    override fun getMangaUrl(manga: SManga): String = api.seriesWebUrl(seriesId(manga.url))

    override fun getChapterUrl(chapter: SChapter): String = api.bookWebUrl(bookId(chapter.url))

    private fun KomgaSeriesDto.toSManga(details: Boolean = false): SManga = SManga.create().also {
        it.url = seriesUrl(id)
        it.title = title
        it.thumbnail_url = api.seriesThumbnailUrl(id)
        it.author = booksMetadata.authors
            .filter { author -> author.role in WRITER_ROLES }
            .map { author -> author.name }
            .distinct()
            .joinToString()
            .takeIf { authors -> authors.isNotEmpty() }
        if (details) {
            it.artist = booksMetadata.authors
                .filter { author -> author.role in ARTIST_ROLES }
                .map { author -> author.name }
                .distinct()
                .joinToString()
                .takeIf { artists -> artists.isNotEmpty() }
            it.description =
                metadata.summary.ifBlank { booksMetadata.summary }.takeIf { summary -> summary.isNotBlank() }
            it.genre =
                (metadata.genres + metadata.tags).distinct().joinToString().takeIf { genres -> genres.isNotEmpty() }
            it.status = when (metadata.status) {
                "ONGOING" -> SManga.ONGOING
                "ENDED" -> SManga.COMPLETED
                "HIATUS" -> SManga.ON_HIATUS
                "ABANDONED" -> SManga.CANCELLED
                else -> SManga.UNKNOWN
            }
            it.initialized = true
        }
    }

    /**
     * Books as last fetched with the chapter list, so the progress sync that follows a refresh
     * doesn't fetch the same data again.
     */
    val progressCache = ProgressCache()

    class ProgressCache {
        private val entries = HashMap<String, Pair<Long, List<KomgaBookDto>>>()

        @Synchronized
        fun put(seriesId: String, books: List<KomgaBookDto>) {
            entries[seriesId] = System.currentTimeMillis() to books
        }

        /** Takes the cached books if they are at most [maxAgeMillis] old; each entry is used once. */
        @Synchronized
        fun take(seriesId: String, maxAgeMillis: Long = 30_000): List<KomgaBookDto>? {
            val (time, books) = entries.remove(seriesId) ?: return null
            return books.takeIf { System.currentTimeMillis() - time <= maxAgeMillis }
        }
    }

    companion object {
        /** Fixed id, so library entries survive reinstalls and don't depend on a generated hash. */
        const val ID = 0x4B4F4D47413031L // "KOMGA01"
        const val NAME = "Komga"

        private const val SORT_TITLE = "metadata.titleSort,asc"
        private const val SORT_LAST_MODIFIED = "lastModified,desc"

        private val WRITER_ROLES = setOf("writer")
        private val ARTIST_ROLES = setOf("penciller", "inker", "colorist", "cover")

        fun seriesUrl(seriesId: String) = "/series/$seriesId"

        fun chapterUrl(bookId: String) = "/book/$bookId"

        fun seriesId(url: String): String = url.substringAfterLast("/series/").substringBefore('/')

        fun bookId(url: String): String = url.substringAfterLast("/book/").substringBefore('/').substringBefore('?')

        fun bookIdOrNull(url: String): String? =
            url.substringAfterLast("/book/", "").substringBefore('/').substringBefore('?').takeIf { it.isNotEmpty() }

        /** "#3 - Title", or the title alone when it's no more than the number. */
        fun chapterName(title: String, number: String): String {
            val cleanTitle = title.trim()
            val cleanNumber = number.trim()
            return when {
                cleanNumber.isEmpty() -> cleanTitle.ifEmpty { "Untitled" }
                cleanTitle.isEmpty() || cleanTitle == cleanNumber -> "#$cleanNumber"
                else -> "#$cleanNumber - $cleanTitle"
            }
        }

        /** Komga writes times in UTC as `2024-05-01T10:20:30Z`, and release dates as `2024-05-01`. */
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
