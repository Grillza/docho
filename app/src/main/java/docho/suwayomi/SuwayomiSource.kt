package docho.suwayomi

import android.os.Looper
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import logcat.LogPriority
import okhttp3.OkHttpClient
import tachiyomi.core.common.util.system.logcat

/**
 * One of the Suwayomi server's sources (an extension installed there), browsed and read through
 * the server. It keeps the extension's own source id and URLs, so its series are the same as
 * those of the extension on the device, which takes its place when both are installed.
 */
class SuwayomiSource(
    val info: SuwayomiSourceInfo,
    private val api: SuwayomiApi,
    private val scope: CoroutineScope,
) : HttpSource() {

    override val id: Long = info.id

    override val name: String = info.name

    override val lang: String = info.lang

    override val supportsLatest: Boolean = info.supportsLatest

    override val baseUrl: String
        get() = api.baseUrlOrNull().orEmpty()

    override val client: OkHttpClient
        get() = api.client

    @Volatile
    private var filters: JsonArray? = null

    // Browse

    override suspend fun getPopularManga(page: Int): MangasPage = api.fetchSourceManga(id, "POPULAR", page)

    override suspend fun getLatestUpdates(page: Int): MangasPage = api.fetchSourceManga(id, "LATEST", page)

    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
        val defaults = loadFilters()?.let(SuwayomiApi::toFilterList).orEmpty()
        return api.fetchSourceManga(id, "SEARCH", page, query, SuwayomiApi.filterChanges(filters, defaults))
    }

    /**
     * The filter sheet is built synchronously, so the filters are fetched on first use: waited
     * for off the main thread, or fetched in the background and shown next time on it.
     */
    override fun getFilterList(): FilterList {
        filters?.let { return SuwayomiApi.toFilterList(it) }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            scope.launch { loadFilters() }
            return FilterList()
        }
        return runBlocking { withTimeoutOrNull(FILTER_TIMEOUT_MS) { loadFilters() } }
            ?.let(SuwayomiApi::toFilterList)
            ?: FilterList()
    }

    private suspend fun loadFilters(): JsonArray? {
        filters?.let { return it }
        return try {
            api.getFilters(id).also { filters = it }
        } catch (e: Exception) {
            logcat(LogPriority.WARN, e) { "Could not load filters of $name from Suwayomi" }
            null
        }
    }

    // Details and chapters

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        val (details, chapterList) = api.fetchManga(id, manga, fetchDetails, fetchChapters)
        return SMangaUpdate(details, chapterList ?: chapters)
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> =
        api.getPages(chapter).mapIndexed { index, url -> Page(index, imageUrl = url) }

    override fun getMangaUrl(manga: SManga): String = api.realUrl(id, manga.url) ?: baseUrl

    override fun getChapterUrl(chapter: SChapter): String = baseUrl

    override fun toString(): String = "$name (${lang.uppercase()})"

    private companion object {
        const val FILTER_TIMEOUT_MS = 15_000L
    }
}
