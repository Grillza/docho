package docho.rename

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import tachiyomi.domain.chapter.model.Chapter

/**
 * Names and numbers the user gave chapters in Docho, and whether they said a chapter is a volume. Sources send their
 * own names again on every refresh, so these are kept apart and put back over them, see [applyTo].
 */
@Inject
@SingleIn(AppScope::class)
class ChapterRenames(
    preferenceStore: PreferenceStore,
) {

    /** [original] is the source's name before the user's first rename, and [at] when it was last renamed. */
    @Serializable
    data class Rename(val name: String, val number: Double, val original: String? = null, val at: Long = 0)

    /** Keyed by [key], so that a chapter is found again by its source and url. */
    val renames: Preference<Map<String, Rename>> = preferenceStore.getObjectFromString(
        key = "chapter_renames",
        defaultValue = emptyMap(),
        serializer = { Json.encodeToString(it) },
        deserializer = { runCatching { Json.decodeFromString<Map<String, Rename>>(it) }.getOrDefault(emptyMap()) },
    )

    /** [Chapter.KIND_VOLUME] or [Chapter.KIND_CHAPTER] for chapters the user said are one or the other. */
    val kinds: Preference<Map<String, String>> = preferenceStore.getObjectFromString(
        key = "chapter_kinds",
        defaultValue = emptyMap(),
        serializer = { Json.encodeToString(it) },
        deserializer = { runCatching { Json.decodeFromString<Map<String, String>>(it) }.getOrDefault(emptyMap()) },
    )

    /** What the user renamed the chapter at [url] to, if they did. */
    fun get(sourceId: Long, url: String): Rename? = renames.get()[key(sourceId, url)]

    /** Remembers [rename] for the chapter at [newUrl], which was at [oldUrl] before its file was renamed. */
    fun put(sourceId: Long, oldUrl: String, newUrl: String, rename: Rename) {
        renames.set(renames.get() - key(sourceId, oldUrl) + (key(sourceId, newUrl) to rename))
        moveKind(sourceId, oldUrl, newUrl)
    }

    /** Remembers whether the chapter at [url] is a volume or a chapter, as [Chapter.KIND_VOLUME] or similar. */
    fun putKind(sourceId: Long, url: String, kind: String) {
        kinds.set(kinds.get() + (key(sourceId, url) to kind))
    }

    private fun moveKind(sourceId: Long, oldUrl: String, newUrl: String) {
        if (oldUrl == newUrl) return
        val all = kinds.get()
        val kind = all[key(sourceId, oldUrl)] ?: return
        kinds.set(all - key(sourceId, oldUrl) + (key(sourceId, newUrl) to kind))
    }

    /** Puts the user's names, numbers and kinds over the ones [chapters] came with from the source. */
    fun applyTo(sourceId: Long, chapters: List<Chapter>): List<Chapter> {
        val allRenames = renames.get()
        val allKinds = kinds.get()
        if (allRenames.isEmpty() && allKinds.isEmpty()) return chapters
        return chapters.map { chapter ->
            val key = key(sourceId, chapter.url)
            var result = chapter
            allRenames[key]?.let { result = result.copy(name = it.name, chapterNumber = it.number) }
            allKinds[key]?.let { result = result.withKind(it) }
            result
        }
    }

    private fun key(sourceId: Long, url: String) = "$sourceId|$url"

    companion object {
        /** The chapter with its memo saying it's a volume or a chapter, whatever its name says. */
        fun Chapter.withKind(kind: String): Chapter =
            copy(memo = JsonObject(memo + (Chapter.MEMO_KIND to JsonPrimitive(kind))))
    }
}
