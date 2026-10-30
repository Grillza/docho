package mihonka.komga

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.POST
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.jsonMime
import eu.kanade.tachiyomi.network.parseAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mihonka.koreader.KoreaderHash
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException

/**
 * Talks to the configured Komga server. Komga accepts an API key in the `X-API-Key` header on
 * every request, so there is no session to keep: [client] adds the key (and Mihonka's user
 * agent) to each request for the server, page images and covers included.
 */
@Inject
@SingleIn(AppScope::class)
class KomgaApi(
    private val preferences: KomgaPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    val client: OkHttpClient by lazy {
        network.client.newBuilder()
            .addInterceptor(AuthInterceptor())
            .build()
    }

    /** `https://host[:port][/subpath]/api`, or `null` while no server is configured. */
    fun apiUrlOrNull(): String? = normalizeApiUrl(preferences.serverUrl.get())

    fun apiUrl(): String = apiUrlOrNull() ?: throw KomgaNotConfiguredException()

    private val mutableConnection = MutableStateFlow<KomgaConnection>(KomgaConnection.Unknown)

    /** Outcome of the latest check, shown as the status light in settings. */
    val connection: StateFlow<KomgaConnection> = mutableConnection.asStateFlow()

    /** Asks the server who the key belongs to and publishes the outcome to [connection]. */
    suspend fun checkConnection(): KomgaConnection {
        val serverUrl = preferences.serverUrl.get()
        val apiKey = preferences.apiKey.get()
        if (serverUrl.isBlank() || apiKey.isBlank()) {
            return KomgaConnection.Unknown.also { mutableConnection.value = it }
        }
        mutableConnection.value = KomgaConnection.Checking
        val result = try {
            val apiUrl = normalizeApiUrl(serverUrl) ?: throw IOException("Invalid server address")
            val user = client.newCall(GET("$apiUrl/v2/users/me")).await().use {
                if (it.code == 401) throw KomgaAuthException()
                if (!it.isSuccessful) throw IOException("HTTP ${it.code}")
                with(json) { it.parseAs<KomgaUserDto>() }
            }
            KomgaConnection.Connected(user.email)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            KomgaConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        // Settings may have changed while checking; only the latest check counts.
        if (serverUrl == preferences.serverUrl.get() && apiKey == preferences.apiKey.get()) {
            mutableConnection.value = result
        }
        return result
    }

    suspend fun getLibraries(): List<KomgaLibraryDto> = get("${apiUrl()}/v1/libraries")

    /** One page of series, `page` counting from 0. */
    suspend fun getSeriesPage(
        page: Int,
        query: String?,
        sort: String,
        libraryId: String?,
        unreadOnly: Boolean = false,
    ): KomgaPageDto<KomgaSeriesDto> {
        val url = "${apiUrl()}/v1/series/list".toHttpUrl().newBuilder()
            .addQueryParameter("page", page.toString())
            .addQueryParameter("size", PAGE_SIZE.toString())
            .addQueryParameter("sort", sort)
            .build()
        return post(url.toString(), seriesSearch(query, libraryId, unreadOnly))
    }

    /** Every book of a series, in Komga's reading order. */
    suspend fun getSeriesBooks(seriesId: String): List<KomgaBookDto> {
        val url = "${apiUrl()}/v1/books/list".toHttpUrl().newBuilder()
            .addQueryParameter("unpaged", "true")
            .addQueryParameter("sort", "metadata.numberSort,asc")
            .build()
        val search = buildJsonObject {
            put("condition", allOf(listOf(isCondition("seriesId", seriesId), notDeleted())))
        }
        return post<KomgaPageDto<KomgaBookDto>>(url.toString(), search).content
    }

    suspend fun getSeries(seriesId: String): KomgaSeriesDto = get("${apiUrl()}/v1/series/$seriesId")

    suspend fun getBook(bookId: String): KomgaBookDto = get("${apiUrl()}/v1/books/$bookId")

    suspend fun getPages(bookId: String): List<KomgaPageInfoDto> = get("${apiUrl()}/v1/books/$bookId/pages")

    /** Moves the book to [page] (1-based); Komga marks it finished when that is the last page. */
    suspend fun saveProgress(bookId: String, page: Int) =
        patchProgress(bookId, KomgaReadProgressUpdateDto(page = page))

    suspend fun markRead(bookId: String) = patchProgress(bookId, KomgaReadProgressUpdateDto(completed = true))

    suspend fun markUnread(bookId: String) {
        val request = Request.Builder().url("${apiUrl()}/v1/books/$bookId/read-progress").delete().build()
        client.newCall(request).awaitSuccess().close()
    }

    private suspend fun patchProgress(bookId: String, update: KomgaReadProgressUpdateDto) {
        val body = json.encodeToString(update).toRequestBody(jsonMime)
        val request = Request.Builder().url("${apiUrl()}/v1/books/$bookId/read-progress").patch(body).build()
        client.newCall(request).awaitSuccess().close()
    }

    /**
     * KOReader's hash of a book's file. Komga only sends whole files, so this downloads the book
     * up to the last sample KOReader takes (most of the file) and keeps none of it.
     */
    suspend fun koreaderHash(bookId: String): String = withContext(Dispatchers.IO) {
        client.newCall(GET("${apiUrl()}/v1/books/$bookId/file")).awaitSuccess().use { response ->
            val size = response.body.contentLength().takeIf { it >= 0 }
            KoreaderHash.compute(response.body.byteStream(), size)
        }
    }

    fun seriesThumbnailUrl(seriesId: String): String = "${apiUrl()}/v1/series/$seriesId/thumbnail"

    fun pageImageUrl(bookId: String, page: Int): String = "${apiUrl()}/v1/books/$bookId/pages/$page"

    /** Address of the series in Komga's own web UI. */
    fun seriesWebUrl(seriesId: String): String = "${apiUrl().removeSuffix(API_PATH)}/series/$seriesId"

    fun bookWebUrl(bookId: String): String = "${apiUrl().removeSuffix(API_PATH)}/book/$bookId"

    private suspend inline fun <reified T> get(url: String): T =
        client.newCall(GET(url)).awaitSuccess().use { with(json) { it.parseAs<T>() } }

    private suspend inline fun <reified T> post(url: String, body: JsonObject): T =
        client.newCall(POST(url, body = body.toString().toRequestBody(jsonMime)))
            .awaitSuccess()
            .use { with(json) { it.parseAs<T>() } }

    private inner class AuthInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val original = chain.request()
            val apiUrl = apiUrlOrNull()
            val apiKey = preferences.apiKey.get()
            if (apiUrl == null || apiKey.isBlank() || !original.url.toString().startsWith(apiUrl, ignoreCase = true)) {
                return chain.proceed(original)
            }
            val response = chain.proceed(
                original.newBuilder()
                    .header("X-API-Key", apiKey)
                    .header("User-Agent", USER_AGENT)
                    .build(),
            )
            if (response.code == 401) {
                mutableConnection.value = KomgaConnection.Failed(KomgaAuthException().message!!)
            }
            return response
        }
    }

    companion object {
        const val PAGE_SIZE = 50
        private const val API_PATH = "/api"
        private val USER_AGENT = "Doki v${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})"

        /** Accepts a bare host, a URL with or without a trailing slash, or one that already has `/api/…`. */
        fun normalizeApiUrl(input: String): String? {
            var value = input.trim().trimEnd('/')
            if (value.isEmpty()) return null
            if (!value.startsWith("http://", ignoreCase = true) && !value.startsWith("https://", ignoreCase = true)) {
                value = "http://$value"
            }
            val apiIndex = value.indexOf("/api", ignoreCase = true)
            val base = if (apiIndex >= 0) value.substring(0, apiIndex) else value
            return "$base$API_PATH".takeIf { it.toHttpUrlOrNull() != null }
        }

        /**
         * Komga's series search: a condition tree plus an optional full-text search. Deleted
         * series are always left out, as Komga's own UI does.
         */
        fun seriesSearch(query: String?, libraryId: String?, unreadOnly: Boolean): JsonObject {
            val conditions = buildList {
                add(notDeleted())
                if (libraryId != null) add(isCondition("libraryId", libraryId))
                if (unreadOnly) {
                    add(
                        buildJsonObject {
                            put(
                                "anyOf",
                                buildJsonArray {
                                    add(isCondition("readStatus", "UNREAD"))
                                    add(isCondition("readStatus", "IN_PROGRESS"))
                                },
                            )
                        },
                    )
                }
            }
            return buildJsonObject {
                put("condition", allOf(conditions))
                if (!query.isNullOrBlank()) put("fullTextSearch", query.trim())
            }
        }

        private fun allOf(conditions: List<JsonObject>) = buildJsonObject {
            put("allOf", JsonArray(conditions))
        }

        private fun isCondition(field: String, value: String) = buildJsonObject {
            put(
                field,
                buildJsonObject {
                    put("operator", "is")
                    put("value", value)
                },
            )
        }

        private fun notDeleted() = buildJsonObject {
            put("deleted", buildJsonObject { put("operator", "isFalse") })
        }
    }
}

class KomgaNotConfiguredException :
    IOException("Komga is not set up. Add your server in Settings → Sync.")

class KomgaAuthException : IOException("Komga rejected the API key.")

sealed interface KomgaConnection {
    /** No server configured, or not checked yet. */
    data object Unknown : KomgaConnection

    data object Checking : KomgaConnection

    data class Connected(val username: String) : KomgaConnection

    data class Failed(val reason: String) : KomgaConnection
}
