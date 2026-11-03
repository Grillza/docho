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
import suwayomi.tachidesk.docho.DochoLibraryTable
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.DochoSyncRecordTable
import suwayomi.tachidesk.docho.DochoSyncUserTable
import suwayomi.tachidesk.docho.library.Libraries
import suwayomi.tachidesk.docho.library.SeriesMetadata
import suwayomi.tachidesk.manga.impl.Category
import suwayomi.tachidesk.manga.impl.util.source.GetSource.getSourceOrStub
import suwayomi.tachidesk.manga.impl.util.updateMangaDownloadDir
import suwayomi.tachidesk.manga.impl.CategoryManga
import suwayomi.tachidesk.manga.model.table.CategoryMangaTable
import suwayomi.tachidesk.manga.model.table.CategoryTable
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
    private const val CATEGORY = "category"
    private const val RENAME = "rename"
    private const val KIND = "kind"

    /** The chapter memo key the apps keep a chapter's Volume/Chapter type under. */
    private const val MEMO_KIND = "kind"

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

    private fun JsonObject.strings(name: String) = (this[name] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()

    private fun chapterIds(
        source: Long,
        url: String,
    ): List<Int> =
        ChapterTable
            .join(MangaTable, JoinType.INNER, ChapterTable.manga, MangaTable.id)
            .select(ChapterTable.id)
            .where { (MangaTable.sourceReference eq source) and (ChapterTable.url eq url) }
            .map { it[ChapterTable.id].value }

    private fun mangaRow(
        source: Long,
        url: String,
    ): ResultRow? =
        MangaTable
            .selectAll()
            .where { (MangaTable.sourceReference eq source) and (MangaTable.url eq url) }
            .firstOrNull()

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
            if (change.kind == CATEGORY) {
                runCatching { applyCategory(change.key, exists = change.value != null) }
                    .onFailure { logger.warn(it) { "Couldn't apply category ${change.key} to the server" } }
                continue
            }
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
                    MANGA -> {
                        applyLibrary(source, url, inLibrary = change.value != null)
                        obj(change.value)?.let { applySeriesCategories(source, url, it.strings("categories")) }
                    }
                    RENAME -> applyRename(source, url, obj(change.value), obj(change.previous))
                    KIND -> applyKind(source, url, obj(change.value)?.string("kind"))
                    DETAILS -> applyDetails(source, url, obj(change.value))
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

    /** A chapter renamed in the apps takes that name and number here too; dropped, its old name. */
    private fun applyRename(
        source: Long,
        url: String,
        value: JsonObject?,
        previous: JsonObject?,
    ) {
        val ids = chapterIds(source, url).ifEmpty { return }
        val name = value?.string("name") ?: previous?.string("original") ?: return
        val number = value?.string("number")?.toFloatOrNull()
        ChapterTable.update({ ChapterTable.id inList ids }) {
            it[ChapterTable.name] = name
            if (number != null) it[chapter_number] = number
        }
    }

    /** A chapter's Volume/Chapter type, kept in its memo as the apps keep it. */
    private fun applyKind(
        source: Long,
        url: String,
        kind: String?,
    ) {
        val rows =
            ChapterTable
                .join(MangaTable, JoinType.INNER, ChapterTable.manga, MangaTable.id)
                .select(ChapterTable.id, ChapterTable.memo)
                .where { (MangaTable.sourceReference eq source) and (ChapterTable.url eq url) }
                .toList()
        for (row in rows) {
            val memo = row[ChapterTable.memo]
            val updated = if (kind == null) JsonObject(memo - MEMO_KIND) else JsonObject(memo + (MEMO_KIND to JsonPrimitive(kind)))
            if (updated != memo) ChapterTable.update({ ChapterTable.id eq row[ChapterTable.id] }) { it[ChapterTable.memo] = updated }
        }
    }

    /** Series details edited in the apps: locked on a library series, written over any other. */
    private fun applyDetails(
        source: Long,
        url: String,
        value: JsonObject?,
    ) {
        val row = mangaRow(source, url) ?: return
        val mangaId = row[MangaTable.id].value
        val isLibrarySeries = DochoSeriesInfoTable.selectAll().where { DochoSeriesInfoTable.manga eq mangaId }.any()
        if (isLibrarySeries) {
            SeriesMetadata.fromSync(mangaId, value)
            return
        }
        // Other series take the source's details again on their next refresh once unlocked.
        value ?: return
        MangaTable.update({ MangaTable.id eq mangaId }) { writeDetails(it, value) }
        value.string("title")?.ifBlank { null }?.let { retitleLater(mangaId, it) }
    }

    /** Renames a series that isn't from a library, moving its downloads as Suwayomi does. */
    private fun retitleLater(
        mangaId: Int,
        title: String,
    ) {
        scope.launch {
            try {
                val row = transaction { MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull() } ?: return@launch
                val current = row[MangaTable.title]
                if (current == title) return@launch
                val source = getSourceOrStub(row[MangaTable.sourceReference])
                if (updateMangaDownloadDir(mangaId, current, source.toString(), title)) {
                    transaction { MangaTable.update({ MangaTable.id eq mangaId }) { it[MangaTable.title] = title.take(512) } }
                }
            } catch (e: Exception) {
                logger.warn(e) { "Couldn't retitle series $mangaId" }
            }
        }
    }

    /** The fields of a series that isn't from a library that were edited, by "details" key. */
    fun editedDetails(mangaId: Int): Set<String> {
        val userId = linkedUserId() ?: return emptySet()
        return transaction {
            val row = MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull() ?: return@transaction emptySet()
            val key = "${row[MangaTable.sourceReference]}|${row[MangaTable.url]}"
            obj(records(userId, DETAILS, listOf(key))[key]?.value)?.keys.orEmpty()
        }
    }

    /**
     * Edits a series that isn't from a library in the WebUI: written now, kept over what its
     * source sends, and sent to the apps. [reset] fields are unlocked; they come back from the
     * source on its next refresh.
     */
    fun editDetails(
        mangaId: Int,
        set: Map<String, JsonElement>,
        reset: Set<String>,
    ) {
        val userId = linkedUserId() ?: throw IllegalStateException("Make a Dōchō Sync account first; edits are kept with it")
        val title =
            synchronized(DochoSync) {
                transaction {
                    val row = MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull() ?: throw IllegalArgumentException("No such series")
                    val key = "${row[MangaTable.sourceReference]}|${row[MangaTable.url]}"
                    val record = records(userId, DETAILS, listOf(key))[key]
                    val fields = obj(record?.value).orEmpty().toMutableMap()
                    reset.forEach { fields.remove(it) }
                    fields.putAll(set)
                    val value = JsonObject(fields)
                    MangaTable.update({ MangaTable.id eq mangaId }) { writeDetails(it, value) }
                    val change =
                        DochoSync.Change(
                            DETAILS,
                            key,
                            if (fields.isEmpty()) null else DochoSync.canonical(value),
                            maxOf(System.currentTimeMillis(), (record?.updatedAt ?: 0) + 1),
                        )
                    if (change.value != record?.value) DochoSync.storeFromServer(userId, listOf(change))
                    value.string("title")?.ifBlank { null }
                }
            }
        title?.let { retitleLater(mangaId, it) }
    }

    /**
     * Renames a chapter, or sets its Volume/Chapter type, in the WebUI, and sends that to the apps
     * as they'd send it. A null [name] drops the rename and puts back the source's name; a null
     * [kind] lets the name decide again.
     */
    fun renameChapter(
        chapterId: Int,
        name: String?,
        number: Float?,
        kind: String?,
    ) {
        val userId = linkedUserId() ?: throw IllegalStateException("Make a Dōchō Sync account first; renames are kept with it")
        synchronized(DochoSync) {
            transaction {
                val chapter = serverChapters { ChapterTable.id eq chapterId }.firstOrNull() ?: throw IllegalArgumentException("No such chapter")
                val row = ChapterTable.selectAll().where { ChapterTable.id eq chapterId }.first()
                val key = chapter.key
                val now = System.currentTimeMillis()
                val changes = mutableListOf<DochoSync.Change>()
                val rename = records(userId, RENAME, listOf(key))[key]
                val previous = obj(rename?.value)
                if (name != null) {
                    val numberValue = number ?: row[ChapterTable.chapter_number]
                    val value =
                        JsonObject(
                            mapOf(
                                "at" to JsonPrimitive(now),
                                "manga" to JsonPrimitive(chapter.mangaUrl),
                                "name" to JsonPrimitive(name),
                                "number" to JsonPrimitive(numberText(numberValue)),
                                "original" to JsonPrimitive(previous?.string("original") ?: row[ChapterTable.name]),
                            ),
                        )
                    changes += DochoSync.Change(RENAME, key, DochoSync.canonical(value), maxOf(now, (rename?.updatedAt ?: 0) + 1))
                    applyRename(chapter.source, chapter.url, value, previous)
                } else if (rename?.value != null) {
                    changes += DochoSync.Change(RENAME, key, null, maxOf(now, rename.updatedAt + 1))
                    applyRename(chapter.source, chapter.url, null, previous)
                }
                val kindRecord = records(userId, KIND, listOf(key))[key]
                val kindValue =
                    kind?.let {
                        DochoSync.canonical(JsonObject(mapOf("kind" to JsonPrimitive(it), "manga" to JsonPrimitive(chapter.mangaUrl))))
                    }
                if (kindValue != kindRecord?.value) {
                    changes += DochoSync.Change(KIND, key, kindValue, maxOf(now, (kindRecord?.updatedAt ?: 0) + 1))
                    applyKind(chapter.source, chapter.url, kind)
                }
                if (changes.isNotEmpty()) DochoSync.storeFromServer(userId, changes)
            }
        }
    }

    data class ChapterEdit(
        val chapterId: Int,
        /** The name before it was renamed, or null if it wasn't. */
        val original: String?,
        /** "volume" or "chapter", or null if the name decides. */
        val kind: String?,
    )

    fun chapterEdits(mangaId: Int): List<ChapterEdit> {
        val userId = linkedUserId() ?: return emptyList()
        return transaction {
            val chapters = serverChapters { ChapterTable.manga eq mangaId }
            val keys = chapters.map { it.key }
            val renames = records(userId, RENAME, keys)
            val kinds = records(userId, KIND, keys)
            chapters.mapNotNull { chapter ->
                val rename = obj(renames[chapter.key]?.value)
                val kind = obj(kinds[chapter.key]?.value)?.string("kind")
                if (rename == null && kind == null) return@mapNotNull null
                ChapterEdit(chapter.chapterId, rename?.let { it.string("original") ?: "" }, kind)
            }
        }
    }

    /** "10" or "119.1", as the apps write chapter numbers (SyncValues.number). */
    private fun numberText(value: Float): String {
        val number = value.toString().toBigDecimal().stripTrailingZeros()
        return if (number.scale() <= 0) number.toBigInteger().toString() else number.toPlainString()
    }

    /**
     * Writes a "details" record's fields over a series; fields it doesn't have are left alone. Not
     * the title: that moves the series' download folder, so it changes on the next refresh
     * ([applyDetailsOverride]), the way Suwayomi changes titles.
     */
    private fun writeDetails(
        statement: org.jetbrains.exposed.v1.core.statements.UpdateStatement,
        value: JsonObject,
    ) {
        if ("author" in value) statement[MangaTable.author] = value.string("author")?.ifBlank { null }
        if ("artist" in value) statement[MangaTable.artist] = value.string("artist")?.ifBlank { null }
        if ("description" in value) statement[MangaTable.description] = value.string("description")?.ifBlank { null }
        if ("genres" in value) statement[MangaTable.genre] = value.strings("genres").joinToString(", ").ifBlank { null }
        value.long("status")?.let { statement[MangaTable.status] = it.toInt() }
    }

    /** The server's categories that stand for its libraries; those stay the server's own. */
    private fun libraryCategoryIds(): Set<Int> =
        DochoLibraryTable
            .select(DochoLibraryTable.categoryId)
            .mapNotNull { it[DochoLibraryTable.categoryId] }
            .toSet()

    /** The server's own categories by name: not Default, nor a library's. */
    private fun syncedCategories(): Map<String, Int> {
        val libraries = libraryCategoryIds()
        return CategoryTable
            .select(CategoryTable.id, CategoryTable.name)
            .map { it[CategoryTable.id].value to it[CategoryTable.name] }
            .filter { (id, _) -> id != Category.DEFAULT_CATEGORY_ID && id !in libraries }
            .associate { (id, name) -> name to id }
    }

    /** A category made or deleted in the apps. A library's category isn't deleted. */
    private fun applyCategory(
        name: String,
        exists: Boolean,
    ) {
        val here = syncedCategories()
        if (exists) {
            if (name !in here && libraryCategoryNames().none { it.equals(name, ignoreCase = true) }) {
                Category.createCategory(name.take(64))
            }
        } else {
            here[name]?.let { Category.removeCategory(it) }
        }
    }

    private fun libraryCategoryNames(): List<String> {
        val ids = libraryCategoryIds().ifEmpty { return emptyList() }
        return CategoryTable.select(CategoryTable.name).where { CategoryTable.id inList ids }.map { it[CategoryTable.name] }
    }

    /** A series' categories as the apps have them; its library's category stays. */
    private fun applySeriesCategories(
        source: Long,
        url: String,
        names: List<String>,
    ) {
        val row = mangaRow(source, url) ?: return
        if (!row[MangaTable.inLibrary]) return
        val mangaId = row[MangaTable.id].value
        val missing = names.filter { it !in syncedCategories() }
        if (missing.isNotEmpty()) Category.createCategories(missing.map { it.take(64) })
        val byName = syncedCategories()
        val wanted = names.mapNotNull { byName[it] }.toSet()
        val current = seriesCategoryIds(mangaId).filter { it in byName.values }.toSet()
        (current - wanted).forEach { CategoryManga.removeMangaFromCategory(mangaId, it) }
        (wanted - current).takeIf { it.isNotEmpty() }?.let { CategoryManga.addMangaToCategories(mangaId, it.toList()) }
    }

    private fun seriesCategoryIds(mangaId: Int): List<Int> =
        CategoryMangaTable
            .select(CategoryMangaTable.category)
            .where { CategoryMangaTable.manga eq mangaId }
            .map { it[CategoryMangaTable.category].value }

    // ---- Kept over what sources and scans send ----

    /**
     * Puts the linked account's chapter renames and types over chapters a source (or a library
     * scan) just sent, before they're saved, so a refresh doesn't undo them. As ChapterRenames
     * does in the apps.
     */
    fun applyChapterOverrides(
        sourceId: Long,
        chapters: List<eu.kanade.tachiyomi.source.model.SChapter>,
    ) {
        val userId = linkedUserId() ?: return
        val keys = chapters.map { "$sourceId|${it.url}" }
        val (renames, kinds) = transaction { records(userId, RENAME, keys) to records(userId, KIND, keys) }
        if (renames.isEmpty() && kinds.isEmpty()) return
        for (chapter in chapters) {
            val key = "$sourceId|${chapter.url}"
            obj(renames[key]?.value)?.let { rename ->
                rename.string("name")?.let { chapter.name = it }
                rename.string("number")?.toFloatOrNull()?.let { chapter.chapter_number = it }
            }
            obj(kinds[key]?.value)?.string("kind")?.let { kind ->
                chapter.memo = JsonObject(chapter.memo + (MEMO_KIND to JsonPrimitive(kind)))
            }
        }
    }

    /**
     * Puts details edited in the apps over what a source just sent for a series that isn't from a
     * library (library series keep their edits as locked fields instead, see [SeriesMetadata]).
     */
    fun applyDetailsOverride(
        sourceId: Long,
        url: String,
        manga: eu.kanade.tachiyomi.source.model.SManga,
    ) {
        if (Libraries.isDochoSource(sourceId)) return
        val userId = linkedUserId() ?: return
        val key = "$sourceId|$url"
        val value = obj(transaction { records(userId, DETAILS, listOf(key)) }[key]?.value) ?: return
        value.string("title")?.ifBlank { null }?.let { manga.title = it }
        if ("author" in value) manga.author = value.string("author")?.ifBlank { null }
        if ("artist" in value) manga.artist = value.string("artist")?.ifBlank { null }
        if ("description" in value) manga.description = value.string("description")?.ifBlank { null }
        if ("genres" in value) manga.genre = value.strings("genres").joinToString(", ").ifBlank { null }
        value.long("status")?.let { manga.status = it.toInt() }
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
                libraryChanges(userId, since, changes)
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

    /** Every record of [kind] the account has, by key. */
    private fun allRecords(
        userId: Int,
        kind: String,
    ): Map<String, Record> =
        DochoSyncRecordTable
            .selectAll()
            .where { (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.kind eq kind) }
            .associate { it[DochoSyncRecordTable.key] to Record(it[DochoSyncRecordTable.value], it[DochoSyncRecordTable.updatedAt]) }

    private fun mangaValue(
        title: String,
        categories: Collection<String>,
        addedAt: Long,
    ): String =
        DochoSync.canonical(
            JsonObject(
                mapOf(
                    "addedAt" to JsonPrimitive(addedAt),
                    "categories" to JsonArray(categories.distinct().sorted().map(::JsonPrimitive)),
                    "title" to JsonPrimitive(title),
                ),
            ),
        )

    /**
     * Categories, and series added to, removed from or moved between categories in the WebUI, as
     * the apps' category and manga records. Where a device changed a series after the server did,
     * the device's version is put on the server instead. The first pass for an account merges:
     * nothing is removed, what's on either side ends up on both.
     *
     * Library series (from the server's own libraries) are only sent once a device has them, so
     * the apps' libraries don't fill with every book on the server. Library categories and
     * Default stay the server's own.
     */
    private fun libraryChanges(
        userId: Int,
        since: Long,
        changes: MutableList<DochoSync.Change>,
    ) {
        val merge = since == 0L
        val now = System.currentTimeMillis()
        val reserved = (libraryCategoryNames() + Category.DEFAULT_CATEGORY_NAME).map { it.lowercase() }.toSet()
        fun isReserved(name: String) = name.lowercase() in reserved

        // Categories
        val categoryRecords = allRecords(userId, CATEGORY)
        var here = syncedCategories()
        var categoriesChanged = false
        for ((name, record) in categoryRecords) {
            if (record.value == null || name in here || isReserved(name)) continue
            if (merge) {
                applyCategory(name, exists = true)
            } else {
                changes += DochoSync.Change(CATEGORY, name, null, maxOf(now, record.updatedAt + 1))
                categoriesChanged = true
            }
        }
        here = syncedCategories()
        for (name in here.keys) {
            val record = categoryRecords[name]
            if (record?.value != null) continue
            changes += DochoSync.Change(CATEGORY, name, "{}", maxOf(now, (record?.updatedAt ?: 0) + 1))
            categoriesChanged = true
        }

        // Series
        val names = CategoryTable.select(CategoryTable.id, CategoryTable.name).associate { it[CategoryTable.id].value to it[CategoryTable.name] }
        val synced = here.values.toSet()
        val mangaRecords = allRecords(userId, MANGA)
        val rows =
            MangaTable
                .select(
                    MangaTable.id,
                    MangaTable.sourceReference,
                    MangaTable.url,
                    MangaTable.title,
                    MangaTable.inLibrary,
                    MangaTable.inLibraryAt,
                    MangaTable.lastModifiedAt,
                ).where {
                    if (merge || categoriesChanged) {
                        MangaTable.inLibrary eq true
                    } else {
                        MangaTable.lastModifiedAt greaterEq since - 1
                    }
                }.toList()
        for (row in rows) {
            val source = row[MangaTable.sourceReference]
            val url = row[MangaTable.url]
            val key = "$source|$url"
            val mangaId = row[MangaTable.id].value
            val record = mangaRecords[key]
            val theirs = obj(record?.value)
            val isLibrarySeries = Libraries.isDochoSource(source)
            val serverIsNewer = row[MangaTable.lastModifiedAt] * 1000 >= (record?.updatedAt ?: 0)
            if (row[MangaTable.inLibrary]) {
                if (theirs == null) {
                    if (isLibrarySeries) continue
                    if (record != null && !serverIsNewer) {
                        // Removed on a device after the server last changed it.
                        applyLibrary(source, url, inLibrary = false)
                        continue
                    }
                    val categories = seriesCategoryIds(mangaId).filter { it in synced }.mapNotNull { names[it] }
                    val addedAt = row[MangaTable.inLibraryAt].takeIf { it > 0 }?.times(1000) ?: now
                    changes += DochoSync.Change(MANGA, key, mangaValue(row[MangaTable.title], categories, addedAt), maxOf(now, (record?.updatedAt ?: 0) + 1))
                    continue
                }
                val ours = seriesCategoryIds(mangaId).filter { it in synced }.mapNotNull { names[it] }.toSet()
                val theirNames = theirs.strings("categories")
                val theirsHere = theirNames.filterNot(::isReserved).toSet()
                if (ours == theirsHere) continue
                val wanted =
                    when {
                        merge -> ours + theirsHere
                        serverIsNewer -> ours
                        else -> theirsHere
                    }
                if (wanted != ours) applySeriesCategories(source, url, wanted.toList())
                if (wanted == theirsHere) continue
                // Their reserved names (a category named like a library) are kept as they were.
                val categories = wanted + theirNames.filter(::isReserved)
                val value = mangaValue(theirs.string("title") ?: row[MangaTable.title], categories, theirs.long("addedAt") ?: 0)
                changes += DochoSync.Change(MANGA, key, value, maxOf(now, record!!.updatedAt + 1))
            } else if (theirs != null && !isLibrarySeries) {
                // A row made after the device added the series, or a first pass: take the device's.
                if (merge || row[MangaTable.inLibraryAt] == 0L || !serverIsNewer) {
                    applyLibrary(source, url, inLibrary = true)
                    applySeriesCategories(source, url, theirs.strings("categories"))
                } else {
                    changes += DochoSync.Change(MANGA, key, null, maxOf(now, record!!.updatedAt + 1))
                }
            }
        }
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
        if (!DochoSeriesInfoTable.selectAll().where { DochoSeriesInfoTable.manga eq mangaId }.any()) return null
        val key = "${manga[MangaTable.sourceReference]}|${manga[MangaTable.url]}"
        val record = records(userId, DETAILS, listOf(key))[key]
        val now = maxOf(System.currentTimeMillis(), (record?.updatedAt ?: 0) + 1)
        // Every edit reset: the apps unlock the details too.
        if (!edited) return if (record?.value != null) DochoSync.Change(DETAILS, key, null, now) else null
        // The edited fields the apps know, blank ones as "", as the apps write them.
        val locked = SeriesMetadata.overridesOf(mangaId).values.keys
        val fields = mutableMapOf<String, JsonElement>()
        for ((name, field) in SeriesMetadata.syncedFields) {
            if (field !in locked) continue
            fields[name] =
                when (name) {
                    "title" -> JsonPrimitive(manga[MangaTable.title])
                    "author" -> JsonPrimitive(manga[MangaTable.author].orEmpty())
                    "artist" -> JsonPrimitive(manga[MangaTable.artist].orEmpty())
                    "description" -> JsonPrimitive(manga[MangaTable.description].orEmpty())
                    "genres" -> JsonArray(manga[MangaTable.genre].orEmpty().split(",").map { it.trim() }.filter { it.isNotEmpty() }.map(::JsonPrimitive))
                    else -> JsonPrimitive(manga[MangaTable.status].toLong())
                }
        }
        if (fields.isEmpty()) return if (record?.value != null) DochoSync.Change(DETAILS, key, null, now) else null
        val value = DochoSync.canonical(JsonObject(fields))
        if (record?.value == value) return null
        return DochoSync.Change(DETAILS, key, value, now)
    }
}
