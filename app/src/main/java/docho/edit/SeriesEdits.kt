package docho.edit

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.data.download.DownloadManager
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import tachiyomi.domain.manga.model.Manga
import tachiyomi.domain.manga.model.MangaRemoteUpdate
import tachiyomi.domain.manga.repository.MangaRepository

/**
 * Series details the user edited: title, author, artist, description, genres and status. Like
 * Kavita's locked fields, an edited field stays over what the source sends on every refresh (see
 * [applyTo]) until it's reset. Shared with other devices and Dōchō Server as Dōchō Sync's
 * "details" records, whose value is [toJson]: only the edited fields, blank ones as "".
 */
@Inject
@SingleIn(AppScope::class)
class SeriesEdits(
    preferenceStore: PreferenceStore,
    private val mangaRepository: MangaRepository,
    private val downloadManager: DownloadManager,
) {

    /** The edited fields; null ones weren't edited. */
    @Serializable
    data class Details(
        val title: String? = null,
        val author: String? = null,
        val artist: String? = null,
        val description: String? = null,
        val genres: List<String>? = null,
        val status: Long? = null,
    ) {
        val isEmpty get() = this == Details()
    }

    /** Keyed by "sourceId|url", as Dōchō Sync keys series. */
    val edits: Preference<Map<String, Details>> = preferenceStore.getObjectFromString(
        key = "series_edits",
        defaultValue = emptyMap(),
        serializer = { Json.encodeToString(it) },
        deserializer = { runCatching { Json.decodeFromString<Map<String, Details>>(it) }.getOrDefault(emptyMap()) },
    )

    fun get(sourceId: Long, url: String): Details? = edits.get()[key(sourceId, url)]

    /** Remembers [details] for the series (or forgets them when empty or null). */
    fun put(sourceId: Long, url: String, details: Details?) {
        val key = key(sourceId, url)
        edits.set(if (details == null || details.isEmpty) edits.get() - key else edits.get() + (key to details))
    }

    /** Puts the edited fields over what a source just sent, before it's saved. */
    fun applyTo(sourceId: Long, url: String, manga: SManga) {
        val edit = get(sourceId, url) ?: return
        edit.title?.takeIf { it.isNotBlank() }?.let { manga.title = it }
        edit.author?.let { manga.author = it }
        edit.artist?.let { manga.artist = it }
        edit.description?.let { manga.description = it }
        edit.genres?.let { manga.genre = it.joinToString(", ") }
        edit.status?.let { manga.status = it.toInt() }
    }

    /**
     * Saves [details] as the series' edits and writes them over its details now. Fields that are
     * no longer edited keep their current value until the next refresh brings the source's back.
     */
    suspend fun edit(manga: Manga, details: Details?) {
        put(manga.source, manga.url, details)
        write(manga, details ?: return)
    }

    /** Writes [details]' fields over the series' details. */
    suspend fun write(manga: Manga, details: Details) {
        val title = details.title?.takeIf { it.isNotBlank() && it != manga.title }
        mangaRepository.updateRemote(
            MangaRemoteUpdate(
                id = manga.id,
                title = title,
                // The update keeps what it isn't given, so a cleared field is written as "".
                author = details.author,
                artist = details.artist,
                description = details.description,
                genre = details.genres,
                status = details.status ?: manga.status,
                thumbnailUrl = manga.thumbnailUrl,
                updateStrategy = manga.updateStrategy,
                memo = manga.memo,
                initialized = manga.initialized,
                coverLastModified = null,
            ),
        )
        if (title != null) downloadManager.renameManga(manga, title)
    }

    companion object {
        fun key(sourceId: Long, url: String) = "$sourceId|$url"

        fun toJson(details: Details): JsonObject = JsonObject(
            buildMap {
                details.title?.let { put("title", JsonPrimitive(it)) }
                details.author?.let { put("author", JsonPrimitive(it)) }
                details.artist?.let { put("artist", JsonPrimitive(it)) }
                details.description?.let { put("description", JsonPrimitive(it)) }
                details.genres?.let { put("genres", JsonArray(it.map(::JsonPrimitive))) }
                details.status?.let { put("status", JsonPrimitive(it)) }
            },
        )

        fun fromJson(value: JsonObject): Details {
            fun string(name: String): String? = when (val element = value[name]) {
                null, JsonNull -> null
                else -> (element as? JsonPrimitive)?.contentOrNull
            }
            return Details(
                title = string("title"),
                author = string("author"),
                artist = string("artist"),
                description = string("description"),
                genres = (value["genres"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                status = (value["status"] as? JsonPrimitive)?.longOrNull,
            )
        }
    }
}
