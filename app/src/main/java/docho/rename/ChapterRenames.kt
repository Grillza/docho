package docho.rename

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import tachiyomi.domain.chapter.model.Chapter

/**
 * Names and numbers the user gave chapters in Docho. Sources send their own names again on every refresh, so these
 * are kept apart and put back over them, see [applyTo].
 */
@Inject
@SingleIn(AppScope::class)
class ChapterRenames(
    preferenceStore: PreferenceStore,
) {

    @Serializable
    data class Rename(val name: String, val number: Double)

    /** Keyed by [key], so that a chapter is found again by its source and url. */
    val renames: Preference<Map<String, Rename>> = preferenceStore.getObjectFromString(
        key = "chapter_renames",
        defaultValue = emptyMap(),
        serializer = { Json.encodeToString(it) },
        deserializer = { runCatching { Json.decodeFromString<Map<String, Rename>>(it) }.getOrDefault(emptyMap()) },
    )

    /** Remembers [rename] for the chapter at [newUrl], which was at [oldUrl] before its file was renamed. */
    fun put(sourceId: Long, oldUrl: String, newUrl: String, rename: Rename) {
        renames.set(renames.get() - key(sourceId, oldUrl) + (key(sourceId, newUrl) to rename))
    }

    /** Puts the user's names and numbers over the ones [chapters] came with from the source. */
    fun applyTo(sourceId: Long, chapters: List<Chapter>): List<Chapter> {
        val all = renames.get()
        if (all.isEmpty()) return chapters
        return chapters.map { chapter ->
            all[key(sourceId, chapter.url)]?.let { chapter.copy(name = it.name, chapterNumber = it.number) } ?: chapter
        }
    }

    private fun key(sourceId: Long, url: String) = "$sourceId|$url"
}
