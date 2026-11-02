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

/** Talks to a Dōchō Sync server (`sync-server/` in this repository). */
@Inject
@SingleIn(AppScope::class)
class DochoSyncApi(
    private val preferences: DochoSyncPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    private val mutableConnection = MutableStateFlow<DochoSyncConnection>(DochoSyncConnection.Unknown)

    /** Outcome of the latest sign-in, shown as the status light in settings. */
    val connection: StateFlow<DochoSyncConnection> = mutableConnection.asStateFlow()

    /** Signs in with the saved settings, or creates the account first if [register]. */
    suspend fun signIn(register: Boolean = false): DochoSyncConnection {
        if (!preferences.isConfigured()) return DochoSyncConnection.Unknown.also { mutableConnection.value = it }
        mutableConnection.value = DochoSyncConnection.Checking
        val result = try {
            val body = buildJsonObject {
                put("username", preferences.username.get())
                put("password", preferences.password.get())
                put("device", preferences.deviceId())
            }
            val response = post(if (register) "register" else "login", body, authorized = false)
            preferences.token.set(response["token"]!!.jsonPrimitive.content)
            DochoSyncConnection.Connected(
                response["username"]?.jsonPrimitive?.contentOrNull ?: preferences.username.get(),
            )
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            DochoSyncConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        mutableConnection.value = result
        return result
    }

    /** Checks the saved sign-in still works, signing in again with the password if it doesn't. */
    suspend fun checkConnection(): DochoSyncConnection {
        if (!preferences.isConfigured()) return DochoSyncConnection.Unknown.also { mutableConnection.value = it }
        if (preferences.token.get().isBlank()) return signIn()
        mutableConnection.value = DochoSyncConnection.Checking
        val result = try {
            val me = call(request("me").build())
            DochoSyncConnection.Connected(me["username"]?.jsonPrimitive?.contentOrNull ?: preferences.username.get())
        } catch (e: DochoSyncAuthException) {
            return signIn()
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            DochoSyncConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        mutableConnection.value = result
        return result
    }

    /** Sends [changes] and returns what changed on the server after [since], one page of it. */
    suspend fun sync(since: Long, changes: List<SyncRecord>): SyncPage {
        val body = buildJsonObject {
            put("since", since)
            put("device", preferences.deviceId())
            put("changes", kotlinx.serialization.json.JsonArray(changes.map { it.toJson() }))
        }
        val response = try {
            post("sync", body, authorized = true)
        } catch (e: DochoSyncAuthException) {
            // The token was revoked or the server was reset: sign in again once
            if (signIn() !is DochoSyncConnection.Connected) throw e
            post("sync", body, authorized = true)
        }
        return json.decodeFromJsonElement(SyncPage.serializer(), response)
    }

    private suspend fun post(path: String, body: JsonObject, authorized: Boolean): JsonObject {
        val request = request(path, authorized).post(body.toString().toRequestBody(jsonMime)).build()
        return call(request)
    }

    private fun request(path: String, authorized: Boolean = true): Request.Builder {
        val base = KoreaderApi.normalizeBaseUrl(preferences.serverUrl.get()) ?: throw IOException("No server address")
        return Request.Builder()
            .url("$base/api/v1/$path")
            .header("User-Agent", USER_AGENT)
            .apply { if (authorized) header("Authorization", "Bearer ${preferences.token.get()}") }
    }

    private suspend fun call(request: Request): JsonObject {
        network.client.newCall(request).await().use { response ->
            val text = response.body.string()
            val body = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
            if (response.isSuccessful && body != null) return body
            val message = body?.get("error")?.jsonPrimitive?.contentOrNull ?: "HTTP ${response.code}"
            if (response.code == 401) throw DochoSyncAuthException(message)
            throw IOException(message)
        }
    }

    companion object {
        private val USER_AGENT = "Docho v${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})"
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
)
