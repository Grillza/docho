package doki.komga

import kotlinx.serialization.Serializable

/*
 * Only the fields Doki reads are declared; the shared Json instance ignores the rest. Komga
 * ids are strings, and its lists come as Spring pages.
 */

@Serializable
data class KomgaUserDto(
    val email: String = "",
)

@Serializable
data class KomgaLibraryDto(
    val id: String,
    val name: String,
)

@Serializable
data class KomgaPageDto<T>(
    val content: List<T> = emptyList(),
    val last: Boolean = true,
)

@Serializable
data class KomgaSeriesDto(
    val id: String,
    val name: String = "",
    val booksCount: Int = 0,
    val booksReadCount: Int = 0,
    val metadata: KomgaSeriesMetadataDto = KomgaSeriesMetadataDto(),
    val booksMetadata: KomgaBooksMetadataDto = KomgaBooksMetadataDto(),
) {
    val title: String get() = metadata.title.ifBlank { name }
}

@Serializable
data class KomgaSeriesMetadataDto(
    val title: String = "",
    val summary: String = "",
    val status: String = "",
    val genres: List<String> = emptyList(),
    val tags: List<String> = emptyList(),
)

/** What Komga gathers from the books of a series: their authors, and a summary if the series has none. */
@Serializable
data class KomgaBooksMetadataDto(
    val authors: List<KomgaAuthorDto> = emptyList(),
    val summary: String = "",
)

@Serializable
data class KomgaAuthorDto(
    val name: String,
    val role: String = "",
)

@Serializable
data class KomgaBookDto(
    val id: String,
    val seriesId: String = "",
    val name: String = "",
    /** The file's path, or only its name for accounts that aren't administrators. */
    val url: String = "",
    val created: String? = null,
    val media: KomgaMediaDto = KomgaMediaDto(),
    val metadata: KomgaBookMetadataDto = KomgaBookMetadataDto(),
    val readProgress: KomgaReadProgressDto? = null,
) {
    /** Komga turns comic archives, PDFs and image-based EPUBs into page images; other EPUBs are text. */
    val hasPages: Boolean
        get() = media.status == MEDIA_READY && media.pagesCount > 0 &&
            (media.mediaProfile in PAGED_PROFILES || media.epubDivinaCompatible)

    val fileName: String
        get() = url.substringAfterLast('/').substringAfterLast('\\').ifBlank { name }

    val isRead: Boolean get() = readProgress?.completed == true

    companion object {
        const val MEDIA_READY = "READY"
        val PAGED_PROFILES = setOf("DIVINA", "PDF")
    }
}

@Serializable
data class KomgaMediaDto(
    val status: String = "",
    val pagesCount: Int = 0,
    val mediaProfile: String = "",
    val epubDivinaCompatible: Boolean = false,
)

@Serializable
data class KomgaBookMetadataDto(
    val title: String = "",
    val number: String = "",
    val numberSort: Float = -1f,
    val releaseDate: String? = null,
)

/** The page reached, counting from 1, and whether the book is finished. */
@Serializable
data class KomgaReadProgressDto(
    val page: Int = 0,
    val completed: Boolean = false,
)

@Serializable
data class KomgaReadProgressUpdateDto(
    val page: Int? = null,
    val completed: Boolean? = null,
)

@Serializable
data class KomgaPageInfoDto(
    val number: Int,
)
