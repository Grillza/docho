package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.neq
import org.jetbrains.exposed.v1.jdbc.deleteAll
import org.jetbrains.exposed.v1.jdbc.deleteWhere
import org.jetbrains.exposed.v1.jdbc.select
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.update
import org.jetbrains.exposed.v1.jdbc.upsert
import suwayomi.tachidesk.docho.DochoSeriesFillTable
import suwayomi.tachidesk.docho.DochoTrackerFillItemTable
import suwayomi.tachidesk.docho.groups.SeriesGroups
import suwayomi.tachidesk.docho.sync.SyncBridge
import suwayomi.tachidesk.manga.impl.track.tracker.Tracker
import suwayomi.tachidesk.manga.impl.track.tracker.TrackerManager
import suwayomi.tachidesk.manga.impl.track.tracker.mangaupdates.MangaUpdates
import suwayomi.tachidesk.manga.impl.track.tracker.model.TrackSearch
import suwayomi.tachidesk.manga.model.table.MangaTable
import suwayomi.tachidesk.manga.model.table.TrackRecordTable
import kotlin.time.Duration.Companion.seconds

/**
 * Fills series' details from trackers, with the trackers signed in on the server. The WebUI's Edit
 * details fills one series, to check before saving ([matches]). [start] scans the whole library
 * and writes nothing: each series that has something to say becomes a [TrackerFillItem] to review,
 * kept in the database as a scan can take hours. Only [resolve] and [applyReady] change a series,
 * saving edits that lock the fields and reach the apps through Dōchō Sync. What's kept or skipped
 * is remembered, so it only comes back if a tracker says something new.
 */
object TrackerFill {
    private val logger = KotlinLogging.logger {}
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    /** Trackers are asked one at a time with a pause between, not to run into their rate limits. */
    private val PAUSE = 2.seconds
    private const val RESULTS_PER_TRACKER = 5
    private const val SUGGESTIONS_PER_TRACKER = 3
    private const val UNKNOWN = 0
    private const val ONGOING = 1
    private const val COMPLETED = 2
    private const val LICENSED = 3
    private const val PUBLISHING_FINISHED = 4
    private const val CANCELLED = 5
    private const val ON_HIATUS = 6

    /** In the remembered choices, a series left out of scans altogether. */
    private const val SKIPPED = "*"
    private const val KEPT = "kept"

    /** What a tracker knows about a series. */
    @Serializable
    data class TrackerMatch(
        val trackerId: Int,
        val remoteId: Long,
        val trackerName: String,
        val title: String,
        val writers: List<String>,
        val artists: List<String>,
        val summary: String,
        val publishingStatus: String,
        val status: Int,
        /** The series is linked to this entry, so there's no need to ask which one it is. */
        val linked: Boolean,
        /** False if it's a search result that lacks the people and status its details would add. */
        val complete: Boolean = true,
    )

    /** Why a series is on the review list. */
    enum class TrackerFillProblem {
        /** Only empty fields to fill, and nothing disagrees. */
        READY,

        /** A tracker differs from the series, or trackers differ from each other. */
        DIFFERENT,

        /** More than one series has this title. */
        SEVERAL_MATCHES,

        NO_MATCH,
    }

    /** One value a field could take, and the tracker it's from. Names are ", "-separated; statuses are numbers. */
    @Serializable
    data class TrackerFillOption(
        val value: String,
        val trackerName: String,
    )

    /** A field a tracker has something to say about. */
    @Serializable
    data class TrackerFillChange(
        val field: SeriesMetadata.Field,
        val current: String,
        val options: List<TrackerFillOption>,
        /** It takes a decision: [current] would be replaced, or the [options] differ. */
        val conflict: Boolean,
    )

    @Serializable
    data class TrackerFillItem(
        val mangaId: Int,
        val title: String,
        val problem: TrackerFillProblem,
        val changes: List<TrackerFillChange> = emptyList(),
        /** The series it could be, for [TrackerFillProblem.SEVERAL_MATCHES] and [TrackerFillProblem.NO_MATCH]. */
        val candidates: List<TrackerMatch> = emptyList(),
        /** The user said which series it is. Scans would only fail to find it again, so they leave it out. */
        val picked: Boolean = false,
    )

    /** A field's outcome: the option taken, or null to keep what the series has. */
    data class TrackerFillChoice(
        val field: SeriesMetadata.Field,
        val value: String? = null,
    )

    data class TrackerFillResult(
        val applied: Int,
        val failed: Int,
    )

    data class TrackerFillStatus(
        val running: Boolean = false,
        val total: Int = 0,
        val done: Int = 0,
        /** Series found on a tracker, with nothing to add. */
        val unchanged: Int = 0,
        /** Trackers that couldn't be reached for a series. */
        val failed: Int = 0,
        /** Items waiting on the review list. */
        val ready: Int = 0,
        val conflicts: Int = 0,
        val finishedAt: Long = 0,
    )

    /** The fields a tracker can fill, as a series has them. */
    data class Current(
        val writers: String,
        val artists: String,
        val summary: String,
        val status: Int,
    ) {
        val hasEmptyFields get() = isEmptyName(writers) || isEmptyName(artists) || summary.isBlank() || status == UNKNOWN
    }

    /** A transaction that isn't inlined: this object makes many, and inlining them all outgrows the compiler. */
    private fun <T> db(block: () -> T): T = org.jetbrains.exposed.v1.jdbc.transactions.transaction { block() }

    private val progress = MutableStateFlow(TrackerFillStatus())
    private var job: Job? = null

    /** A tracker's publishing status as a series status; each site words it its own way. */
    fun status(publishing: String): Int =
        when (publishing.trim().lowercase().replace('_', ' ').replace('-', ' ')) {
            "releasing", "publishing", "currently publishing", "ongoing", "current" -> ONGOING
            "finished", "completed", "complete", "released" -> COMPLETED
            "cancelled", "canceled", "discontinued", "dropped" -> CANCELLED
            "hiatus", "on hiatus", "paused" -> ON_HIATUS
            else -> UNKNOWN
        }

    /** Sources often send "Unknown" for a missing name. */
    fun isEmptyName(name: String) = name.isBlank() || name.trim().equals("unknown", ignoreCase = true)

    /** A title without case, spaces or punctuation, so only real differences stop a match. */
    fun comparable(title: String): String = title.lowercase().filter { it.isLetterOrDigit() }

    /**
     * Names to compare, whatever their order: trackers write "MIURA Kentaro", sources "Kentaro
     * Miura", and either can list the people differently.
     */
    fun namesKey(names: String): String =
        names
            .split(",")
            .map { name ->
                name
                    .trim()
                    .split(Regex("\\s+"))
                    .map(::comparable)
                    .filter { it.isNotEmpty() }
                    .sorted()
                    .joinToString(" ")
            }.filter { it.isNotEmpty() }
            .distinct()
            .sorted()
            .joinToString(",")

    /** Whether a tracker's [status] says the same as the series'. Trackers can't tell these apart. */
    private fun sameStatus(
        current: Int,
        status: Int,
    ) = current == status || current == LICENSED || (current == PUBLISHING_FINISHED && status == COMPLETED)

    /**
     * What [matches] have to say about a series. An empty field just takes its value, unless
     * trackers disagree. A field with a value is a conflict if a tracker differs, except for a
     * status that the last fill gave ([filledStatus]), which is only out of date. Summaries are
     * never compared: no two are worded alike. Values in [ignored] were decided on earlier.
     */
    fun review(
        current: Current,
        matches: List<TrackerMatch>,
        filledStatus: Int?,
        ignored: Map<String, List<String>> = emptyMap(),
    ): List<TrackerFillChange> =
        buildList {
            fun names(
                field: SeriesMetadata.Field,
                value: String,
                of: (TrackerMatch) -> List<String>,
            ) {
                val options =
                    matches
                        .filter { of(it).isNotEmpty() }
                        .map { TrackerFillOption(of(it).joinToString(", "), it.trackerName) }
                        .distinctBy { namesKey(it.value) }
                        .filter { namesKey(it.value) !in ignored[field.key].orEmpty() }
                if (isEmptyName(value)) {
                    if (options.isNotEmpty()) add(TrackerFillChange(field, value, options, conflict = options.size > 1))
                } else {
                    val different = options.filter { namesKey(it.value) != namesKey(value) }
                    if (different.isNotEmpty()) add(TrackerFillChange(field, value, different, conflict = true))
                }
            }
            names(SeriesMetadata.Field.WRITERS, current.writers) { it.writers }
            names(SeriesMetadata.Field.ARTISTS, current.artists) { it.artists }

            // Summaries are never worded alike, so keeping one's emptiness is decided once
            if (current.summary.isBlank() && ignored[SeriesMetadata.Field.SUMMARY.key].isNullOrEmpty()) {
                matches
                    .firstOrNull { it.summary.isNotBlank() }
                    ?.let { add(TrackerFillChange(SeriesMetadata.Field.SUMMARY, "", listOf(TrackerFillOption(it.summary, it.trackerName)), conflict = false)) }
            }

            val statuses =
                matches
                    .filter { it.status != UNKNOWN && it.status.toString() !in ignored[SeriesMetadata.Field.STATUS.key].orEmpty() }
                    .distinctBy { it.status }
                    .filterNot { sameStatus(current.status, it.status) }
                    .map { TrackerFillOption(it.status.toString(), it.trackerName) }
            if (statuses.isNotEmpty()) {
                val weOwnIt = current.status == UNKNOWN || current.status == filledStatus
                add(TrackerFillChange(SeriesMetadata.Field.STATUS, current.status.toString(), statuses, conflict = !weOwnIt || statuses.size > 1))
            }
        }

    /**
     * An item as it stands now that the series may have changed since the scan, here or on another
     * device: values it already has or that were decided against drop out. Null if nothing's left.
     */
    fun prune(
        item: TrackerFillItem,
        current: Current,
        filledStatus: Int?,
        ignored: Map<String, List<String>>,
    ): TrackerFillItem? {
        if (SKIPPED in ignored) return null
        if (item.changes.isEmpty()) return if (current.hasEmptyFields) item else null
        val changes =
            item.changes.mapNotNull { change ->
                val decided = ignored[change.field.key].orEmpty()
                when (change.field) {
                    SeriesMetadata.Field.WRITERS, SeriesMetadata.Field.ARTISTS -> {
                        val live = if (change.field == SeriesMetadata.Field.WRITERS) current.writers else current.artists
                        val options =
                            change.options.filter { namesKey(it.value) !in decided && (isEmptyName(live) || namesKey(it.value) != namesKey(live)) }
                        options
                            .takeIf { it.isNotEmpty() }
                            ?.let { change.copy(current = live, options = it, conflict = !isEmptyName(live) || it.size > 1) }
                    }
                    SeriesMetadata.Field.SUMMARY -> change.takeIf { current.summary.isBlank() && decided.isEmpty() }
                    else -> {
                        val options =
                            change.options.filter { it.value !in decided && !sameStatus(current.status, it.value.toInt()) }
                        val weOwnIt = current.status == UNKNOWN || current.status == filledStatus
                        options
                            .takeIf { it.isNotEmpty() }
                            ?.let { change.copy(current = current.status.toString(), options = it, conflict = !weOwnIt || it.size > 1) }
                    }
                }
            }
        return itemOf(item.mangaId, item.title, changes)?.copy(picked = item.picked)
    }

    /** The item for a series that was found, or null if there's nothing to say. */
    private fun itemOf(
        mangaId: Int,
        title: String,
        changes: List<TrackerFillChange>,
    ): TrackerFillItem? =
        if (changes.isEmpty()) {
            null
        } else {
            TrackerFillItem(
                mangaId,
                title,
                if (changes.any { it.conflict }) TrackerFillProblem.DIFFERENT else TrackerFillProblem.READY,
                changes,
            )
        }

    private fun fieldValue(
        field: SeriesMetadata.Field,
        value: String,
    ): JsonElement =
        when (field) {
            SeriesMetadata.Field.WRITERS, SeriesMetadata.Field.ARTISTS ->
                JsonArray(value.split(",").map { it.trim() }.filter { it.isNotEmpty() }.map(::JsonPrimitive))
            SeriesMetadata.Field.STATUS -> JsonPrimitive(value.toInt())
            else -> JsonPrimitive(value)
        }

    /** The value that stands for an option in the remembered choices. */
    private fun optionKey(
        field: SeriesMetadata.Field,
        value: String,
    ) = if (field == SeriesMetadata.Field.WRITERS || field == SeriesMetadata.Field.ARTISTS) namesKey(value) else value

    // ---- One series, for Edit details ----

    suspend fun matches(
        mangaId: Int,
        query: String?,
    ): List<TrackerMatch> {
        val trackers = requireTrackers()
        val linked = linked(mangaId, trackers).matches
        if (linked.isNotEmpty()) return linked
        val title =
            query?.trim()?.ifEmpty { null }
                ?: db { MangaTable.selectAll().where { MangaTable.id eq mangaId }.first()[MangaTable.title] }
        return search(trackers, title)
    }

    /** The closest results on each tracker. Throws only if every tracker failed. */
    private suspend fun search(
        trackers: List<Tracker>,
        title: String,
    ): List<TrackerMatch> {
        val results =
            coroutineScope {
                trackers.map { tracker -> async { runCatching { searchWithDetails(tracker, title) } } }.awaitAll()
            }
        results.firstOrNull()?.takeIf { results.all { it.isFailure } }?.getOrThrow()
        return results.flatMap { it.getOrDefault(emptyList()) }
    }

    private suspend fun searchWithDetails(
        tracker: Tracker,
        title: String,
    ): List<TrackerMatch> =
        coroutineScope {
            tracker
                .search(title)
                .take(RESULTS_PER_TRACKER)
                .map { result -> async { withDetails(tracker, result).toMatch(tracker, linked = false) } }
                .awaitAll()
        }

    /** MangaUpdates' search results have no people or status, which takes another request. */
    private suspend fun withDetails(
        tracker: Tracker,
        result: TrackSearch,
    ): TrackSearch =
        if (tracker is MangaUpdates) {
            try {
                tracker.details(result.remote_id)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                logger.debug(e) { "No details for ${result.title} on ${tracker.name}" }
                result
            }
        } else {
            result
        }

    private fun TrackSearch.toMatch(
        tracker: Tracker,
        linked: Boolean,
        complete: Boolean = true,
    ) = TrackerMatch(
        trackerId = tracker.id,
        remoteId = remote_id,
        trackerName = tracker.name,
        title = title,
        writers = authors.map { it.trim() }.filter { it.isNotEmpty() }.distinct(),
        artists = artists.map { it.trim() }.filter { it.isNotEmpty() }.distinct(),
        summary = summary.trim(),
        publishingStatus = publishing_status,
        status = status(publishing_status),
        linked = linked,
        complete = complete,
    )

    /** The ones with the most details first, so fewer are asked. */
    private fun trackers(): List<Tracker> =
        with(TrackerManager) { listOf(aniList, myAnimeList, mangaUpdates, kitsu, shikimori, bangumi) }.filter { it.isLoggedIn }

    private fun requireTrackers(): List<Tracker> =
        trackers().also { require(it.isNotEmpty()) { "Sign in to a tracker in Settings → Tracking first" } }

    private class Lookup(
        val matches: List<TrackerMatch>,
        val failed: Int,
        /** Results that are all exactly the title, when it can't be told which is the series. */
        val several: List<TrackerMatch> = emptyList(),
        /** The closest results, when none has the title. */
        val suggestions: List<TrackerMatch> = emptyList(),
    )

    private suspend fun linked(
        mangaId: Int,
        trackers: List<Tracker>,
        pause: Boolean = false,
    ): Lookup {
        val records =
            db {
                TrackRecordTable
                    .selectAll()
                    .where { TrackRecordTable.mangaId eq mangaId }
                    .map { Triple(it[TrackRecordTable.trackerId], it[TrackRecordTable.remoteId], it[TrackRecordTable.title]) }
            }
        val matches = mutableListOf<TrackerMatch>()
        var failed = 0
        // In the trackers' order
        for (tracker in trackers) {
            val (_, remoteId, title) = records.firstOrNull { it.first == tracker.id } ?: continue
            try {
                val result =
                    if (tracker is MangaUpdates) tracker.details(remoteId) else tracker.search(title).firstOrNull { it.remote_id == remoteId }
                result?.let { matches += it.toMatch(tracker, linked = true) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                logger.warn(e) { "Could not look up $title on ${tracker.name}" }
                failed++
            }
            if (pause) delay(PAUSE)
        }
        return Lookup(matches, failed)
    }

    // ---- Scanning the library ----

    /** How the scan is going, and what's waiting on the review list. */
    fun status(): TrackerFillStatus {
        val waiting =
            db {
                DochoTrackerFillItemTable.selectAll().map { it[DochoTrackerFillItemTable.problem] }
            }
        val ready = waiting.count { it == TrackerFillProblem.READY.name }
        return progress.value.copy(ready = ready, conflicts = waiting.size - ready)
    }

    /** The review list as it stands now, conflicts first. */
    fun items(): List<TrackerFillItem> {
        val stored =
            db { DochoTrackerFillItemTable.selectAll().map { it[DochoTrackerFillItemTable.data] } }
                .mapNotNull { runCatching { json.decodeFromString<TrackerFillItem>(it) }.getOrNull() }
        val series = db { MangaTable.selectAll().associate { it[MangaTable.id].value to currentOf(it) } }
        val memory = remembered()
        return stored
            .mapNotNull { item -> settled(item, series[item.mangaId], memory[item.mangaId]) }
            .sortedWith(compareBy({ it.problem == TrackerFillProblem.READY }, { it.title.lowercase() }))
    }

    /** Saves what's left of an item, or takes it off the list if nothing is. */
    private fun settled(
        item: TrackerFillItem,
        current: Current?,
        memory: Remembered?,
    ): TrackerFillItem? {
        val left = current?.let { prune(item, it, memory?.status, memory?.ignored.orEmpty()) }
        when {
            left == null -> remove(item.mangaId)
            left != item -> save(left)
        }
        return left
    }

    /** Brings a series' item up to date after an edit or a decision, here or from another device. */
    fun settle(mangaId: Int) {
        val data =
            db {
                DochoTrackerFillItemTable.selectAll().where { DochoTrackerFillItemTable.manga eq mangaId }.firstOrNull()?.get(DochoTrackerFillItemTable.data)
            } ?: return
        val item = runCatching { json.decodeFromString<TrackerFillItem>(data) }.getOrNull() ?: return
        val current = db { MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull()?.let(::currentOf) }
        settled(item, current, remembered(mangaId)[mangaId])
    }

    fun settle(
        source: Long,
        url: String,
    ) {
        mangaIdOf(source, url)?.let(::settle)
    }

    private fun mangaIdOf(
        source: Long,
        url: String,
    ): Int? =
        db {
            MangaTable
                .select(MangaTable.id)
                .where { (MangaTable.sourceReference eq source) and (MangaTable.url eq url) }
                .firstOrNull()
                ?.get(MangaTable.id)
                ?.value
        }

    // ---- Shared with the apps, as Dōchō Sync's "fill" records ----

    /** A field's name in a record, the same as in "details" records. */
    private val syncNames = SeriesMetadata.syncedFields.entries.associate { (name, field) -> field.key to name }
    private val fieldKeys = SeriesMetadata.syncedFields.entries.associate { (name, field) -> name to field.key }

    /** What's remembered about a series as a record's value; null if nothing is. */
    fun recordOf(mangaId: Int): JsonObject? {
        val memory = remembered(mangaId)[mangaId] ?: return null
        val ignored =
            memory.ignored
                .filterValues { it.isNotEmpty() }
                .mapKeys { (key, _) -> syncNames[key] ?: key }
                .mapValues { (_, values) -> JsonArray(values.sorted().map(::JsonPrimitive)) }
        return JsonObject(
            buildMap {
                put("ignored", JsonObject(ignored))
                memory.status?.let { put("status", JsonPrimitive(it)) }
            },
        )
    }

    /** Takes a record from another device; the newest one has already won. A deleted one forgets it all. */
    fun fromSync(
        source: Long,
        url: String,
        value: JsonObject?,
    ) {
        val mangaId = mangaIdOf(source, url) ?: return
        val ignored =
            (value?.get("ignored") as? JsonObject)
                .orEmpty()
                .mapKeys { (key, _) -> fieldKeys[key] ?: key }
                .mapValues { (_, values) -> (values as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty() }
        db {
            DochoSeriesFillTable.upsert {
                it[manga] = mangaId
                it[status] = (value?.get("status") as? JsonPrimitive)?.intOrNull
                it[DochoSeriesFillTable.ignored] = json.encodeToString(ignored)
            }
        }
        settle(mangaId)
    }

    /**
     * Starts a new scan, which replaces the review list; does nothing if one is running. Fails if
     * no tracker is signed in. [compareAll] also looks up series with no empty fields, to find
     * where they differ from trackers. [forgetChoices] asks again about what was kept or skipped.
     */
    @Synchronized
    fun start(
        compareAll: Boolean,
        forgetChoices: Boolean,
    ): TrackerFillStatus {
        if (progress.value.running) return status()
        val trackers = requireTrackers()
        db {
            DochoTrackerFillItemTable.deleteAll()
            if (forgetChoices) {
                DochoSeriesFillTable.update { it[ignored] = "{}" }
            }
        }
        if (forgetChoices) {
            db { DochoSeriesFillTable.select(DochoSeriesFillTable.manga).map { it[DochoSeriesFillTable.manga].value } }
                .forEach(SyncBridge::publishFill)
        }
        progress.value = TrackerFillStatus(running = true)
        job =
            scope.launch {
                try {
                    run(trackers, compareAll)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    logger.warn(e) { "Tracker scan failed" }
                } finally {
                    progress.update { it.copy(running = false, finishedAt = System.currentTimeMillis()) }
                }
            }
        return status()
    }

    /** Stops the scan; what it found so far stays on the review list. */
    @Synchronized
    fun cancel(): TrackerFillStatus {
        job?.cancel()
        return status()
    }

    private class Row(
        val id: Int,
        val title: String,
        val current: Current,
    )

    private fun currentOf(row: org.jetbrains.exposed.v1.core.ResultRow) =
        Current(
            row[MangaTable.author].orEmpty(),
            row[MangaTable.artist].orEmpty(),
            row[MangaTable.description].orEmpty(),
            row[MangaTable.status],
        )

    class Remembered(
        val status: Int?,
        val ignored: Map<String, List<String>>,
    )

    private fun remembered(mangaId: Int? = null): Map<Int, Remembered> =
        db {
            val query = DochoSeriesFillTable.selectAll()
            if (mangaId != null) query.where { DochoSeriesFillTable.manga eq mangaId }
            query.associate {
                it[DochoSeriesFillTable.manga].value to
                    Remembered(
                        it[DochoSeriesFillTable.status],
                        runCatching { json.decodeFromString<Map<String, List<String>>>(it[DochoSeriesFillTable.ignored]) }.getOrDefault(emptyMap()),
                    )
            }
        }

    private suspend fun run(
        trackers: List<Tracker>,
        compareAll: Boolean,
    ) {
        SyncBridge.fillRecords().forEach { (key, value) ->
            val source = key.substringBefore('|').toLongOrNull() ?: return@forEach
            fromSync(source, key.substringAfter('|'), value)
        }
        val remembered = remembered()
        val rows =
            db {
                MangaTable
                    .selectAll()
                    .where { (MangaTable.inLibrary eq true) and (MangaTable.sourceReference neq SeriesGroups.SOURCE_ID) }
                    .map { Row(it[MangaTable.id].value, it[MangaTable.title], currentOf(it)) }
            }.filter { row ->
                val memory = remembered[row.id]
                SKIPPED !in memory?.ignored.orEmpty() && (compareAll || row.current.hasEmptyFields || memory?.status == row.current.status)
            }
        progress.update { it.copy(total = rows.size) }
        for (row in rows) {
            scan(row, trackers, remembered[row.id], compareAll)
            progress.update { it.copy(done = it.done + 1) }
        }
    }

    private suspend fun scan(
        row: Row,
        trackers: List<Tracker>,
        memory: Remembered?,
        compareAll: Boolean,
    ) {
        val lookup = lookUp(row, trackers, compareAll)
        if (lookup.failed > 0) progress.update { it.copy(failed = it.failed + lookup.failed) }
        val item =
            when {
                // Nothing is missing, so not knowing which series it is doesn't matter
                lookup.matches.isEmpty() && !row.current.hasEmptyFields -> null
                lookup.several.isNotEmpty() ->
                    TrackerFillItem(row.id, row.title, TrackerFillProblem.SEVERAL_MATCHES, candidates = lookup.several + lookup.matches)
                lookup.matches.isNotEmpty() ->
                    itemOf(row.id, row.title, review(row.current, lookup.matches, memory?.status, memory?.ignored.orEmpty()))
                        ?: run {
                            progress.update { it.copy(unchanged = it.unchanged + 1) }
                            null
                        }
                // A tracker that couldn't be reached says nothing about whether there's a match
                lookup.failed > 0 && lookup.suggestions.isEmpty() -> null
                else -> TrackerFillItem(row.id, row.title, TrackerFillProblem.NO_MATCH, candidates = lookup.suggestions)
            }
        item?.let(::save)
    }

    /** The entries a series is linked to; else exact title matches, until nothing's missing. */
    private suspend fun lookUp(
        row: Row,
        trackers: List<Tracker>,
        compareAll: Boolean,
    ): Lookup {
        val linked = linked(row.id, trackers, pause = true)
        if (linked.matches.isNotEmpty()) return linked
        val matches = mutableListOf<TrackerMatch>()
        val suggestions = mutableListOf<TrackerMatch>()
        var failed = linked.failed
        val wanted = comparable(row.title)
        for (tracker in trackers) {
            try {
                val results = tracker.search(row.title)
                val exact = if (wanted.isEmpty()) emptyList() else results.filter { comparable(it.title) == wanted }
                when {
                    exact.size == 1 -> matches += withDetails(tracker, exact.single()).toMatch(tracker, linked = false)
                    exact.size > 1 -> {
                        val several = exact.take(RESULTS_PER_TRACKER).map { withDetails(tracker, it).toMatch(tracker, linked = false) }
                        return Lookup(matches, failed, several = several)
                    }
                    else ->
                        suggestions +=
                            results.take(SUGGESTIONS_PER_TRACKER).map { it.toMatch(tracker, linked = false, complete = tracker !is MangaUpdates) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                logger.warn(e) { "Could not search for ${row.title} on ${tracker.name}" }
                failed++
            }
            delay(PAUSE)
            if (isComplete(row.current, matches, compareAll)) break
        }
        return Lookup(matches, failed, suggestions = suggestions)
    }

    private fun isComplete(
        current: Current,
        matches: List<TrackerMatch>,
        compareAll: Boolean,
    ) = ((!compareAll && !isEmptyName(current.writers)) || matches.any { it.writers.isNotEmpty() }) &&
        ((!compareAll && !isEmptyName(current.artists)) || matches.any { it.artists.isNotEmpty() }) &&
        (current.summary.isNotBlank() || matches.any { it.summary.isNotBlank() }) &&
        matches.any { it.status != UNKNOWN }

    // ---- The review list ----

    private fun save(item: TrackerFillItem) {
        db {
            DochoTrackerFillItemTable.upsert {
                it[manga] = item.mangaId
                it[problem] = item.problem.name
                it[data] = json.encodeToString(item)
            }
        }
    }

    private fun item(mangaId: Int): TrackerFillItem =
        db {
            DochoTrackerFillItemTable
                .selectAll()
                .where { DochoTrackerFillItemTable.manga eq mangaId }
                .firstOrNull()
                ?.get(DochoTrackerFillItemTable.data)
        }?.let { json.decodeFromString<TrackerFillItem>(it) } ?: throw IllegalArgumentException("That series isn't on the review list any more")

    private fun remove(mangaId: Int) {
        db { DochoTrackerFillItemTable.deleteWhere { manga eq mangaId } }
    }

    private fun remember(
        mangaId: Int,
        filledStatus: Int?,
        ignore: Map<String, List<String>>,
    ) {
        val memory = remembered(mangaId)[mangaId]
        val ignored = memory?.ignored.orEmpty().toMutableMap()
        ignore.forEach { (key, values) -> ignored[key] = (ignored[key].orEmpty() + values).distinct() }
        db {
            DochoSeriesFillTable.upsert {
                it[manga] = mangaId
                it[status] = filledStatus ?: memory?.status
                it[DochoSeriesFillTable.ignored] = json.encodeToString(ignored.toMap())
            }
        }
        SyncBridge.publishFill(mangaId)
    }

    /** The item as it stands now. */
    private fun current(mangaId: Int): TrackerFillItem {
        settle(mangaId)
        return item(mangaId)
    }

    /**
     * Settles an item: each field takes its choice, or keeps what it has if there's none. Options
     * not taken are remembered, so they aren't asked about again.
     */
    fun resolve(
        mangaId: Int,
        choices: List<TrackerFillChoice>,
    ) {
        val item = current(mangaId)
        val set = mutableMapOf<SeriesMetadata.Field, JsonElement>()
        val ignore = mutableMapOf<String, List<String>>()
        for (change in item.changes) {
            val value = choices.firstOrNull { it.field == change.field }?.value
            require(value == null || change.options.any { it.value == value }) { "${change.field.key} has no such option" }
            value?.let { set[change.field] = fieldValue(change.field, it) }
            ignore[change.field.key] =
                if (change.field == SeriesMetadata.Field.SUMMARY) {
                    if (value == null) listOf(KEPT) else emptyList()
                } else {
                    change.options.map { it.value }.filter { it != value }.map { optionKey(change.field, it) }
                }
        }
        if (item.picked) ignore[SKIPPED] = listOf(KEPT)
        if (set.isNotEmpty()) SeriesMetadata.edit(mangaId, SeriesMetadata.Edit(set, emptySet()))
        val status = choices.firstOrNull { it.field == SeriesMetadata.Field.STATUS }?.value?.toIntOrNull()
        remove(mangaId)
        remember(mangaId, status, ignore)
    }

    /** Takes an item off the list, keeping what the series has; one with no match isn't scanned again. */
    fun skip(mangaId: Int) {
        val item = current(mangaId)
        if (item.changes.isEmpty()) {
            remove(mangaId)
            remember(mangaId, null, mapOf(SKIPPED to listOf(KEPT)))
        } else {
            resolve(mangaId, emptyList())
        }
    }

    /**
     * Applies everything that's ready. A series that changed since the scan is left out, as what
     * was reviewed no longer holds; the next scan looks at it again.
     */
    fun applyReady(): TrackerFillResult {
        var applied = 0
        var failed = 0
        val series =
            db {
                MangaTable.selectAll().associate { it[MangaTable.id].value to currentOf(it) }
            }
        for (item in items().filter { it.problem == TrackerFillProblem.READY }) {
            val current = series[item.mangaId]
            if (current == null || !sameAsScanned(item, current)) {
                remove(item.mangaId)
                continue
            }
            try {
                resolve(item.mangaId, item.changes.map { TrackerFillChoice(it.field, it.options.first().value) })
                applied++
            } catch (e: Exception) {
                logger.warn(e) { "Could not save details for ${item.title}" }
                failed++
            }
        }
        return TrackerFillResult(applied, failed)
    }

    private fun sameAsScanned(
        item: TrackerFillItem,
        current: Current,
    ) = item.changes.all { change ->
        when (change.field) {
            SeriesMetadata.Field.WRITERS -> change.current == current.writers
            SeriesMetadata.Field.ARTISTS -> change.current == current.artists
            SeriesMetadata.Field.SUMMARY -> current.summary.isBlank()
            SeriesMetadata.Field.STATUS -> change.current == current.status.toString()
            else -> true
        }
    }

    /** Takes every conflict off the list, keeping what the series have. */
    fun dismissConflicts(): TrackerFillResult {
        var dismissed = 0
        for (item in items().filter { it.problem != TrackerFillProblem.READY }) {
            skip(item.mangaId)
            dismissed++
        }
        return TrackerFillResult(dismissed, 0)
    }

    /** Takes a series on an item with no clear match as [index] of its candidates. Null if that has nothing to add. */
    suspend fun pick(
        mangaId: Int,
        index: Int,
    ): TrackerFillItem? {
        val item = item(mangaId)
        val candidate = item.candidates.getOrNull(index) ?: throw IllegalArgumentException("No such match")
        val match =
            if (candidate.complete) {
                candidate
            } else {
                (TrackerManager.getTracker(candidate.trackerId) as? MangaUpdates)
                    ?.let { it.details(candidate.remoteId).toMatch(it, linked = false) }
                    ?: candidate
            }
        val current =
            db { MangaTable.selectAll().where { MangaTable.id eq mangaId }.first().let(::currentOf) }
        val picked = itemOf(mangaId, item.title, review(current, listOf(match), remembered(mangaId)[mangaId]?.status))?.copy(picked = true)
        if (picked == null) {
            remove(mangaId)
            remember(mangaId, null, mapOf(SKIPPED to listOf(KEPT)))
        } else {
            save(picked)
        }
        return picked
    }

    /** Replaces an item's candidates with search results for [query], when none of them is the series. */
    suspend fun searchFor(
        mangaId: Int,
        query: String,
    ): TrackerFillItem {
        val found = search(requireTrackers(), query.trim())
        val item =
            item(mangaId).copy(
                problem = if (found.isEmpty()) TrackerFillProblem.NO_MATCH else TrackerFillProblem.SEVERAL_MATCHES,
                changes = emptyList(),
                candidates = found,
            )
        save(item)
        return item
    }
}
