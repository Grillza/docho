package docho.dochosync

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.math.BigDecimal

/**
 * The records Dōchō Sync keeps, as both apps write them. Keys are "sourceId|url", values JSON
 * objects. They're compared as [canonical] text, so both apps must build them the same way:
 * fractional numbers go as strings like "119.1", since the two platforms print doubles differently.
 */
object SyncValues {
    const val MANGA = "manga"
    const val CATEGORY = "category"
    const val CHAPTER = "chapter"
    const val HISTORY = "history"
    const val RENAME = "rename"
    const val KIND = "kind"

    /** A series' edited details (SeriesEdits): only the edited fields, blank ones as "". */
    const val DETAILS = "details"

    /** What the tracker fill remembers about a series (TrackerFillMemory). */
    const val FILL = "fill"

    fun key(sourceId: Long, url: String) = "$sourceId|$url"

    /** The source id and url in a [key], or null if it isn't one. */
    fun parseKey(key: String): Pair<Long, String>? {
        val bar = key.indexOf('|')
        if (bar <= 0) return null
        return key.substring(0, bar).toLongOrNull()?.let { it to key.substring(bar + 1) }
    }

    fun manga(title: String, categories: Collection<String>, addedAt: Long) = obj(
        "addedAt" to JsonPrimitive(addedAt),
        "categories" to JsonArray(categories.distinct().sorted().map(::JsonPrimitive)),
        "title" to JsonPrimitive(title),
    )

    fun category() = JsonObject(emptyMap())

    /**
     * A chapter's progress. [at] is when it last changed on the device that read it (epoch ms), left
     * out where that isn't known (progress from before 0.32.9, or from an older app).
     */
    fun chapter(mangaUrl: String, read: Boolean, bookmark: Boolean, page: Long, at: Long? = null) = JsonObject(
        buildMap {
            if (at != null && at > 0) put("at", JsonPrimitive(at))
            put("bookmark", JsonPrimitive(bookmark))
            put("manga", JsonPrimitive(mangaUrl))
            put("page", JsonPrimitive(if (read) 0 else page))
            put("read", JsonPrimitive(read))
        },
    )

    fun history(mangaUrl: String, readAt: Long) = obj(
        "manga" to JsonPrimitive(mangaUrl),
        "readAt" to JsonPrimitive(readAt),
    )

    fun rename(name: String, number: Double, original: String?, at: Long, mangaUrl: String?) = obj(
        "at" to JsonPrimitive(at),
        "manga" to (mangaUrl?.let(::JsonPrimitive) ?: JsonNull),
        "name" to JsonPrimitive(name),
        "number" to JsonPrimitive(number(number)),
        "original" to (original?.let(::JsonPrimitive) ?: JsonNull),
    )

    fun kind(kind: String, mangaUrl: String?) = obj(
        "kind" to JsonPrimitive(kind),
        "manga" to (mangaUrl?.let(::JsonPrimitive) ?: JsonNull),
    )

    /** "10" or "119.1": the shortest plain decimal, the same on both apps. */
    fun number(value: Double): String =
        if (value == Math.rint(value) && kotlin.math.abs(value) < 1e15) {
            value.toLong().toString()
        } else {
            BigDecimal.valueOf(value).stripTrailingZeros().toPlainString()
        }

    /** [value] with object keys sorted and nulls dropped, as text, for comparing records. */
    fun canonical(value: JsonElement?): String = when (value) {
        null, JsonNull -> "null"
        is JsonObject ->
            value.entries
                .filter { it.value !is JsonNull }
                .sortedBy { it.key }
                .joinToString(",", "{", "}") { (k, v) -> JsonPrimitive(k).toString() + ":" + canonical(v) }
        is JsonArray -> value.joinToString(",", "[", "]") { canonical(it) }
        is JsonPrimitive -> when {
            value.isString -> value.toString()
            value.booleanOrNull != null -> value.booleanOrNull.toString()
            value.longOrNull != null -> value.longOrNull.toString()
            else -> value.toString()
        }
    }

    private fun obj(vararg entries: Pair<String, JsonElement>) = JsonObject(mapOf(*entries))

    fun JsonObject.string(name: String): String? = (get(name) as? JsonPrimitive)?.contentOrNull
    fun JsonObject.long(name: String): Long? = (get(name) as? JsonPrimitive)?.longOrNull
    fun JsonObject.bool(name: String): Boolean = (get(name) as? JsonPrimitive)?.booleanOrNull ?: false
    fun JsonObject.strings(name: String): List<String> =
        (get(name) as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()

    /** When a chapter record says its progress changed, if it does. */
    fun JsonObject.at(): Long? = long("at")?.takeIf { it > 0 }

    /**
     * Whether a change at [at] surely came after the other's: after the other's own time, or, where
     * that isn't known, after the other was stored on the server ([otherStored], which can't be
     * before it changed). Dōchō Server's `surelyAfter`.
     */
    fun surelyAfter(at: Long?, otherAt: Long?, otherStored: Long?): Boolean =
        at != null && if (otherAt != null) at > otherAt else otherStored != null && at > otherStored

    /**
     * A chapter's progress here and on the server put together; Dōchō Server's `mergeProgress`.
     * Where one surely changed after the other ([surelyAfter]) it wins whole, even going back.
     * Otherwise the furthest point is kept: read anywhere is read, the further page, the later
     * known time. The bookmark is then [remote]'s when [remoteBookmark], else bookmarked on either.
     */
    fun mergeChapter(
        local: JsonObject,
        remote: JsonObject,
        remoteBookmark: Boolean = false,
        localStored: Long? = null,
        remoteStored: Long? = null,
    ): JsonObject {
        if (surelyAfter(remote.at(), local.at(), localStored)) return remote
        if (surelyAfter(local.at(), remote.at(), remoteStored)) return local
        val read = local.bool("read") || remote.bool("read")
        return chapter(
            mangaUrl = remote.string("manga") ?: local.string("manga").orEmpty(),
            read = read,
            bookmark = if (remoteBookmark) remote.bool("bookmark") else local.bool("bookmark") || remote.bool("bookmark"),
            page = maxOf(local.long("page") ?: 0, remote.long("page") ?: 0),
            at = listOfNotNull(local.at(), remote.at()).maxOrNull(),
        )
    }

    /** Whether chapter progress [value] is behind [other]: unread where it's read, or on an earlier page. */
    fun isBehind(value: JsonObject, other: JsonObject): Boolean =
        !value.bool("read") && (other.bool("read") || (other.long("page") ?: 0) > (value.long("page") ?: 0))

    fun id(kind: String, key: String) = "$kind\t$key"
}

/**
 * What changed on this device since it last synced: records whose values differ from what was
 * synced, and deletions for records that are gone. Records still waiting to be applied here
 * ([pending]) aren't sent, so a chapter that hasn't arrived yet can't overwrite its state.
 */
fun syncChanges(
    current: Map<String, Pair<String, JsonElement>>,
    synced: Map<String, String>,
    pending: Set<String>,
    now: Long,
): List<SyncRecord> {
    val changes = mutableListOf<SyncRecord>()
    for ((id, entry) in current) {
        if (id in pending) continue
        val (kind, value) = entry
        if (synced[id] != SyncValues.canonical(value)) {
            changes += SyncRecord(kind, id.substringAfter('\t'), value, now)
        }
    }
    for (id in synced.keys) {
        if (id in current || id in pending) continue
        changes += SyncRecord(id.substringBefore('\t'), id.substringAfter('\t'), null, now)
    }
    return changes
}
