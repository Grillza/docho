package docho.edit

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore

/**
 * What the tracker fill remembers about each series: the status it last gave, and what the user
 * decided against. Shared with other devices and Dōchō Server as Dōchō Sync's "fill" records, so a
 * decision made anywhere holds everywhere; the newest one wins.
 */
@Inject
@SingleIn(AppScope::class)
class TrackerFillMemory(preferenceStore: PreferenceStore) {

    @Serializable
    data class Memory(
        val status: Long? = null,
        val ignored: Map<String, List<String>> = emptyMap(),
    )

    /** Keyed by "sourceId|url", as Dōchō Sync keys series. */
    val all: Preference<Map<String, Memory>> = preferenceStore.getObjectFromString(
        key = "tracker_fill_memory",
        defaultValue = emptyMap(),
        serializer = { Json.encodeToString(it) },
        deserializer = { runCatching { Json.decodeFromString<Map<String, Memory>>(it) }.getOrDefault(emptyMap()) },
    )

    fun get(key: String): Memory? = all.get()[key]

    fun put(key: String, memory: Memory?) {
        all.set(if (memory == null) all.get() - key else all.get() + (key to memory))
    }

    fun remember(key: String, filledStatus: Long?, ignore: Map<String, List<String>>) {
        val memory = get(key) ?: Memory()
        val ignored = memory.ignored.toMutableMap()
        ignore.forEach { (field, values) -> ignored[field] = (ignored[field].orEmpty() + values).distinct() }
        put(key, Memory(filledStatus ?: memory.status, ignored))
    }

    /** Asks again about everything that was kept or skipped. */
    fun forgetChoices() {
        all.set(all.get().mapValues { (_, memory) -> memory.copy(ignored = emptyMap()) })
    }

    companion object {
        fun toJson(memory: Memory) = JsonObject(
            buildMap {
                put(
                    "ignored",
                    JsonObject(
                        memory.ignored
                            .filterValues { it.isNotEmpty() }
                            .mapValues { (_, values) -> JsonArray(values.sorted().map(::JsonPrimitive)) },
                    ),
                )
                memory.status?.let { put("status", JsonPrimitive(it)) }
            },
        )

        fun fromJson(value: JsonObject) = Memory(
            status = (value["status"] as? JsonPrimitive)?.longOrNull,
            ignored = (value["ignored"] as? JsonObject).orEmpty().mapValues { (_, values) ->
                (values as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
            },
        )
    }
}
