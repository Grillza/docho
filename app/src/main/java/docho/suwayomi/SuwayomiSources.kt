package docho.suwayomi

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import logcat.LogPriority
import tachiyomi.core.common.util.system.logcat

/**
 * The sources the Suwayomi server offers, which come and go as extensions are installed there.
 * They are remembered between launches, so series from them open before the server answers.
 */
@Inject
@SingleIn(AppScope::class)
class SuwayomiSources(
    private val preferences: SuwayomiPreferences,
    private val api: SuwayomiApi,
    private val json: Json,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val infos = MutableStateFlow(readCache())

    /** The sources to offer: none while no server is set up, and NSFW ones only if allowed. */
    val sources: Flow<List<SuwayomiSource>> = combine(
        infos,
        preferences.serverUrl.changes(),
        preferences.showNsfw.changes(),
    ) { infos, _, showNsfw ->
        if (!preferences.isConfigured()) return@combine emptyList()
        infos.filter { showNsfw || !it.isNsfw }
    }
        .distinctUntilChanged()
        .map { list -> list.map { SuwayomiSource(it, api, scope) } }

    /** Ids of the server's sources currently in use, i.e. not replaced by an extension on the device. */
    @Volatile
    var activeIds: Set<Long> = emptySet()

    /** The icon of a server source in use, as a full URL. */
    fun iconUrl(sourceId: Long): String? {
        if (sourceId !in activeIds) return null
        val path = infos.value.firstOrNull { it.id == sourceId }?.iconPath?.takeIf { it.isNotBlank() } ?: return null
        return runCatching { api.absoluteUrl(path) }.getOrNull()
    }

    /** Asks the server for its sources; after setup, on launch, and when Browse is refreshed. */
    suspend fun refresh(): Boolean {
        if (!preferences.isConfigured()) {
            infos.value = emptyList()
            return false
        }
        return try {
            val list = api.getSources().sortedBy { it.name.lowercase() }
            infos.value = list
            preferences.sourcesCache.set(json.encodeToString(ListSerializer(SuwayomiSourceInfo.serializer()), list))
            true
        } catch (e: Exception) {
            logcat(LogPriority.WARN, e) { "Could not load sources from Suwayomi" }
            false
        }
    }

    /** After the server address changes: forget what the old one had. */
    fun clear() {
        infos.value = emptyList()
        preferences.sourcesCache.delete()
    }

    private fun readCache(): List<SuwayomiSourceInfo> = runCatching {
        val cached = preferences.sourcesCache.get()
        if (cached.isBlank()) {
            emptyList()
        } else {
            json.decodeFromString(
                ListSerializer(SuwayomiSourceInfo.serializer()),
                cached,
            )
        }
    }.getOrDefault(emptyList())
}
