package mihonka.kavita

import kotlinx.serialization.Serializable

/*
 * Only the fields Mihonka reads are declared; the shared Json instance ignores the rest.
 * Field names follow Kavita's camelCase JSON. Most fields default so that older servers,
 * which lack some of them, still parse.
 */

@Serializable
data class KavitaUserDto(
    val username: String = "",
    val token: String,
    val kavitaVersion: String? = null,
)

@Serializable
data class KavitaLibraryDto(
    val id: Int,
    val name: String,
    val type: Int = 0,
)

@Serializable
data class KavitaSeriesDto(
    val id: Int,
    val name: String? = null,
    val originalName: String? = null,
    val localizedName: String? = null,
    val pages: Int = 0,
    val pagesRead: Int = 0,
    val format: Int = FORMAT_UNKNOWN,
    val libraryId: Int = 0,
    val libraryName: String? = null,
) {
    companion object {
        const val FORMAT_IMAGE = 0
        const val FORMAT_UNKNOWN = 2
        const val FORMAT_EPUB = 3
    }
}

@Serializable
data class KavitaNamedDto(
    val title: String? = null,
    val name: String? = null,
) {
    val label: String? get() = (title ?: name)?.takeIf { it.isNotBlank() }
}

@Serializable
data class KavitaSeriesMetadataDto(
    val summary: String? = null,
    val genres: List<KavitaNamedDto> = emptyList(),
    val tags: List<KavitaNamedDto> = emptyList(),
    val writers: List<KavitaNamedDto> = emptyList(),
    val coverArtists: List<KavitaNamedDto> = emptyList(),
    val pencillers: List<KavitaNamedDto> = emptyList(),
    val publicationStatus: Int = -1,
)

@Serializable
data class KavitaVolumeDto(
    val id: Int,
    val name: String = "",
    val minNumber: Float? = null,
    @Suppress("PropertyName")
    val number: Float? = null,
    val pages: Int = 0,
    val pagesRead: Int = 0,
    val seriesId: Int = 0,
    val chapters: List<KavitaChapterDto> = emptyList(),
) {
    val volumeNumber: Float get() = minNumber ?: number ?: 0f
}

@Serializable
data class KavitaChapterDto(
    val id: Int,
    val range: String? = null,
    val number: String? = null,
    val minNumber: Float? = null,
    val maxNumber: Float? = null,
    val pages: Int = 0,
    val pagesRead: Int = 0,
    val isSpecial: Boolean = false,
    val title: String? = null,
    val titleName: String? = null,
    val volumeId: Int = 0,
    val created: String? = null,
    val releaseDate: String? = null,
    val files: List<KavitaFileDto> = emptyList(),
) {
    val chapterNumber: Float
        get() = minNumber ?: number?.replace(',', '.')?.toFloatOrNull() ?: KavitaConstants.DEFAULT_CHAPTER_NUMBER

    /**
     * The KOReader document hash, lowercased like KOReader sends it. Only a chapter made of a
     * single file has one, since KOReader would see each file as a separate document.
     */
    val koreaderHash: String?
        get() = files.singleOrNull()?.koreaderHash?.takeIf { it.isNotBlank() }?.lowercase()

    /** Name of the chapter's first file, without its folder. */
    val fileName: String?
        get() = files.mapNotNull { file -> file.filePath?.substringAfterLast('/')?.substringAfterLast('\\') }
            .filter { it.isNotBlank() }
            .minWithOrNull(String.CASE_INSENSITIVE_ORDER)
}

@Serializable
data class KavitaFileDto(
    val format: Int = KavitaSeriesDto.FORMAT_UNKNOWN,
    val filePath: String? = null,
    /** KOReader's partial MD5 of the file. Kavita only computes it when it (re)scans a file. */
    val koreaderHash: String? = null,
)

@Serializable
data class KavitaProgressDto(
    val volumeId: Int,
    val chapterId: Int,
    val pageNum: Int,
    val seriesId: Int,
    val libraryId: Int,
)

@Serializable
data class KavitaMarkChaptersDto(
    val seriesId: Int,
    val volumeIds: List<Int>,
    val chapterIds: List<Int>,
)

@Serializable
data class KavitaFilterDto(
    val statements: List<KavitaFilterStatementDto> = emptyList(),
    val combination: Int = 1, // And
    val sortOptions: KavitaSortOptionsDto = KavitaSortOptionsDto(),
    val limitTo: Int = 0,
)

@Serializable
data class KavitaFilterStatementDto(
    val comparison: Int,
    val field: Int,
    val value: String,
)

@Serializable
data class KavitaSortOptionsDto(
    val sortField: Int = KavitaConstants.SORT_NAME,
    val isAscending: Boolean = true,
)

@Serializable
data class KavitaPaginationDto(
    val currentPage: Int = 1,
    val totalPages: Int = 1,
)

object KavitaConstants {
    /** Volume holding chapters that belong to no volume (Kavita 0.8+). */
    const val LOOSE_LEAF_VOLUME_NUMBER = -100_000f

    /** Volume holding the specials (Kavita 0.8+). */
    const val SPECIAL_VOLUME_NUMBER = 100_000f

    /** Chapter number of a file that is a whole volume (Kavita 0.8+). */
    const val DEFAULT_CHAPTER_NUMBER = -100_000f

    // FilterComparison
    const val COMPARISON_MATCHES = 7
    const val COMPARISON_NOT_CONTAINS = 8
    const val COMPARISON_NOT_EQUAL = 9
    const val COMPARISON_CONTAINS = 5

    // SeriesFilterField
    const val FIELD_SERIES_NAME = 1
    const val FIELD_LIBRARIES = 19
    const val FIELD_READ_PROGRESS = 20
    const val FIELD_FORMATS = 21

    // SeriesSortField
    const val SORT_NAME = 1
    const val SORT_CREATED = 2
    const val SORT_LAST_CHAPTER_ADDED = 4
    const val SORT_READ_PROGRESS = 7

    // PublicationStatus
    const val STATUS_ONGOING = 0
    const val STATUS_HIATUS = 1
    const val STATUS_COMPLETED = 2
    const val STATUS_CANCELLED = 3
    const val STATUS_ENDED = 4
}

@Serializable
data class KavitaReadPositionDto(
    val pageNum: Int = 0,
)
