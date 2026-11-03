package suwayomi.tachidesk.docho.sync

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import org.jetbrains.exposed.v1.core.JoinType
import org.jetbrains.exposed.v1.core.Op
import org.jetbrains.exposed.v1.core.ResultRow
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.greaterEq
import org.jetbrains.exposed.v1.core.inList
import org.jetbrains.exposed.v1.core.lowerCase
import org.jetbrains.exposed.v1.core.neq
import org.jetbrains.exposed.v1.core.or
import org.jetbrains.exposed.v1.jdbc.select
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.DochoSyncRecordTable
import suwayomi.tachidesk.docho.DochoSyncUserTable
import suwayomi.tachidesk.docho.library.Libraries
import suwayomi.tachidesk.docho.library.SeriesMetadata
import suwayomi.tachidesk.manga.model.table.ChapterTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import kotlin.time.Duration.Companion.seconds

/**
 * Joins the server's own reading to Dōchō Sync, so the WebUI and the apps share read progress.
 *
 * One sync account is linked to the server: DOCHO_SYNC_SERVER_ACCOUNT names it, or else it's the
 * first account made ("none" turns this off). The apps already keep the server's source ids and
 * series and chapter URLs, so a record such as `chapter <source>|<chapter url>` names a chapter in
 * the server's database directly, for library series and for extension series alike.
 *
 * - From the apps: when the linked account syncs, its chapter and history records are applied to
 *   the server's chapters (read, bookmark, page, last read), and series added to or removed from
 *   the apps' library are added to or removed from the server's (not library series, which are
 *   always there).
 * - To the apps: every few seconds the server looks for chapters read in the WebUI and writes
 *   them as records from the device "docho-server". Edited series details go as "details" records.
 *
 * The newest change wins either way, as between devices.
 */
object SyncBridge {
    const val DEVICE = "docho-server"
    const val DETAILS = "details"
    private const val CHAPTER = "chapter"
    private const val HISTORY = "history"
    private const val MANGA = "manga"

    private val logger = KotlinLogging.logger {}
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Chapters changed at or after this (seconds) are looked at next; 0 means all of them. */
    @Volatile
    private var watermark = 0L

    @Volatile
    private var linkedFor: Int? = null

    fun start() {
        scope.launch {
            delay(15.seconds)
            while (true) {
                try {
                    pass()
                } catch (e: Exception) {
                    logger.warn(e) { "Dōchō Sync bridge pass failed" }
                }
                delay(10.seconds)
            }
        }
    }

    /** The account the server's progress follows, or null if there's none (yet) or it's off. */
    fun linkedUserId(): Int? {
        val name = System.getenv("DOCHO_SYNC_SERVER_ACCOUNT")?.trim()?.ifEmpty { null }
        if (name.equals("none", ignoreCase = true)) return null
        return transaction {
            val query = DochoSyncUserTable.selectAll()
            if (name != null) query.where { DochoSyncUserTable.username.lowerCase() eq name.lowercase() }
            query
                .orderBy(DochoSyncUserTable.id to SortOrder.ASC)
                .limit(1)
                .firstOrNull()
                ?.get(DochoSyncUserTable.id)
                ?.value
        }
    }

    fun isLinked(userId: Int) = linkedUserId() == userId

    // ---- The server's chapters ----

    private data class ServerChapter(
        val chapterId: Int,
        val mangaId: Int,
        val source: Long,
        val mangaUrl: String,
        val url: String,
        val read: Boolean,
        val bookmark: Boolean,
        val page: Int,
        val lastReadAt: Long,
        val modifiedAt: Long,
    ) {
        val key get() = "$source|$url"

        /** As the apps write it (SyncValues.chapter): the page is 0 once read. */
        fun value(): String =
            DochoSync.canonical(
                JsonObject(
                    mapOf(
                        "bookmark" to JsonPrimitive(bookmark),
                        "manga" to JsonPrimitive(mangaUrl),
                        "page" to JsonPrimitive(if (read) 0L else page.toLong()),
                        "read" to JsonPrimitive(read),
                    ),
                ),
            )

        fun history(): String =
            DochoSync.canonical(JsonObject(mapOf("manga" to JsonPrimitive(mangaUrl), "readAt" to JsonPrimitive(lastReadAt * 1000))))
    }

    private val chapterColumns =
        listOf(
            ChapterTable.id,
            ChapterTable.url,
            ChapterTable.isRead,
            ChapterTable.isBookmarked,
            ChapterTable.lastPageRead,
            ChapterTable.lastReadAt,
            ChapterTable.lastModifiedAt,
            MangaTable.id,
            MangaTable.sourceReference,
            MangaTable.url,
        )

    private fun serverChapters(where: () -> Op<Boolean>): List<ServerChapter> =
        ChapterTable
            .join(MangaTable, JoinType.INNER, ChapterTable.manga, MangaTable.id)
            .select(chapterColumns)
            .where(where)
            .map(::toServerChapter)

    private fun toServerChapter(row: ResultRow) =
        ServerChapter(
            chapterId = row[ChapterTable.id].value,
            mangaId = row[MangaTable.id].value,
            source = row[MangaTable.sourceReference],
            mangaUrl = row[MangaTable.url],
            url = row[ChapterTable.url],
            read = row[ChapterTable.isRead],
            bookmark = row[ChapterTable.isBookmarked],
            page = row[ChapterTable.lastPageRead],
            lastReadAt = row[ChapterTable.lastReadAt],
            modifiedAt = row[ChapterTable.lastModifiedAt],
        )

    private fun findChapter(
        source: Long,
        mangaUrl: String,
        url: String,
    ): ServerChapter? =
        serverChapters {
            (MangaTable.sourceReference eq source) and (MangaTable.url eq mangaUrl) and (ChapterTable.url eq url)
        }.firstOrNull()

    private class Record(
        val value: String?,
        val updatedAt: Long,
    )

    private fun records(
        userId: Int,
        kind: String,
        keys: Collection<String>,
    ): Map<String, Record> =
        keys.chunked(500).flatMap { chunk ->
            DochoSyncRecordTable
                .selectAll()
                .where { (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.kind eq kind) and (DochoSyncRecordTable.key inList chunk) }
                .map { it[DochoSyncRecordTable.key] to Record(it[DochoSyncRecordTable.value], it[DochoSyncRecordTable.updatedAt]) }
        }.toMap()

    private fun obj(value: String?): JsonObject? = value?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() }

    private fun JsonObject.bool(name: String) = (this[name] as? JsonPrimitive)?.booleanOrNull == true

    private fun JsonObject.long(name: String) = (this[name] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.string(name: String) = (this[name] as? JsonPrimitive)?.contentOrNull

    /** Puts a chapter record's state on the server's chapter. */
    private fun applyChapter(
        chapter: ServerChapter,
        value: JsonObject,
    ) {
        val read = value.bool("read")
        ChapterTable.update({ ChapterTable.id eq chapter.chapterId }) {
            it[isRead] = read
            it[isBookmarked] = value.bool("bookmark")
            // A read chapter's page is 0 in the apps' records; keep the server's.
            if (!read) it[lastPageRead] = (value.long("page") ?: 0).toInt().coerceAtLeast(0)
        }
    }

    private fun applyHistory(
        chapter: ServerChapter,
        readAtMillis: Long,
    ) {
        val seconds = readAtMillis / 1000
        if (seconds <= chapter.lastReadAt) return
        ChapterTable.update({ ChapterTable.id eq chapter.chapterId }) { it[lastReadAt] = seconds }
    }

    // ---- From the apps ----

    /**
     * Applies what the linked account's devices just sent to the server's own chapters and library.
     * Runs inside [DochoSync.sync]'s transaction. Returns records to store back, where the server
     * changed a chapter after the device did.
     */
    fun fromDevices(stored: List<DochoSync.Stored>): List<DochoSync.Change> {
        val corrections = mutableListOf<DochoSync.Change>()
        for (change in stored) {
            if (change.device == DEVICE) continue
            val source = change.key.substringBefore('|').toLongOrNull() ?: continue
            val url = change.key.substringAfter('|')
            try {
                when (change.kind) {
                    CHAPTER -> {
                        val value = obj(change.value) ?: continue
                        val chapter = findChapter(source, value.string("manga") ?: continue, url) ?: continue
                        val here = chapter.value()
                        if (here == change.value) continue
                        val serverIsNewer = chapter.modifiedAt * 1000 > change.updatedAt && !DochoSync.isUntouched(here)
                        if (serverIsNewer) {
                            corrections += DochoSync.Change(CHAPTER, chapter.key, here, change.updatedAt + 1)
                        } else {
                            applyChapter(chapter, value)
                        }
                    }
                    HISTORY -> {
                        val value = obj(change.value) ?: continue
                        val chapter = findChapter(source, value.string("manga") ?: continue, url) ?: continue
                        applyHistory(chapter, value.long("readAt") ?: continue)
                    }
                    MANGA -> applyLibrary(source, url, inLibrary = change.value != null)
                }
            } catch (e: Exception) {
                logger.warn(e) { "Couldn't apply ${change.kind} ${change.key} to the server" }
            }
        }
        return corrections
    }

    /** Series added in the apps join the server's library, and leave it when removed there. */
    private fun applyLibrary(
        source: Long,
        url: String,
        inLibrary: Boolean,
    ) {
        // Library series are always in the library, and grouped ones are hidden on purpose.
        if (Libraries.isDochoSource(source)) return
        val row =
            MangaTable
                .selectAll()
                .where { (MangaTable.sourceReference eq source) and (MangaTable.url eq url) }
                .firstOrNull() ?: return
        if (row[MangaTable.inLibrary] == inLibrary) return
        MangaTable.update({ MangaTable.id eq row[MangaTable.id] }) {
            it[MangaTable.inLibrary] = inLibrary
            if (inLibrary) it[inLibraryAt] = System.currentTimeMillis() / 1000
        }
    }

    // ---- To the apps ----

    /** Writes records for chapters changed on the server since the last pass. */
    private fun pass() {
        val userId = linkedUserId() ?: return
        if (linkedFor != userId) {
            linkedFor = userId
            watermark = 0
        }
        val started = System.currentTimeMillis() / 1000
        val since = watermark
        synchronized(DochoSync) {
            val changes = mutableListOf<DochoSync.Change>()
            transaction {
                val chapters =
                    serverChapters {
                        if (since == 0L) {
                            Op.TRUE
                        } else {
                            (ChapterTable.lastModifiedAt greaterEq since - 1) or (ChapterTable.lastReadAt greaterEq since - 1)
                        }
                    }
                val keys = chapters.map { it.key }
                val chapterRecords = records(userId, CHAPTER, keys)
                val historyRecords = records(userId, HISTORY, keys)
                for (chapter in chapters) {
                    val here = chapter.value()
                    val record = chapterRecords[chapter.key]
                    when {
                        record == null || record.value == null ->
                            if (!DochoSync.isUntouched(here)) {
                                changes += DochoSync.Change(CHAPTER, chapter.key, here, (chapter.modifiedAt * 1000).takeIf { it > 0 } ?: System.currentTimeMillis())
                            }
                        record.value == here -> Unit
                        // A device changed it after the server did, and it wasn't applied yet.
                        record.updatedAt > chapter.modifiedAt * 1000 + 999 -> obj(record.value)?.let { applyChapter(chapter, it) }
                        else -> changes += DochoSync.Change(CHAPTER, chapter.key, here, maxOf(chapter.modifiedAt * 1000, record.updatedAt + 1))
                    }
                    if (chapter.lastReadAt > 0) {
                        val history = historyRecords[chapter.key]
                        val theirs = obj(history?.value)?.long("readAt")
                        when {
                            theirs == null ->
                                changes += DochoSync.Change(HISTORY, chapter.key, chapter.history(), maxOf(chapter.lastReadAt * 1000, (history?.updatedAt ?: 0) + 1))
                            theirs / 1000 < chapter.lastReadAt ->
                                changes += DochoSync.Change(HISTORY, chapter.key, chapter.history(), maxOf(chapter.lastReadAt * 1000, history!!.updatedAt + 1))
                            theirs / 1000 > chapter.lastReadAt -> applyHistory(chapter, theirs)
                        }
                    }
                }
                if (since == 0L) {
                    val edited =
                        DochoSeriesInfoTable
                            .select(DochoSeriesInfoTable.manga)
                            .where { DochoSeriesInfoTable.overrides neq "{}" }
                            .map { it[DochoSeriesInfoTable.manga].value }
                    edited.mapNotNullTo(changes) { detailsChange(userId, it) }
                }
            }
            if (changes.isNotEmpty()) {
                DochoSync.storeFromServer(userId, changes)
                logger.info { "Dōchō Sync: sent ${changes.size} change(s) from the server" }
            }
        }
        watermark = started
    }

    /** Sends a series' details after they were edited (or reset) on the server. */
    fun publishDetails(mangaId: Int) {
        val userId = linkedUserId() ?: return
        synchronized(DochoSync) {
            val change = transaction { detailsChange(userId, mangaId) } ?: return
            DochoSync.storeFromServer(userId, listOf(change))
        }
    }

    /**
     * A "details" record for a series: its title, people, summary, genres and status, for the
     * apps to show. Null if nothing changed, or the series was never edited.
     */
    private fun detailsChange(
        userId: Int,
        mangaId: Int,
    ): DochoSync.Change? {
        val manga = MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull() ?: return null
        val edited = SeriesMetadata.overridesOf(mangaId).values.isNotEmpty()
        val key = "${manga[MangaTable.sourceReference]}|${manga[MangaTable.url]}"
        val record = records(userId, DETAILS, listOf(key))[key]
        if (!edited && record == null) return null
        val fields = mutableMapOf<String, JsonElement>("title" to JsonPrimitive(manga[MangaTable.title]))
        manga[MangaTable.author]?.let { fields["author"] = JsonPrimitive(it) }
        manga[MangaTable.artist]?.let { fields["artist"] = JsonPrimitive(it) }
        manga[MangaTable.description]?.let { fields["description"] = JsonPrimitive(it) }
        fields["genres"] = JsonArray(manga[MangaTable.genre].orEmpty().split(",").map { it.trim() }.filter { it.isNotEmpty() }.map(::JsonPrimitive))
        fields["status"] = JsonPrimitive(manga[MangaTable.status].toLong())
        val value = DochoSync.canonical(JsonObject(fields))
        if (record?.value == value) return null
        return DochoSync.Change(DETAILS, key, value, maxOf(System.currentTimeMillis(), (record?.updatedAt ?: 0) + 1))
    }
}
