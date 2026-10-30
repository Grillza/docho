package doki.kavita

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
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import logcat.LogPriority
import okhttp3.OkHttpClient
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.source.model.UnreadListingSource
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId

/**
 * Kavita built into the app rather than installed as an extension. It is always present while a
 * server is configured, and its manga carry Kavita's web path as their URL
 * (`/library/{libraryId}/series/{seriesId}`), so the ids needed for progress sync never take
 * an extra request.
 */
@Inject
@SingleIn(AppScope::class)
class KavitaSource(
    private val api: KavitaApi,
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
    private var libraries: List<KavitaLibraryDto> = emptyList()

    /** Loads the library list for the filter sheet, which has to be built synchronously. */
    fun refreshLibraries() {
        if (api.apiUrlOrNull() == null) return
        scope.launch {
            try {
                libraries = api.getLibraries().sortedBy { it.name.lowercase() }
            } catch (e: Exception) {
                logcat(LogPriority.WARN, e) { "Could not load Kavita libraries" }
            }
        }
    }

    init {
        refreshLibraries()
    }

    // Browse

    override suspend fun getPopularManga(page: Int): MangasPage =
        browse(page, KavitaFilterDto(sortOptions = KavitaSortOptionsDto(KavitaConstants.SORT_NAME, true)))

    override suspend fun getLatestUpdates(page: Int): MangasPage =
        browse(
            page,
            KavitaFilterDto(sortOptions = KavitaSortOptionsDto(KavitaConstants.SORT_LAST_CHAPTER_ADDED, false)),
        )

    /** Kavita's own "unread" filter: read progress below 100%. */
    override suspend fun getUnreadManga(page: Int): MangasPage =
        browse(
            page,
            KavitaFilterDto(
                statements = listOf(
                    KavitaFilterStatementDto(
                        KavitaConstants.COMPARISON_NOT_EQUAL,
                        KavitaConstants.FIELD_READ_PROGRESS,
                        "100",
                    ),
                ),
                sortOptions = KavitaSortOptionsDto(KavitaConstants.SORT_LAST_CHAPTER_ADDED, false),
            ),
        )

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        val statements = mutableListOf<KavitaFilterStatementDto>()
        if (query.isNotBlank()) {
            statements += KavitaFilterStatementDto(
                KavitaConstants.COMPARISON_MATCHES,
                KavitaConstants.FIELD_SERIES_NAME,
                query.trim(),
            )
        }
        var sort = KavitaSortOptionsDto(KavitaConstants.SORT_NAME, true)
        filters.forEach { filter ->
            when (filter) {
                is LibraryFilter -> filter.selected()?.let {
                    statements += KavitaFilterStatementDto(
                        KavitaConstants.COMPARISON_CONTAINS,
                        KavitaConstants.FIELD_LIBRARIES,
                        it.id.toString(),
                    )
                }
                is SortFilter -> filter.state?.let { selection ->
                    sort = KavitaSortOptionsDto(SortFilter.FIELDS[selection.index], selection.ascending)
                }
                else -> {}
            }
        }
        return browse(page, KavitaFilterDto(statements = statements, sortOptions = sort))
    }

    private suspend fun browse(page: Int, filter: KavitaFilterDto): MangasPage {
        // EPUBs are rendered as text by Kavita and have no page images to show here.
        val withoutEpub = filter.copy(
            statements = filter.statements + KavitaFilterStatementDto(
                KavitaConstants.COMPARISON_NOT_CONTAINS,
                KavitaConstants.FIELD_FORMATS,
                KavitaSeriesDto.FORMAT_EPUB.toString(),
            ),
        )
        val (series, hasNext) = api.getSeriesPage(withoutEpub, page)
        return MangasPage(series.map { it.toSManga() }, hasNext)
    }

    override fun getFilterList(): FilterList {
        if (libraries.isEmpty()) refreshLibraries()
        return FilterList(
            LibraryFilter(libraries),
            SortFilter(),
        )
    }

    private class LibraryFilter(val libraries: List<KavitaLibraryDto>) :
        Filter.Select<String>("Library", arrayOf("All") + libraries.map { it.name }) {
        fun selected(): KavitaLibraryDto? = libraries.getOrNull(state - 1)
    }

    private class SortFilter : Filter.Sort(
        "Sort",
        arrayOf("Name", "Recently added", "Last chapter added", "Reading progress"),
        Selection(0, true),
    ) {
        companion object {
            val FIELDS = intArrayOf(
                KavitaConstants.SORT_NAME,
                KavitaConstants.SORT_CREATED,
                KavitaConstants.SORT_LAST_CHAPTER_ADDED,
                KavitaConstants.SORT_READ_PROGRESS,
            )
        }
    }

    // Details and chapters

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate = supervisorScope {
        val seriesId = seriesId(manga.url)
        val details = if (fetchDetails) async { mangaDetails(manga, seriesId) } else null
        val chapterList = if (fetchChapters) async { chapterList(manga, seriesId) } else null
        SMangaUpdate(details?.await() ?: manga, chapterList?.await() ?: chapters)
    }

    private suspend fun mangaDetails(manga: SManga, seriesId: Int): SManga = supervisorScope {
        val series = async { api.getSeries(seriesId) }
        val metadata = async { api.getSeriesMetadata(seriesId) }
        series.await().toSManga().apply {
            val meta = metadata.await()
            description = meta.summary?.trim()?.takeIf { it.isNotEmpty() }
            author = meta.writers.labels()
            artist = (meta.pencillers.ifEmpty { meta.coverArtists }).labels()
            genre = (meta.genres + meta.tags).labels()
            status = when (meta.publicationStatus) {
                KavitaConstants.STATUS_ONGOING -> SManga.ONGOING
                KavitaConstants.STATUS_HIATUS -> SManga.ON_HIATUS
                KavitaConstants.STATUS_COMPLETED, KavitaConstants.STATUS_ENDED -> SManga.COMPLETED
                KavitaConstants.STATUS_CANCELLED -> SManga.CANCELLED
                else -> SManga.UNKNOWN
            }
            initialized = true
        }
    }

    private suspend fun chapterList(manga: SManga, seriesId: Int): List<SChapter> {
        val volumes = api.getVolumes(seriesId)
        progressCache.put(seriesId, volumes)
        val libraryId = libraryId(manga.url)

        val specials = mutableListOf<SChapter>()
        val looseChapters = mutableListOf<SChapter>()
        val volumeEntries = mutableListOf<SChapter>()

        volumes.sortedBy { it.volumeNumber }.forEach { volume ->
            val looseLeaf = volume.isLooseLeaf()
            volume.chapters.sortedBy { it.chapterNumber }.forEach { chapter ->
                val sChapter = SChapter.create().apply {
                    url = chapterUrl(chapter.id)
                    memo = chapterMemo(seriesId, libraryId, chapter)
                    date_upload = parseDate(chapter.releaseDate) ?: parseDate(chapter.created) ?: 0L
                }
                when {
                    chapter.isSpecial || volume.volumeNumber == KavitaConstants.SPECIAL_VOLUME_NUMBER -> {
                        sChapter.name = chapter.displayTitle() ?: "Special"
                        sChapter.chapter_number = specialChapterNumber(specials.size)
                        specials += sChapter
                    }
                    chapter.isWholeVolume() -> {
                        sChapter.name = buildString {
                            append("Volume ").append(volume.displayNumber())
                            chapter.titleName
                                ?.takeIf { it.isNotBlank() && it != volume.name }
                                ?.let { append(" - ").append(it) }
                        }
                        sChapter.chapter_number = volumeChapterNumber(volume.volumeNumber)
                        volumeEntries += sChapter
                    }
                    else -> {
                        sChapter.name = buildString {
                            if (!looseLeaf) append("Vol. ").append(volume.displayNumber()).append(' ')
                            append("Ch. ")
                            append(chapter.range?.takeIf { it.isNotBlank() } ?: formatNumber(chapter.chapterNumber))
                            chapter.titleName
                                ?.takeIf { it.isNotBlank() && it != chapter.range }
                                ?.let { append(" - ").append(it) }
                        }
                        sChapter.chapter_number = chapter.chapterNumber
                        if (looseLeaf) looseChapters += sChapter else volumeEntries += sChapter
                    }
                }
            }
        }

        // Kavita's reading order is volumes, then loose chapters, then specials; Mihon wants the newest first.
        return (volumeEntries + looseChapters + specials).asReversed()
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val chapterId = chapterId(chapter.url)
        val pages = api.getChapter(chapterId).pages
        return List(pages) { index -> Page(index, imageUrl = api.pageImageUrl(chapterId, index)) }
    }

    override fun getMangaUrl(manga: SManga): String = baseUrl + manga.url

    override fun getChapterUrl(chapter: SChapter): String = baseUrl + chapter.url

    private fun KavitaSeriesDto.toSManga(): SManga = SManga.create().also {
        it.url = seriesUrl(libraryId, id)
        it.title = name ?: localizedName ?: originalName ?: "Series $id"
        it.thumbnail_url = api.seriesCoverUrl(id)
    }

    /**
     * Volumes as last fetched with the chapter list, so the progress sync that follows a refresh
     * doesn't fetch the same data again.
     */
    val progressCache = ProgressCache()

    class ProgressCache {
        private val entries = HashMap<Int, Pair<Long, List<KavitaVolumeDto>>>()

        @Synchronized
        fun put(seriesId: Int, volumes: List<KavitaVolumeDto>) {
            entries[seriesId] = System.currentTimeMillis() to volumes
        }

        /** Takes the cached volumes if they are at most [maxAgeMillis] old; each entry is used once. */
        @Synchronized
        fun take(seriesId: Int, maxAgeMillis: Long = 30_000): List<KavitaVolumeDto>? {
            val (time, volumes) = entries.remove(seriesId) ?: return null
            return volumes.takeIf { System.currentTimeMillis() - time <= maxAgeMillis }
        }
    }

    companion object {
        /** Fixed id, so library entries survive reinstalls and don't depend on a generated hash. */
        const val ID = 0x4B415649544131L // "KAVITA1"
        const val NAME = "Kavita"

        fun seriesUrl(libraryId: Int, seriesId: Int) = "/library/$libraryId/series/$seriesId"

        fun chapterUrl(chapterId: Int) = "/chapter/$chapterId"

        fun seriesId(url: String): Int =
            url.substringAfterLast("/series/").substringBefore('/').substringBefore('?').toInt()

        fun libraryId(url: String): Int =
            url.substringAfter("/library/", "").substringBefore('/').toIntOrNull() ?: 0

        fun chapterId(url: String): Int = url.substringAfterLast("/chapter/").substringBefore('?').toInt()

        fun chapterIdOrNull(url: String): Int? =
            url.substringAfterLast("/chapter/", "").substringBefore('?').toIntOrNull()

        private fun chapterMemo(seriesId: Int, libraryId: Int, chapter: KavitaChapterDto): JsonObject =
            buildJsonObject {
                put(MEMO_SERIES_ID, seriesId)
                put(MEMO_LIBRARY_ID, libraryId)
                put(MEMO_VOLUME_ID, chapter.volumeId)
                put(MEMO_PAGES, chapter.pages)
                chapter.koreaderHash?.let { put(MEMO_KOREADER_HASH, it) }
                chapter.fileName?.let { put(Chapter.MEMO_FILE_NAME, it) }
            }

        const val MEMO_SERIES_ID = "kavitaSeriesId"
        const val MEMO_LIBRARY_ID = "kavitaLibraryId"
        const val MEMO_VOLUME_ID = "kavitaVolumeId"
        const val MEMO_PAGES = "kavitaPages"
        const val MEMO_KOREADER_HASH = "koreaderHash"

        /**
         * Like Kavita, a whole-volume file is never compared with a chapter of the same number, so
         * "Volume 3" must not look like "Ch. 3" to duplicate detection, missing-chapter gaps or
         * trackers. Negative numbers are unrecognized in Mihon; each volume still gets its own, in
         * volume order and below every chapter.
         */
        fun volumeChapterNumber(volumeNumber: Float): Float = volumeNumber - 100_000f

        /** Specials get distinct unrecognized numbers too, below the volumes, in Kavita's order. */
        fun specialChapterNumber(index: Int): Float = index - 200_000f

        fun JsonObject.memoInt(key: String): Int? = this[key]?.jsonPrimitive?.intOrNull

        fun JsonObject.memoString(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

        private fun KavitaVolumeDto.isLooseLeaf(): Boolean =
            volumeNumber == KavitaConstants.LOOSE_LEAF_VOLUME_NUMBER || (minNumber == null && volumeNumber == 0f)

        private fun KavitaVolumeDto.displayNumber(): String =
            name.takeIf { it.isNotBlank() && it != "0" } ?: formatNumber(volumeNumber)

        private fun KavitaChapterDto.isWholeVolume(): Boolean =
            chapterNumber == KavitaConstants.DEFAULT_CHAPTER_NUMBER || (minNumber == null && number == "0")

        private fun KavitaChapterDto.displayTitle(): String? =
            listOf(titleName, title, range).firstOrNull { !it.isNullOrBlank() }

        private fun List<KavitaNamedDto>.labels(): String? =
            mapNotNull { it.label }.distinct().joinToString().takeIf { it.isNotEmpty() }

        private fun formatNumber(value: Float): String =
            if (value % 1f == 0f) value.toLong().toString() else value.toString()

        /** Kavita sends local times without an offset; a year of 1 means "not set". */
        private fun parseDate(value: String?): Long? {
            if (value.isNullOrBlank() || value.startsWith("0001")) return null
            return runCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
                .recoverCatching {
                    LocalDateTime.parse(value.substringBefore('Z'))
                        .atZone(ZoneId.systemDefault())
                        .toInstant()
                        .toEpochMilli()
                }
                .getOrNull()
        }
    }
}
