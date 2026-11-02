package tachiyomi.domain.chapter.model

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import mihon.core.common.extensions.EMPTY
import kotlin.time.Instant

data class Chapter(
    val id: Long,
    val mangaId: Long,
    val read: Boolean,
    val bookmark: Boolean,
    val lastPageRead: Int,
    val dateFetch: Instant,
    val sourceOrder: Long,
    val url: String,
    val name: String,
    val dateUpload: Instant?,
    val chapterNumber: Double,
    val scanlator: String?,
    val memo: JsonObject,
) {
    val isRecognizedNumber: Boolean
        get() = chapterNumber >= 0f

    /** The name of the file the source read this chapter from, or the chapter name if it gave none. */
    val fileName: String
        get() = memo[MEMO_FILE_NAME]?.jsonPrimitive?.contentOrNull ?: name

    /**
     * Whether this is a whole volume rather than a chapter: as the user set it in Docho, else read from a name like
     * "Vol. 3" or "Volume 3 - Title" that names no chapter.
     */
    val isVolume: Boolean
        get() = when (memo[MEMO_KIND]?.jsonPrimitive?.contentOrNull) {
            KIND_VOLUME -> true
            KIND_CHAPTER -> false
            else -> looksLikeVolume(name)
        }

    fun copyFrom(other: Chapter): Chapter {
        return copy(
            name = other.name,
            url = other.url,
            dateUpload = other.dateUpload,
            chapterNumber = other.chapterNumber,
            scanlator = other.scanlator?.ifBlank { null },
        )
    }

    companion object {
        /** Memo key a source can set to the chapter's file name, for sorting by file name. */
        const val MEMO_FILE_NAME = "fileName"

        /** Memo key Docho sets to [KIND_VOLUME] or [KIND_CHAPTER] when the user says which a chapter is. */
        const val MEMO_KIND = "kind"
        const val KIND_VOLUME = "volume"
        const val KIND_CHAPTER = "chapter"

        private val VOLUME_NAME = Regex("""^\s*(?:vol(?:ume)?\.?|v\.?)\s*[0-9]""", RegexOption.IGNORE_CASE)
        private val CHAPTER_IN_NAME = Regex("""\b(?:ch|chap|chapter)\.?\s*[0-9]""", RegexOption.IGNORE_CASE)

        /** "Vol. 3", "Volume 3 - Title" or "v03", but not "Vol. 3 Ch. 12", which is a chapter in a volume. */
        fun looksLikeVolume(name: String): Boolean =
            VOLUME_NAME.containsMatchIn(name) && !CHAPTER_IN_NAME.containsMatchIn(name)

        fun create() = Chapter(
            id = -1,
            mangaId = -1,
            read = false,
            bookmark = false,
            lastPageRead = 0,
            dateFetch = Instant.fromEpochMilliseconds(0),
            sourceOrder = 0,
            url = "",
            name = "",
            dateUpload = null,
            chapterNumber = -1.0,
            scanlator = null,
            memo = JsonObject.EMPTY,
        )
    }
}
