package docho.edit

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.data.track.EnhancedTracker
import eu.kanade.tachiyomi.data.track.Tracker
import eu.kanade.tachiyomi.data.track.TrackerManager
import eu.kanade.tachiyomi.data.track.model.TrackSearch
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable
import tachiyomi.domain.manga.model.Manga
import tachiyomi.domain.track.interactor.GetTracks

/**
 * Fills a series' empty details from a tracker, for Edit details to show before they're saved.
 * Series linked to a tracker use that entry; others search for it and the user picks the result.
 */
@Inject
@SingleIn(AppScope::class)
class TrackerFill(
    private val trackerManager: TrackerManager,
    private val getTracks: GetTracks,
) {

    /** What a tracker knows about a series. */
    @Serializable
    data class Match(
        val trackerName: String,
        val title: String,
        val author: String,
        val artist: String,
        val description: String,
        val publishingStatus: String,
        val status: Long,
        val trackerId: Long = 0,
        val remoteId: Long = 0,
        /** False if it's a search result that lacks the people and status its details would add. */
        val complete: Boolean = true,
    )

    /** The fields a tracker can fill. */
    data class Form(
        val author: String,
        val artist: String,
        val description: String,
        val status: Long,
    )

    fun canFill() = trackers().isNotEmpty()

    /** The entries of the trackers the series is linked to; empty if there are none. */
    suspend fun linked(manga: Manga): List<Match> {
        val byId = trackers().associateBy { it.id }
        return getTracks.await(manga.id).mapNotNull { track ->
            val tracker = byId[track.trackerId] ?: return@mapNotNull null
            try {
                // MangaUpdates' search results have no people or status: it's looked up by id
                val results = tracker.search(if (tracker.id == trackerManager.mangaUpdates.id) "id:${track.remoteId}" else track.title)
                results.firstOrNull { it.remote_id == track.remoteId }?.toMatch(tracker)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
        }
    }

    /** The closest results on each tracker. Throws only if every tracker failed. */
    suspend fun search(query: String): List<Match> = coroutineScope {
        val results = trackers()
            .map { tracker -> async { runCatching { searchOn(tracker, query) } } }
            .awaitAll()
        results.firstOrNull()?.takeIf { results.all { it.isFailure } }?.getOrThrow()
        results.flatMap { it.getOrDefault(emptyList()) }
    }

    private suspend fun searchOn(tracker: Tracker, query: String): List<Match> = coroutineScope {
        val results = tracker.search(query).take(RESULTS_PER_TRACKER)
        if (tracker.id != trackerManager.mangaUpdates.id) return@coroutineScope results.map { it.toMatch(tracker) }
        results
            .map { result ->
                async {
                    val details = runCatching { tracker.search("id:${result.remote_id}").firstOrNull() }.getOrNull()
                    (details ?: result).toMatch(tracker)
                }
            }
            .awaitAll()
    }

    /** The ones with the most details first, so a scan asks fewer. */
    fun trackersInScanOrder(): List<Tracker> = trackers().sortedBy { tracker ->
        with(trackerManager) { listOf(aniList, myAnimeList, mangaUpdates, mangaBaka, kitsu, shikimori, comick, hikka, bangumi) }
            .indexOf(tracker).let { if (it < 0) Int.MAX_VALUE else it }
    }

    /** A search result with whatever its details add. */
    suspend fun withDetails(tracker: Tracker, result: TrackSearch): Match {
        if (tracker.id != trackerManager.mangaUpdates.id) return result.toMatch(tracker)
        val details = try {
            tracker.search("id:${result.remote_id}").firstOrNull()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        return (details ?: result).toMatch(tracker)
    }

    /** A search result as it is, saying if its details would add to it. */
    fun withoutDetails(tracker: Tracker, result: TrackSearch) =
        result.toMatch(tracker).copy(complete = tracker.id != trackerManager.mangaUpdates.id)

    /** A [Match] from [withoutDetails] with its details. */
    suspend fun completed(match: Match): Match {
        val tracker = trackerManager.trackers.firstOrNull { it.id == match.trackerId } ?: return match
        return tracker.search("id:${match.remoteId}").firstOrNull()?.toMatch(tracker) ?: match
    }

    // Komga, Kavita and Suwayomi are the user's own servers, which only repeat what the source says
    private fun trackers() = trackerManager.loggedInTrackers().filter { it !is EnhancedTracker }

    private fun TrackSearch.toMatch(tracker: Tracker) = Match(
        trackerName = tracker.name,
        title = title,
        author = authors.distinct().joinToString(", "),
        artist = artists.distinct().joinToString(", "),
        description = summary.trim(),
        publishingStatus = publishing_status,
        status = status(publishing_status),
        trackerId = tracker.id,
        remoteId = remote_id,
    )

    companion object {
        private const val RESULTS_PER_TRACKER = 5

        /** A tracker's publishing status as a series status; each site words it its own way. */
        fun status(publishing: String): Long = when (publishing.trim().lowercase().replace('_', ' ').replace('-', ' ')) {
            "releasing", "publishing", "currently publishing", "ongoing", "current" -> SManga.ONGOING
            "finished", "completed", "complete", "released" -> SManga.COMPLETED
            "cancelled", "canceled", "discontinued", "dropped" -> SManga.CANCELLED
            "hiatus", "on hiatus", "paused" -> SManga.ON_HIATUS
            else -> SManga.UNKNOWN
        }.toLong()

        /**
         * Puts [match] in the fields that are empty, leaving what's there. Sources often send
         * "Unknown" for a missing name, which counts as empty. A status edited earlier can go
         * stale, so [statusEdited] lets a tracker's status replace it; it's still shown to check.
         */
        fun fill(form: Form, match: Match, statusEdited: Boolean): Form = Form(
            author = form.author.takeUnless(::isEmpty) ?: match.author.ifBlank { form.author },
            artist = form.artist.takeUnless(::isEmpty) ?: match.artist.ifBlank { form.artist },
            description = form.description.ifBlank { match.description },
            status = if (match.status != SManga.UNKNOWN.toLong() && (form.status == SManga.UNKNOWN.toLong() || statusEdited)) {
                match.status
            } else {
                form.status
            },
        )

        private fun isEmpty(name: String) = name.isBlank() || name.trim().equals("unknown", ignoreCase = true)
    }
}
