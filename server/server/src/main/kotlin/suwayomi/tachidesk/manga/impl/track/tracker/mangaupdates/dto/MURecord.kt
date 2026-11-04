package suwayomi.tachidesk.manga.impl.track.tracker.mangaupdates.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import suwayomi.tachidesk.manga.impl.track.Track.htmlDecode
import suwayomi.tachidesk.manga.impl.track.tracker.model.TrackSearch

@Serializable
data class MURecord(
    @SerialName("series_id")
    val seriesId: Long? = null,
    val title: String? = null,
    val url: String? = null,
    val description: String? = null,
    val image: MUImage? = null,
    val type: String? = null,
    val year: String? = null,
    @SerialName("bayesian_rating")
    val bayesianRating: Double? = null,
    @SerialName("rating_votes")
    val ratingVotes: Int? = null,
    @SerialName("latest_chapter")
    val latestChapter: Int? = null,
    val authors: List<MUAuthor> = emptyList(),
    val status: String? = null,
    val completed: Boolean? = null,
)

@Serializable
data class MUAuthor(
    val name: String,
    val type: String,
)

private val STATUS_IN_BRACKETS = Regex("""\((Ongoing|Complete|Hiatus|Cancelled|Discontinued|Dropped)\)""", RegexOption.IGNORE_CASE)

/** "43 Volumes (Ongoing)" as "Ongoing". Only a series' details have this, not search results. */
private fun MURecord.publishingStatus(): String =
    if (completed == true) "Completed" else status?.let { STATUS_IN_BRACKETS.find(it)?.groupValues?.get(1) }.orEmpty()

fun MURecord.toTrackSearch(id: Int): TrackSearch =
    TrackSearch.create(id).apply {
        remote_id = this@toTrackSearch.seriesId ?: 0L
        title = this@toTrackSearch.title?.htmlDecode() ?: ""
        total_chapters = 0
        cover_url = this@toTrackSearch.image?.url?.original ?: ""
        summary = this@toTrackSearch.description?.htmlDecode() ?: ""
        tracking_url = this@toTrackSearch.url ?: ""
        publishing_status = publishingStatus()
        publishing_type = this@toTrackSearch.type.toString()
        start_date = this@toTrackSearch.year.toString()
        authors = this@toTrackSearch.authors.filter { it.type == "Author" }.map { it.name }
        artists = this@toTrackSearch.authors.filter { it.type == "Artist" }.map { it.name }
    }
