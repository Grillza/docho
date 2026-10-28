package mihonka.koreader

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.jsonMime
import eu.kanade.tachiyomi.network.parseAs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.security.MessageDigest

/**
 * Talks to a KOReader sync server (the kosync protocol), such as BookOrbit's or KOReader's own.
 * Every request carries the username and the MD5 of the password, as KOReader sends them.
 */
@Inject
@SingleIn(AppScope::class)
class KoreaderApi(
    private val preferences: KoreaderPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    /** Bodies must carry every field; kosync servers reject a progress update missing one. */
    private val requestJson = Json(json) { encodeDefaults = true }

    private val mutableConnection = MutableStateFlow<KoreaderConnection>(KoreaderConnection.Unknown)

    /** Outcome of the latest sign-in, shown as the status light in settings. */
    val connection: StateFlow<KoreaderConnection> = mutableConnection.asStateFlow()

    /** Signs in with the saved settings and publishes the outcome to [connection]. */
    suspend fun checkConnection(): KoreaderConnection {
        val serverUrl = preferences.serverUrl.get()
        val username = preferences.username.get()
        val password = preferences.password.get()
        if (!preferences.isConfigured()) {
            return KoreaderConnection.Unknown.also { mutableConnection.value = it }
        }
        mutableConnection.value = KoreaderConnection.Checking
        val result = try {
            call(request("users/auth")).close()
            KoreaderConnection.Connected(username)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            KoreaderConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        // Settings may have changed while signing in; only the latest check counts.
        if (serverUrl == preferences.serverUrl.get() &&
            username == preferences.username.get() &&
            password == preferences.password.get()
        ) {
            mutableConnection.value = result
        }
        return result
    }

    /** The position the server has for a document, or `null` if it has none. */
    suspend fun getProgress(document: String): KoreaderProgressDto? {
        val progress = call(request("syncs/progress/$document")).use {
            with(json) { it.parseAs<KoreaderProgressDto>() }
        }
        return progress.takeIf { it.progress != null || it.percentage != null }
    }

    /** Throws [KoreaderUnknownDocumentException] when the server doesn't know the document. */
    suspend fun updateProgress(progress: KoreaderProgressDto) {
        val body = requestJson.encodeToString(progress).toRequestBody(jsonMime)
        call(request("syncs/progress").newBuilder().put(body).build()).close()
    }

    private fun request(path: String): Request {
        val baseUrl = normalizeBaseUrl(preferences.serverUrl.get()) ?: throw KoreaderNotConfiguredException()
        return Request.Builder()
            .url("$baseUrl/$path")
            .header("Accept", "application/vnd.koreader.v1+json")
            .header("x-auth-user", preferences.username.get())
            .header("x-auth-key", md5(preferences.password.get()))
            .header("User-Agent", USER_AGENT)
            .build()
    }

    private suspend fun call(request: Request): Response {
        val response = network.client.newCall(request).await()
        if (response.isSuccessful) return response
        response.close()
        throw when (response.code) {
            401, 403 -> KoreaderAuthException().also {
                mutableConnection.value = KoreaderConnection.Failed(it.message!!)
            }
            404 -> if (request.method == "PUT") KoreaderUnknownDocumentException() else IOException("HTTP 404")
            else -> IOException("HTTP ${response.code}")
        }
    }

    companion object {
        private val USER_AGENT = "Mihonka v${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})"

        /** Accepts a bare host or a URL with or without a trailing slash. */
        fun normalizeBaseUrl(input: String): String? {
            var value = input.trim().trimEnd('/')
            if (value.isEmpty()) return null
            if (!value.startsWith("http://", ignoreCase = true) && !value.startsWith("https://", ignoreCase = true)) {
                value = "http://$value"
            }
            return value.takeIf { it.toHttpUrlOrNull() != null }
        }

        fun md5(value: String): String =
            MessageDigest.getInstance("MD5").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}

/**
 * A kosync position. For paged documents such as CBZ, [progress] is the 1-based page number and
 * [percentage] how far into the document that page is, from 0 to 1.
 */
@Serializable
data class KoreaderProgressDto(
    val document: String? = null,
    val progress: String? = null,
    val percentage: Double? = null,
    val device: String? = null,
    @SerialName("device_id")
    val deviceId: String? = null,
)

class KoreaderNotConfiguredException :
    IOException("KOReader sync is not set up. Add your server in Settings → KOReader sync.")

class KoreaderAuthException : IOException("The sync server rejected the username or password.")

/** Raised for a document the server has no book for, such as a series missing from BookOrbit. */
class KoreaderUnknownDocumentException : IOException("The sync server doesn't have this file.")

sealed interface KoreaderConnection {
    /** No server configured, or not checked yet. */
    data object Unknown : KoreaderConnection

    data object Checking : KoreaderConnection

    data class Connected(val username: String) : KoreaderConnection

    data class Failed(val reason: String) : KoreaderConnection
}
