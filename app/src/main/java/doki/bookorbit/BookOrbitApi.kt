package doki.bookorbit

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.POST
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
 * Talks to the configured BookOrbit server. It signs in the way BookOrbit's own iPhone app does,
 * as a "native" client: the password is exchanged for an access token, which [client] attaches
 * to every request, and a refresh token that renews it. The refresh token is saved, so the app
 * keeps one session on the account rather than starting a new one on every launch.
 */
@Inject
@SingleIn(AppScope::class)
class BookOrbitApi(
    private val preferences: BookOrbitPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    private val requestJson = Json(json) { encodeDefaults = true }

    /** The settings a token was issued for, so a token is never sent to a different account. */
    private data class Session(val apiUrl: String, val username: String, val accessToken: String)

    @Volatile
    private var session: Session? = null
    private val sessionLock = Any()

    val client: OkHttpClient by lazy {
        network.client.newBuilder()
            .addInterceptor(AuthInterceptor())
            .build()
    }

    /** `https://host[:port][/subpath]/api/v1`, or `null` while no server is configured. */
    fun apiUrlOrNull(): String? = normalizeApiUrl(preferences.serverUrl.get())

    fun apiUrl(): String = apiUrlOrNull() ?: throw BookOrbitNotConfiguredException()

    private val mutableConnection = MutableStateFlow<BookOrbitConnection>(BookOrbitConnection.Unknown)

    /** Outcome of the latest sign-in, shown as the status light in settings. */
    val connection: StateFlow<BookOrbitConnection> = mutableConnection.asStateFlow()

    /** Signs in with the saved settings and publishes the outcome to [connection]. */
    suspend fun checkConnection(): BookOrbitConnection {
        if (!preferences.isConfigured()) {
            return BookOrbitConnection.Unknown.also { mutableConnection.value = it }
        }
        val settings = currentSettings()
        mutableConnection.value = BookOrbitConnection.Checking
        val result = try {
            val user = get<BookOrbitUserDto>("${apiUrl()}/auth/me")
            BookOrbitConnection.Connected(user.username ?: preferences.username.get())
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            BookOrbitConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        // Settings may have changed while signing in; only the latest check counts.
        if (settings == currentSettings()) mutableConnection.value = result
        return result
    }

    private fun currentSettings() =
        listOf(preferences.serverUrl.get(), preferences.username.get(), preferences.password.get())

    suspend fun getLibraries(): List<BookOrbitLibraryDto> = get("${apiUrl()}/libraries")

    /** One page of series, `page` counting from 0. */
    suspend fun getSeriesPage(
        page: Int,
        query: String?,
        sort: String,
        ascending: Boolean,
        libraryId: Int?,
    ): BookOrbitSeriesPageDto {
        val url = "${apiUrl()}/series".toHttpUrl().newBuilder()
            .addQueryParameter("page", page.toString())
            .addQueryParameter("size", PAGE_SIZE.toString())
            .addQueryParameter("sort", sort)
            .addQueryParameter("order", if (ascending) "asc" else "desc")
            .apply {
                if (!query.isNullOrBlank()) addQueryParameter("q", query.trim())
                if (libraryId != null) addQueryParameter("libraryId", libraryId.toString())
            }
            .build()
        return get(url.toString())
    }

    /** Every book in a series, in series order, with the series' name and authors. */
    suspend fun getSeriesBooks(seriesId: Int): BookOrbitSeriesBooksPageDto {
        val books = mutableListOf<BookOrbitBookDto>()
        var info: BookOrbitSeriesInfoDto? = null
        var page = 0
        while (true) {
            val result = get<BookOrbitSeriesBooksPageDto>(
                "${apiUrl()}/series/$seriesId/books?page=$page&size=$BOOKS_PAGE_SIZE&sort=seriesIndex&order=asc",
            )
            books += result.items
            info = info ?: result.seriesInfo
            if (result.items.isEmpty() || books.size >= result.total) break
            page++
        }
        return BookOrbitSeriesBooksPageDto(books, books.size, info)
    }

    suspend fun getBook(bookId: Int): BookOrbitBookDetailDto = get("${apiUrl()}/books/$bookId")

    suspend fun getPageCount(fileId: Int): Int =
        get<BookOrbitPageCountDto>("${apiUrl()}/cbz/files/$fileId/pages").pageCount

    suspend fun getProgress(fileId: Int): BookOrbitProgressDto =
        get("${apiUrl()}/books/files/$fileId/progress")

    suspend fun saveProgress(fileId: Int, progress: BookOrbitProgressDto) {
        val body = requestJson.encodeToString(progress).toRequestBody(jsonMime)
        client.newCall(POST("${apiUrl()}/books/files/$fileId/progress", body = body)).awaitSuccess().close()
    }

    /** Marks a book unread: its position is cleared and its status set back. */
    suspend fun markUnread(bookId: Int, fileId: Int) {
        val clear = Request.Builder().url("${apiUrl()}/books/files/$fileId/progress").delete().build()
        client.newCall(clear).awaitSuccess().close()
        setStatus(bookId, BookOrbitBookDto.STATUS_UNREAD)
    }

    suspend fun setStatus(bookId: Int, status: String) {
        val body = requestJson.encodeToString(BookOrbitStatusDto(status)).toRequestBody(jsonMime)
        val request = Request.Builder().url("${apiUrl()}/books/$bookId/status").patch(body).build()
        client.newCall(request).awaitSuccess().close()
    }

    fun thumbnailUrl(bookId: Int): String = "${apiUrl()}/books/$bookId/thumbnail"

    fun pageImageUrl(fileId: Int, pageIndex: Int): String = "${apiUrl()}/cbz/files/$fileId/pages/$pageIndex"

    /** Address of the series in BookOrbit's own web UI. */
    fun seriesWebUrl(seriesId: Int): String = "${apiUrl().removeSuffix(API_PATH)}/series/$seriesId"

    private suspend inline fun <reified T> get(url: String): T =
        client.newCall(GET(url)).awaitSuccess().use { with(json) { it.parseAs<T>() } }

    /**
     * Returns an access token for the current settings: the one in memory, else one from the
     * saved refresh token, else a fresh sign-in with the password.
     */
    private fun accessToken(chain: Interceptor.Chain, apiUrl: String, forceRefresh: Boolean): String {
        synchronized(sessionLock) {
            val username = preferences.username.get()
            val current = session
            if (!forceRefresh && current != null && current.apiUrl == apiUrl && current.username == username) {
                return current.accessToken
            }

            val refreshToken = preferences.refreshToken.get().takeIf { current == null || current.apiUrl == apiUrl }
            val credentials = refreshToken?.takeIf { it.isNotBlank() }?.let { refresh(chain, apiUrl, it) }
                ?: signIn(chain, apiUrl, username)
            credentials.refreshToken?.let { preferences.refreshToken.set(it) }
            session = Session(apiUrl, username, credentials.accessToken)
            mutableConnection.value = BookOrbitConnection.Connected(username)
            return credentials.accessToken
        }
    }

    /** `null` when the refresh token is no longer accepted, so the caller signs in again. */
    private fun refresh(chain: Interceptor.Chain, apiUrl: String, refreshToken: String): BookOrbitCredentialsDto? {
        val body = requestJson.encodeToString(BookOrbitRefreshDto(refreshToken)).toRequestBody(jsonMime)
        val request = Request.Builder().url("$apiUrl/auth/refresh").post(body).header("User-Agent", USER_AGENT).build()
        return chain.proceed(request).use { response ->
            when {
                response.isSuccessful -> with(json) { response.parseAs<BookOrbitCredentialsDto>() }
                response.code == 400 || response.code == 401 -> null
                else -> throw IOException("BookOrbit sign-in failed (HTTP ${response.code})")
            }
        }
    }

    private fun signIn(chain: Interceptor.Chain, apiUrl: String, username: String): BookOrbitCredentialsDto {
        val login = BookOrbitLoginDto(
            username = username,
            password = preferences.password.get(),
            deviceLabel = DEVICE_LABEL,
        )
        val body = requestJson.encodeToString(login).toRequestBody(jsonMime)
        val request = Request.Builder().url("$apiUrl/auth/login").post(body).header("User-Agent", USER_AGENT).build()
        return chain.proceed(request).use { response ->
            when {
                response.isSuccessful -> with(json) { response.parseAs<BookOrbitCredentialsDto>() }
                response.code == 401 || response.code == 403 -> {
                    preferences.refreshToken.set("")
                    mutableConnection.value = BookOrbitConnection.Failed(BookOrbitAuthException().message!!)
                    throw BookOrbitAuthException()
                }
                response.code == 429 -> throw IOException("BookOrbit is limiting sign-ins; try again in a minute")
                else -> throw IOException("BookOrbit sign-in failed (HTTP ${response.code})")
            }
        }
    }

    /** Forgets the session, for when the server or account in settings changes. */
    fun signOut() {
        synchronized(sessionLock) {
            session = null
            preferences.refreshToken.set("")
        }
    }

    private inner class AuthInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val original = chain.request()
            val apiUrl = apiUrlOrNull()
            if (apiUrl == null || !preferences.isConfigured() ||
                !original.url.toString().startsWith(apiUrl, ignoreCase = true)
            ) {
                return chain.proceed(original)
            }

            fun authorized(token: String) = original.newBuilder()
                .header("Authorization", "Bearer $token")
                .header("User-Agent", USER_AGENT)
                .build()

            val response = chain.proceed(authorized(accessToken(chain, apiUrl, forceRefresh = false)))
            if (response.code != 401) return response

            response.close()
            return chain.proceed(authorized(accessToken(chain, apiUrl, forceRefresh = true)))
        }
    }

    companion object {
        const val PAGE_SIZE = 50
        private const val BOOKS_PAGE_SIZE = 100
        private const val API_PATH = "/api/v1"
        private const val DEVICE_LABEL = "Doki"
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
    }
}

class BookOrbitNotConfiguredException :
    IOException("BookOrbit is not set up. Add your server in Settings → Sync.")

class BookOrbitAuthException : IOException("BookOrbit rejected the username or password.")

sealed interface BookOrbitConnection {
    /** No server configured, or not checked yet. */
    data object Unknown : BookOrbitConnection

    data object Checking : BookOrbitConnection

    data class Connected(val username: String) : BookOrbitConnection

    data class Failed(val reason: String) : BookOrbitConnection
}
