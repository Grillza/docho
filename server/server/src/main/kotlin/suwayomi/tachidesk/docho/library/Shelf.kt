package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import io.javalin.apibuilder.ApiBuilder.get
import io.javalin.apibuilder.ApiBuilder.path
import io.javalin.http.HttpStatus
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.greater
import org.jetbrains.exposed.v1.jdbc.select
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import suwayomi.tachidesk.docho.DochoLibraryFileTable
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.groups.SeriesGroups
import suwayomi.tachidesk.manga.model.table.ChapterTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import suwayomi.tachidesk.server.ApplicationDirs
import uy.kohesive.injekt.injectLazy
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * What the library shelf shows besides each series' own cover, as BookOrbit does: the covers of
 * the next books in the series, stacked behind the first, with how many books there are; and the
 * series being read, to resume.
 */
object Shelf {
    private val applicationDirs: ApplicationDirs by injectLazy()

    /** Covers stacked behind a series' own: at most this many. */
    private const val BEHIND = 2
    private const val STACK_COVER_WIDTH = 360

    /** A series as a stack: [behind] are image URLs, nearest first, and [books] its count. */
    data class Stack(
        val mangaId: Int,
        val books: Int,
        val behind: List<String>,
    )

    private fun thumbnail(mangaId: Int) = "/api/v1/manga/$mangaId/thumbnail"

    fun stack(mangaId: Int): Stack =
        transaction {
            val chapterCount = ChapterTable.selectAll().where { ChapterTable.manga eq mangaId }.count().toInt()
            val group = SeriesGroups.byMangaId(mangaId)
            when {
                // A group: the covers of its other parts.
                group != null -> {
                    val front = SeriesGroups.coverMemberOf(mangaId)
                    Stack(mangaId, chapterCount, group.members.map { it.mangaId }.filter { it != front }.take(BEHIND).map(::thumbnail))
                }
                // A library series: the covers of its next books.
                DochoSeriesInfoTable.selectAll().where { DochoSeriesInfoTable.manga eq mangaId }.any() -> {
                    val files =
                        DochoLibraryFileTable
                            .selectAll()
                            .where { DochoLibraryFileTable.manga eq mangaId }
                            .sortedWith(LibrarySource.readingOrder)
                    Stack(mangaId, files.size, files.drop(1).take(BEHIND).map { "/api/docho/cover/file/${it[DochoLibraryFileTable.id].value}" })
                }
                else -> Stack(mangaId, chapterCount, emptyList())
            }
        }

    // ---- Covers of single files ----

    private val coverLocks = ConcurrentHashMap<Int, Any>()

    private fun fileCoversDir() = File(Libraries.coversDir(applicationDirs), "files")

    /** A book's cover, made from its first page the first time it's asked for and kept. */
    fun fileCover(fileId: Int): File? {
        val row =
            transaction { DochoLibraryFileTable.selectAll().where { DochoLibraryFileTable.id eq fileId }.firstOrNull() } ?: return null
        val cached = File(fileCoversDir(), "$fileId.jpg")
        val modified = row[DochoLibraryFileTable.modifiedAt]
        synchronized(coverLocks.getOrPut(fileId) { Any() }) {
            if (cached.exists() && cached.lastModified() >= modified) return cached
            val file = File(row[DochoLibraryFileTable.path])
            if (!file.exists()) return cached.takeIf { it.exists() }
            val bytes = BookFiles.cover(file, BookFormat.valueOf(row[DochoLibraryFileTable.format])) ?: return null
            cached.parentFile.mkdirs()
            cached.writeBytes(BookFiles.shrinkImage(bytes, STACK_COVER_WIDTH))
            return cached
        }
    }

    fun defineEndpoints() {
        path("docho/cover") {
            get("file/{fileId}") { ctx ->
                val id = ctx.pathParam("fileId").toIntOrNull()
                val cover = id?.let { fileCover(it) }
                if (cover == null) {
                    ctx.status(HttpStatus.NOT_FOUND)
                    return@get
                }
                ctx.header("Cache-Control", "max-age=86400")
                ctx.contentType("image/jpeg")
                ctx.result(cover.inputStream())
            }
        }
    }

    // ---- Currently reading ----

    /** A series being read: where to resume and how far along it is. */
    data class Reading(
        val mangaId: Int,
        val title: String,
        val thumbnailUrl: String,
        val readChapters: Int,
        val totalChapters: Int,
        val chapterId: Int,
        val chapterName: String,
        val chapterSourceOrder: Int,
        val page: Int,
        val pageCount: Int,
        val lastReadAt: Long,
    )

    /**
     * The series read most recently that aren't finished, newest first. A part of a series group
     * shows as its group.
     */
    fun reading(limit: Int): List<Reading> =
        transaction {
            val recent =
                ChapterTable
                    .select(ChapterTable.manga, ChapterTable.lastReadAt)
                    .where { ChapterTable.lastReadAt greater 0L }
                    .orderBy(ChapterTable.lastReadAt to SortOrder.DESC)
                    .limit(2000)
                    .map { it[ChapterTable.manga].value to it[ChapterTable.lastReadAt] }
            val seen = LinkedHashMap<Int, Long>()
            for ((mangaId, at) in recent) {
                val shown = SeriesGroups.groupOfMember(mangaId)?.mangaId ?: mangaId
                seen.putIfAbsent(shown, at)
            }
            seen.entries
                .asSequence()
                .mapNotNull { (mangaId, at) -> readingOf(mangaId, at) }
                .take(limit.coerceIn(1, 20))
                .toList()
        }

    private fun readingOf(
        mangaId: Int,
        lastReadAt: Long,
    ): Reading? {
        val manga = MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull() ?: return null
        val chapters =
            ChapterTable
                .selectAll()
                .where { ChapterTable.manga eq mangaId }
                .orderBy(ChapterTable.sourceOrder to SortOrder.ASC)
                .toList()
        if (chapters.isEmpty()) return null
        val read = chapters.count { it[ChapterTable.isRead] }
        if (read == chapters.size) return null
        val last = chapters.filter { it[ChapterTable.lastReadAt] > 0 }.maxByOrNull { it[ChapterTable.lastReadAt] }
        val resume =
            when {
                last != null && !last[ChapterTable.isRead] -> last
                last != null ->
                    chapters.firstOrNull { it[ChapterTable.sourceOrder] > last[ChapterTable.sourceOrder] && !it[ChapterTable.isRead] }
                        ?: chapters.first { !it[ChapterTable.isRead] }
                else -> chapters.first { !it[ChapterTable.isRead] }
            }
        val inProgress = resume[ChapterTable.lastPageRead] > 0 && !resume[ChapterTable.isRead]
        return Reading(
            mangaId = mangaId,
            title = manga[MangaTable.title],
            thumbnailUrl = thumbnail(mangaId),
            readChapters = read,
            totalChapters = chapters.size,
            chapterId = resume[ChapterTable.id].value,
            chapterName = resume[ChapterTable.name],
            chapterSourceOrder = resume[ChapterTable.sourceOrder],
            page = if (inProgress) resume[ChapterTable.lastPageRead] else 0,
            pageCount = resume[ChapterTable.pageCount].coerceAtLeast(0),
            lastReadAt = lastReadAt,
        )
    }
}
