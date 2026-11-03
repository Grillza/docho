package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.UnmeteredSource
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import eu.kanade.tachiyomi.util.lang.compareToCaseInsensitiveNaturalOrder
import org.jetbrains.exposed.v1.core.JoinType
import org.jetbrains.exposed.v1.core.LikePattern
import org.jetbrains.exposed.v1.core.ResultRow
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.like
import org.jetbrains.exposed.v1.core.lowerCase
import org.jetbrains.exposed.v1.core.or
import org.jetbrains.exposed.v1.jdbc.andWhere
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import suwayomi.tachidesk.docho.DochoLibraryFileTable
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import java.io.File
import java.io.InputStream

/** A source whose pages the server serves itself (from files, or from other series) rather than fetching. */
interface FileBackedSource : CatalogueSource {
    suspend fun openPage(
        chapterUrl: String,
        index: Int,
    ): Pair<InputStream, String>
}

/**
 * One library, offered as a source: browse and search its series, and read their files.
 * Series and chapters come from the last scan ([LibraryScanner]), so this never walks folders.
 */
class LibrarySource(
    val libraryId: Int,
    override val name: String,
) : FileBackedSource,
    UnmeteredSource {
    override val id: Long = Libraries.sourceId(libraryId)
    override val lang: String = Libraries.SOURCE_LANG
    override val supportsLatest: Boolean = true

    override fun toString() = name

    private class SortFilter :
        Filter.Sort(
            "Sort by",
            arrayOf("Name", "Recently added", "Recently updated"),
            Selection(0, true),
        )

    override fun getFilterList() = FilterList(SortFilter())

    override suspend fun getPopularManga(page: Int) = browse(page, "", 0, true)

    override suspend fun getLatestUpdates(page: Int) = browse(page, "", 2, false)

    override suspend fun getSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): MangasPage {
        val sort = filters.filterIsInstance<SortFilter>().firstOrNull()?.state
        return browse(page, query, sort?.index ?: 0, sort?.ascending ?: true)
    }

    private fun browse(
        page: Int,
        query: String,
        sort: Int,
        ascending: Boolean,
    ): MangasPage =
        transaction {
            val order = if (ascending) SortOrder.ASC else SortOrder.DESC
            val q =
                MangaTable
                    .join(DochoSeriesInfoTable, JoinType.INNER, MangaTable.id, DochoSeriesInfoTable.manga)
                    .selectAll()
                    .where { MangaTable.sourceReference eq this@LibrarySource.id }
            if (query.isNotBlank()) {
                val pattern = LikePattern("%${query.trim().lowercase()}%")
                q.andWhere {
                    (MangaTable.title.lowerCase() like pattern) or
                        (DochoSeriesInfoTable.localizedName.lowerCase() like pattern) or
                        (MangaTable.author.lowerCase() like pattern)
                }
            }
            when (sort) {
                1 -> q.orderBy(DochoSeriesInfoTable.addedAt to order)
                2 -> q.orderBy(DochoSeriesInfoTable.updatedAt to order)
                else -> q.orderBy(DochoSeriesInfoTable.sortName.lowerCase() to order)
            }
            val rows = q.limit(PAGE_SIZE + 1).offset(((page - 1) * PAGE_SIZE).toLong()).toList()
            MangasPage(rows.take(PAGE_SIZE).map { it.toSManga() }, rows.size > PAGE_SIZE)
        }

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        val row =
            transaction {
                MangaTable.selectAll().where { (MangaTable.sourceReference eq this@LibrarySource.id) and (MangaTable.url eq manga.url) }.firstOrNull()
            } ?: throw IllegalStateException("${manga.title} is no longer in $name; scan the library")
        val details = if (fetchDetails) row.toSManga() else manga
        val list = if (fetchChapters) chapterList(row[MangaTable.id].value) else chapters
        return SMangaUpdate(details, list)
    }

    private fun chapterList(mangaId: Int): List<SChapter> {
        val files =
            transaction {
                DochoLibraryFileTable.selectAll().where { DochoLibraryFileTable.manga eq mangaId }.toList()
            }
        val type = Libraries.get(libraryId)?.type ?: LibraryType.MANGA
        return files
            .sortedWith(readingOrder)
            .mapIndexed { index, file ->
                SChapter.create().apply {
                    url = file[DochoLibraryFileTable.chapterUrl]
                    name = chapterName(file, type)
                    date_upload = file[DochoLibraryFileTable.modifiedAt]
                    chapter_number =
                        file[DochoLibraryFileTable.chapter]
                            ?: file[DochoLibraryFileTable.volume]
                            ?: (index + 1).toFloat()
                    scanlator = file[DochoLibraryFileTable.releaseGroup]
                }
            }.reversed() // newest first, as sources list them
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val (file, format) = fileFor(chapter.url)
        val count = BookFiles.pageCount(file, format)
        return List(count) { Page(it, imageUrl = "docho-library:${chapter.url}#$it") }
    }

    override suspend fun openPage(
        chapterUrl: String,
        index: Int,
    ): Pair<InputStream, String> {
        val (file, format) = fileFor(chapterUrl)
        return BookFiles.openPage(file, format, index)
    }

    private fun fileFor(chapterUrl: String): Pair<File, BookFormat> {
        val row =
            transaction {
                DochoLibraryFileTable
                    .selectAll()
                    .where { (DochoLibraryFileTable.library eq libraryId) and (DochoLibraryFileTable.chapterUrl eq chapterUrl) }
                    .firstOrNull()
            } ?: throw IllegalStateException("This chapter's file is gone; scan the library")
        val file = File(row[DochoLibraryFileTable.path])
        if (!file.exists()) throw IllegalStateException("${file.name} is missing; is the library folder mounted?")
        return file to BookFormat.valueOf(row[DochoLibraryFileTable.format])
    }

    private fun ResultRow.toSManga(): SManga {
        val row = this
        return SManga.create().apply {
            url = row[MangaTable.url]
            title = row[MangaTable.title]
            artist = row[MangaTable.artist]
            author = row[MangaTable.author]
            description = row[MangaTable.description]
            genre = row[MangaTable.genre]
            status = row[MangaTable.status]
            thumbnail_url = row[MangaTable.thumbnail_url]
            update_strategy = UpdateStrategy.ALWAYS_UPDATE
            initialized = true
        }
    }

    companion object {
        private const val PAGE_SIZE = 60

        /** Volumes in order with their chapters, then loose chapters, then specials. */
        val readingOrder: Comparator<ResultRow> =
            compareBy<ResultRow> { it[DochoLibraryFileTable.isSpecial] }
                .thenBy { it[DochoLibraryFileTable.volume] ?: Float.MAX_VALUE }
                .thenBy { it[DochoLibraryFileTable.chapter] ?: -1f }
                .thenComparator { a, b ->
                    File(a[DochoLibraryFileTable.path]).name.compareToCaseInsensitiveNaturalOrder(File(b[DochoLibraryFileTable.path]).name)
                }

        fun number(value: Float): String = if (value % 1f == 0f) value.toInt().toString() else value.toString()

        /** "Vol. 3 Ch. 12", "Vol. 3", "Ch. 12", "Special: Omake", or the book's title. */
        fun chapterName(
            file: ResultRow,
            type: LibraryType,
        ): String {
            val volume = file[DochoLibraryFileTable.volume]
            val chapter = file[DochoLibraryFileTable.chapter]
            val title = file[DochoLibraryFileTable.title]
            val fileName = FileNameParser.clean(File(file[DochoLibraryFileTable.path]).nameWithoutExtension)
            val numbered =
                listOfNotNull(
                    volume?.let { "Vol. ${number(it)}" },
                    chapter?.let { "Ch. ${number(it)}" },
                ).joinToString(" ")
            return when {
                file[DochoLibraryFileTable.isSpecial] -> "Special: ${title ?: fileName}"
                // The server drops a chapter name that repeats the series title, as a book's would.
                type.filePerSeries && volume == null && chapter == null ->
                    "Book · " + BookFormat.valueOf(file[DochoLibraryFileTable.format]).name.replace("SEVEN_ZIP", "7Z")
                numbered.isNotEmpty() && title != null && title != file[DochoLibraryFileTable.seriesName] -> "$numbered - $title"
                numbered.isNotEmpty() -> numbered
                else -> title ?: fileName
            }
        }
    }
}
