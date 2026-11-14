package docho.dochosync

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import docho.koreader.KoreaderApi
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.jsonMime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/** Talks to the Dōchō Sync built into Dōchō Server, through the server's own login (if it has one). */
@Inject
@SingleIn(AppScope::class)
class DochoSyncApi(
    private val preferences: DochoSyncPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    private val mutableConnection = MutableStateFlow<DochoSyncConnection>(DochoSyncConnection.Unknown)

    /** Outcome of the latest check, shown in settings. */
    val connection: StateFlow<DochoSyncConnection> = mutableConnection.asStateFlow()

    /** Whether the server at an address has Dōchō Sync (a Dōchō Server, not a plain Suwayomi). */
    private val probed = java.util.concurrent.ConcurrentHashMap<String, Boolean>()

    private fun base(): String? = KoreaderApi.normalizeBaseUrl(preferences.serverUrl())?.let { "$it/api/docho/sync/v1" }

    /** Whether the configured server is a Dōchō Server; asked once per address (and again on a check). */
    suspend fun isDochoServer(): Boolean {
        val base = base() ?: return false
        probed[base]?.let { return it }
        val result = try {
            val request = Request.Builder().url("$base/health").header("User-Agent", USER_AGENT).build()
            network.client.newCall(request).await().use { response ->
                response.isSuccessful &&
                    runCatching { json.parseToJsonElement(response.body.string()).jsonObject["name"] }.getOrNull() != null
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            // Unreachable: don't remember a guess; the request after this reports the error.
            return false
        }
        probed[base] = result
        return result
    }

    /** Checks the server has Dōchō Sync and lets this device in. */
    suspend fun checkConnection(): DochoSyncConnection {
        if (!preferences.isConfigured()) return DochoSyncConnection.Unknown.also { mutableConnection.value = it }
        mutableConnection.value = DochoSyncConnection.Checking
        base()?.let { probed.remove(it) }
        val result = try {
            if (!isDochoServer()) throw IOException(NOT_DOCHO_SERVER)
            val me = call(request("me").build())
            DochoSyncConnection.Connected(me["username"]?.jsonPrimitive?.contentOrNull.orEmpty())
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            DochoSyncConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        mutableConnection.value = result
        return result
    }

    /** Sends [changes] and returns what changed on the server after [since], one page of it. */
    suspend fun sync(since: Long, changes: List<SyncRecord>): SyncPage {
        if (!isDochoServer()) throw IOException(NOT_DOCHO_SERVER)
        val body = buildJsonObject {
            put("since", since)
            put("device", preferences.deviceId())
            put("changes", kotlinx.serialization.json.JsonArray(changes.map { it.toJson() }))
        }
        val response = call(request("sync").post(body.toString().toRequestBody(jsonMime)).build())
        return json.decodeFromJsonElement(SyncPage.serializer(), response)
    }

    private fun request(path: String): Request.Builder {
        val base = base() ?: throw IOException("No server address")
        return Request.Builder()
            .url("$base/$path")
            .header("User-Agent", USER_AGENT)
            .apply {
                // The server's own login, as for its sources (basic authentication).
                if (preferences.username().isNotBlank()) {
                    header("Authorization", okhttp3.Credentials.basic(preferences.username(), preferences.password()))
                }
            }
    }

    private suspend fun call(request: Request): JsonObject {
        network.client.newCall(request).await().use { response ->
            val text = response.body.string()
            val body = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            if (response.isSuccessful && body != null) return body
            if (response.code == 401) throw DochoSyncAuthException(WRONG_LOGIN)
            val message = body?.get("error")?.jsonPrimitive?.contentOrNull ?: "HTTP ${response.code}"
            throw IOException(message)
        }
    }

    companion object {
        private val USER_AGENT = "Docho v${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})"
        private const val NOT_DOCHO_SERVER = "This server has no Dōchō Sync. Update it to Dōchō Server to sync."
        private const val WRONG_LOGIN = "The server's username or password is wrong (Dōchō Server / Suwayomi)"
    }
}

class DochoSyncAuthException(message: String) : IOException(message)

sealed interface DochoSyncConnection {
    data object Unknown : DochoSyncConnection
    data object Checking : DochoSyncConnection
    data class Connected(val username: String) : DochoSyncConnection
    data class Failed(val reason: String) : DochoSyncConnection
}

/** One record as the server keeps it: [value] is null once deleted. */
@Serializable
data class SyncRecord(
    val kind: String,
    val key: String,
    val value: JsonElement? = null,
    val updatedAt: Long,
    val device: String? = null,
) {
    val isDeleted: Boolean get() = value == null || value is JsonNull

    fun toJson(): JsonObject = buildJsonObject {
        put("kind", kind)
        put("key", key)
        put("value", value ?: JsonNull)
        put("updatedAt", updatedAt)
    }
}

@Serializable
data class SyncPage(
    val accepted: Int = 0,
    val seq: Long,
    val more: Boolean = false,
    val changes: List<SyncRecord> = emptyList(),
    /**
     * Further progress on the server that this device's later change went back from (Dōchō Server
     * 0.32.9). Not asked about: going back here was on purpose. Kept so the response still reads.
     */
    val behind: List<SyncRecord> = emptyList(),
)
