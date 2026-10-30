package doki.bookorbit

import kotlinx.serialization.Serializable

@Serializable
data class BookOrbitLoginDto(
    val username: String,
    val password: String,
    /** "native" makes BookOrbit return the refresh token in the body instead of a cookie. */
    val clientKind: String = "native",
    val deviceLabel: String,
)

@Serializable
data class BookOrbitRefreshDto(
    val refreshToken: String,
)

@Serializable
data class BookOrbitCredentialsDto(
    val accessToken: String,
    val refreshToken: String? = null,
)

@Serializable
data class BookOrbitUserDto(
    val username: String? = null,
)

@Serializable
data class BookOrbitLibraryDto(
    val id: Int,
    val name: String,
)

@Serializable
data class BookOrbitSeriesPageDto(
    val items: List<BookOrbitSeriesDto> = emptyList(),
    val total: Int = 0,
)

@Serializable
data class BookOrbitSeriesDto(
    val id: Int,
    val name: String,
    val authors: List<String> = emptyList(),
    val coverBookIds: List<Int> = emptyList(),
    val bookCount: Int = 0,
    /** Books the user has marked read. */
    val readCount: Int = 0,
)

@Serializable
data class BookOrbitSeriesBooksPageDto(
    val items: List<BookOrbitBookDto> = emptyList(),
    val total: Int = 0,
    val seriesInfo: BookOrbitSeriesInfoDto? = null,
)

@Serializable
data class BookOrbitSeriesInfoDto(
    val id: Int,
    val name: String,
    val authors: List<String> = emptyList(),
)

@Serializable
data class BookOrbitBookDto(
    val id: Int,
    val title: String? = null,
    val seriesIndex: String? = null,
    val files: List<BookOrbitFileDto> = emptyList(),
    val genres: List<String> = emptyList(),
    /** How far the user is, from 0 to 100, or `null` if not started. */
    val readingProgress: Double? = null,
    val readStatus: BookOrbitReadStatusDto? = null,
    val addedAt: String? = null,
    val publishedDate: String? = null,
) {
    /** The comic archive Doki can show page by page; BookOrbit's page API only serves these. */
    val comicFile: BookOrbitFileDto?
        get() = files.firstOrNull { it.format?.lowercase() in COMIC_FORMATS }

    val isRead: Boolean
        get() = readStatus?.status == STATUS_READ || (readingProgress ?: 0.0) >= 100.0

    companion object {
        val COMIC_FORMATS = setOf("cbz", "cbr", "cb7", "cbt")
        const val STATUS_READ = "read"
        const val STATUS_UNREAD = "unread"
    }
}

@Serializable
data class BookOrbitFileDto(
    val id: Int,
    val format: String? = null,
)

@Serializable
data class BookOrbitReadStatusDto(
    val status: String? = null,
)

@Serializable
data class BookOrbitBookDetailDto(
    val id: Int,
    val files: List<BookOrbitDetailFileDto> = emptyList(),
)

@Serializable
data class BookOrbitDetailFileDto(
    val id: Int,
    /** KOReader's partial MD5 of the file, which BookOrbit matches KOReader's progress by. */
    val fileHash: String? = null,
)

@Serializable
data class BookOrbitPageCountDto(
    val pageCount: Int,
)

/** A file's position: [pageNumber] is 1-based and [percentage] runs from 0 to 100. */
@Serializable
data class BookOrbitProgressDto(
    val pageNumber: Int? = null,
    val percentage: Double = 0.0,
)

@Serializable
data class BookOrbitStatusDto(
    val status: String,
)
