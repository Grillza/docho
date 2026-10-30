package docho.kavita

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.POST
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.jsonMime
import eu.kanade.tachiyomi.network.parseAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException

/**
 * Talks to the configured Kavita server. Authentication is the plugin flow Kavita offers for
 * third-party readers: the API key is exchanged for a JWT, which [client] attaches to every
 * request for the server and renews once when the server answers 401.
 */
@Inject
@SingleIn(AppScope::class)
class KavitaApi(
    private val preferences: KavitaPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    /**
     * Request bodies must carry every field: the shared [json] omits defaults, and Kavita reads a
     * missing filter `combination` as "or", which would turn a search into "everything".
     */
    private val requestJson = Json(json) { encodeDefaults = true }

    private data class Session(val apiUrl: String, val apiKey: String, val token: String)

    @Volatile
    private var session: Session? = null
    private val sessionLock = Any()

    val client: OkHttpClient by lazy {
        network.client.newBuilder()
            .addInterceptor(AuthInterceptor())
            .build()
    }

    /** `https://host[:port][/subpath]/api`, or `null` while no server is configured. */
    fun apiUrlOrNull(): String? = normalizeApiUrl(preferences.serverUrl.get())

    fun apiUrl(): String = apiUrlOrNull() ?: throw KavitaNotConfiguredException()

    private val mutableConnection = MutableStateFlow<KavitaConnection>(KavitaConnection.Unknown)

    /** Outcome of the latest sign-in, shown as the status light in settings. */
    val connection: StateFlow<KavitaConnection> = mutableConnection.asStateFlow()

    /** Signs in with the saved settings and publishes the outcome to [connection]. */
    suspend fun checkConnection(): KavitaConnection {
        val serverUrl = preferences.serverUrl.get()
        val apiKey = preferences.apiKey.get()
        if (serverUrl.isBlank() || apiKey.isBlank()) {
            return KavitaConnection.Unknown.also { mutableConnection.value = it }
        }
        mutableConnection.value = KavitaConnection.Checking
        val result = try {
            val apiUrl = normalizeApiUrl(serverUrl) ?: throw IOException("Invalid server address")
            val response = network.client.newCall(authenticateRequest(apiUrl, apiKey)).await()
            val user = response.use {
                if (it.code == 401) throw KavitaAuthException()
                if (!it.isSuccessful) throw IOException("HTTP ${it.code}")
                with(json) { it.parseAs<KavitaUserDto>() }
            }
            synchronized(sessionLock) { session = Session(apiUrl, apiKey, user.token) }
            KavitaConnection.Connected(user.username, user.kavitaVersion)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            KavitaConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        // Settings may have changed while signing in; only the latest check counts.
        if (serverUrl == preferences.serverUrl.get() && apiKey == preferences.apiKey.get()) {
            mutableConnection.value = result
        }
        return result
    }

    suspend fun getLibraries(): List<KavitaLibraryDto> =
        get("${apiUrl()}/Library/libraries")

    suspend fun getSeriesPage(
        filter: KavitaFilterDto,
        page: Int,
        pageSize: Int = PAGE_SIZE,
    ): Pair<List<KavitaSeriesDto>, Boolean> {
        val request = POST(
            "${apiUrl()}/Series/all-v2?pageNumber=$page&pageSize=$pageSize",
            body = requestJson.encodeToString(filter).toRequestBody(jsonMime),
        )
        return client.newCall(request).awaitSuccess().use { response ->
            val series = with(json) { response.parseAs<List<KavitaSeriesDto>>() }
            val pagination = response.header("Pagination")
                ?.let { runCatching { json.decodeFromString<KavitaPaginationDto>(it) }.getOrNull() }
            val hasNext = pagination?.let { it.currentPage < it.totalPages } ?: (series.size >= pageSize)
            series to hasNext
        }
    }

    suspend fun getSeries(seriesId: Int): KavitaSeriesDto =
        get("${apiUrl()}/Series/$seriesId")

    suspend fun getSeriesMetadata(seriesId: Int): KavitaSeriesMetadataDto =
        get("${apiUrl()}/Series/metadata?seriesId=$seriesId")

    suspend fun getVolumes(seriesId: Int): List<KavitaVolumeDto> =
        get("${apiUrl()}/Series/volumes?seriesId=$seriesId")

    suspend fun getChapter(chapterId: Int): KavitaChapterDto =
        get("${apiUrl()}/Chapter?chapterId=$chapterId")

    /** Page the server has for one chapter; `pages` means read. Servers without the endpoint fall back to [getVolumes]. */
    suspend fun getPagesRead(seriesId: Int, chapterId: Int): Int {
        return try {
            get<KavitaReadPositionDto>("${apiUrl()}/Reader/get-progress?chapterId=$chapterId").pageNum
        } catch (e: HttpException) {
            if (e.code != 404) throw e
            getVolumes(seriesId).flatMap { it.chapters }.find { it.id == chapterId }?.pagesRead ?: 0
        }
    }

    suspend fun saveProgress(progress: KavitaProgressDto) {
        val request = POST(
            "${apiUrl()}/Reader/progress",
            body = requestJson.encodeToString(progress).toRequestBody(jsonMime),
        )
        client.newCall(request).awaitSuccess().close()
    }

    /** Marks whole chapters read (`read = true`) or unread in one request. */
    suspend fun setChaptersRead(seriesId: Int, chapterIds: List<Int>, read: Boolean) {
        val body = requestJson.encodeToString(KavitaMarkChaptersDto(seriesId, emptyList(), chapterIds))
        val endpoint = if (read) "mark-multiple-read" else "mark-multiple-unread"
        client.newCall(POST("${apiUrl()}/Reader/$endpoint", body = body.toRequestBody(jsonMime)))
            .awaitSuccess()
            .close()
    }

    /**
     * Reads part of a chapter's file through a ranged request to the download endpoint, so
     * KOReader's partial MD5 can be computed without downloading the file. Only works for
     * single-file chapters, which Kavita serves as is, and for accounts allowed to download.
     */
    suspend fun readFileRange(chapterId: Int, offset: Long, length: Int): KavitaFileRange {
        val request = Request.Builder()
            .url("${apiUrl()}/Download/chapter?chapterId=$chapterId")
            .header("Range", "bytes=$offset-${offset + length - 1}")
            .build()
        return client.newCall(request).awaitSuccess().use { response ->
            // A server that ignores the range would send the whole file.
            if (response.code != 206) {
                throw IOException("Kavita did not honour a ranged download (HTTP ${response.code})")
            }
            val totalSize = response.header("Content-Range")?.substringAfterLast('/')?.toLongOrNull()
                ?: throw IOException("Kavita sent no file size")
            KavitaFileRange(response.body.bytes(), totalSize)
        }
    }

    fun seriesCoverUrl(seriesId: Int): String = "${apiUrl()}/Image/series-cover?seriesId=$seriesId"

    fun pageImageUrl(chapterId: Int, page: Int): String =
        "${apiUrl()}/Reader/image?chapterId=$chapterId&page=$page&extractPdf=true"

    /** Address of the series in Kavita's own web UI. */
    fun seriesWebUrl(libraryId: Int, seriesId: Int): String =
        "${apiUrl().removeSuffix("/api")}/library/$libraryId/series/$seriesId"

    private suspend inline fun <reified T> get(url: String): T =
        client.newCall(GET(url)).awaitSuccess().use { with(json) { it.parseAs<T>() } }

    private fun authenticateRequest(apiUrl: String, apiKey: String): Request {
        val url = "$apiUrl/Plugin/authenticate".toHttpUrl().newBuilder()
            .addQueryParameter("apiKey", apiKey)
            .addQueryParameter("pluginName", PLUGIN_NAME)
            .build()
        return Request.Builder()
            .url(url)
            .post("{}".toRequestBody(jsonMime))
            .header("User-Agent", USER_AGENT)
            .build()
    }

    /** Returns a valid token for the current settings, signing in again when they changed. */
    private fun token(chain: Interceptor.Chain, apiUrl: String, apiKey: String, forceRefresh: Boolean): String {
        synchronized(sessionLock) {
            val current = session
            if (!forceRefresh && current != null && current.apiUrl == apiUrl && current.apiKey == apiKey) {
                return current.token
            }
            val response = chain.proceed(authenticateRequest(apiUrl, apiKey))
            val user = response.use {
                if (it.code == 401) {
                    mutableConnection.value = KavitaConnection.Failed(KavitaAuthException().message!!)
                    throw KavitaAuthException()
                }
                if (!it.isSuccessful) throw IOException("Kavita sign-in failed (HTTP ${it.code})")
                with(json) { it.parseAs<KavitaUserDto>() }
            }
            session = Session(apiUrl, apiKey, user.token)
            mutableConnection.value = KavitaConnection.Connected(user.username, user.kavitaVersion)
            return user.token
        }
    }

    private inner class AuthInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val original = chain.request()
            val apiUrl = apiUrlOrNull()
            val apiKey = preferences.apiKey.get()
            if (apiUrl == null || apiKey.isBlank() || !original.url.toString().startsWith(apiUrl, ignoreCase = true)) {
                return chain.proceed(original)
            }

            val withKey = original.url.newBuilder().apply {
                // Kavita's image endpoints authenticate with an apiKey query parameter rather than
                // the bearer token, because its web UI loads them through <img> tags.
                if (original.url.encodedPath.contains("/image", ignoreCase = true) &&
                    original.url.queryParameter("apiKey") == null
                ) {
                    addQueryParameter("apiKey", apiKey)
                }
            }.build()

            fun authorized(token: String) = original.newBuilder()
                .url(withKey)
                .header("Authorization", "Bearer $token")
                .header("User-Agent", USER_AGENT)
                .build()

            val response = chain.proceed(authorized(token(chain, apiUrl, apiKey, forceRefresh = false)))
            if (response.code != 401) return response

            response.close()
            return chain.proceed(authorized(token(chain, apiUrl, apiKey, forceRefresh = true)))
        }
    }

    companion object {
        const val PAGE_SIZE = 30
        private const val PLUGIN_NAME = "Docho"
        private val USER_AGENT = "Docho v${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})"

        /**
         * Accepts what people paste: a bare host, a URL with or without a trailing slash, or a link
         * that already contains `/api/…` (such as Kavita's OPDS URL).
         */
        fun normalizeApiUrl(input: String): String? {
            var value = input.trim().trimEnd('/')
            if (value.isEmpty()) return null
            if (!value.startsWith("http://", ignoreCase = true) && !value.startsWith("https://", ignoreCase = true)) {
                value = "http://$value"
            }
            val apiIndex = value.indexOf("/api", ignoreCase = true)
            val base = if (apiIndex >= 0) value.substring(0, apiIndex) else value
            return "$base/api".takeIf { it.toHttpUrlOrNull() != null }
        }
    }
}

class KavitaFileRange(val data: ByteArray, val totalSize: Long)

class KavitaNotConfiguredException : IOException("Kavita is not set up. Add your server in Settings → Kavita.")

class KavitaAuthException : IOException("Kavita rejected the API key.")

sealed interface KavitaConnection {
    /** No server configured, or not checked yet. */
    data object Unknown : KavitaConnection

    data object Checking : KavitaConnection

    data class Connected(val username: String, val version: String?) : KavitaConnection

    data class Failed(val reason: String) : KavitaConnection
}
