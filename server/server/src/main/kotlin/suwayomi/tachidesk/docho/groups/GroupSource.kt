package suwayomi.tachidesk.docho.groups

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import eu.kanade.tachiyomi.source.UnmeteredSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.inList
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import suwayomi.tachidesk.docho.library.FileBackedSource
import suwayomi.tachidesk.docho.library.LibrarySource
import suwayomi.tachidesk.manga.impl.Chapter
import suwayomi.tachidesk.manga.impl.Page as ServerPage
import suwayomi.tachidesk.manga.impl.chapter.getChapterDownloadReadyById
import suwayomi.tachidesk.manga.model.table.ChapterTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import java.io.InputStream

/** The Series Groups source: each group as one series, its chapters its members' chapters. */
object GroupSource : FileBackedSource, UnmeteredSource {
    override val id: Long = SeriesGroups.SOURCE_ID
    override val name: String = SeriesGroups.SOURCE_NAME
    override val lang: String = "all"
    override val supportsLatest: Boolean = false

    override fun toString() = name

    override suspend fun getPopularManga(page: Int): MangasPage = getSearchManga(page, "", FilterList())

    override suspend fun getLatestUpdates(page: Int): MangasPage = getPopularManga(page)

    override suspend fun getSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): MangasPage {
        val groups = SeriesGroups.list().filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
        val rows =
            transaction {
                MangaTable.selectAll().where { MangaTable.id inList groups.mapNotNull { it.mangaId } }.associateBy { it[MangaTable.id].value }
            }
        return MangasPage(
            groups.mapNotNull { group -> group.mangaId?.let(rows::get) }.map { row ->
                SManga.create().apply {
                    url = row[MangaTable.url]
                    title = row[MangaTable.title]
                    description = row[MangaTable.description]
                    thumbnail_url = row[MangaTable.thumbnail_url]
                    initialized = true
                }
            },
            false,
        )
    }

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        val groupId = manga.url.removePrefix("/group/").substringBefore('/').toIntOrNull() ?: throw IllegalArgumentException("Not a group")
        val group = SeriesGroups.get(groupId) ?: throw IllegalStateException("This group was removed")
        val details =
            if (fetchDetails) {
                val row = transaction { MangaTable.selectAll().where { MangaTable.id eq group.mangaId!! }.first() }
                SManga.create().apply {
                    url = manga.url
                    title = group.name
                    author = row[MangaTable.author]
                    artist = row[MangaTable.artist]
                    description = row[MangaTable.description]
                    genre = row[MangaTable.genre]
                    status = row[MangaTable.status]
                    thumbnail_url = row[MangaTable.thumbnail_url]
                    update_strategy = UpdateStrategy.ALWAYS_UPDATE
                    initialized = true
                }
            } else {
                manga
            }
        return SMangaUpdate(details, if (fetchChapters) chapterList(group) else chapters)
    }

    private data class Numbers(
        val volume: Float?,
        val chapter: Float?,
    )

    private val volumeName = Regex("""(?<![\p{L}])(?:vol(?:ume)?)\.?\s*(\d+(?:\.\d+)?)""", RegexOption.IGNORE_CASE)
    private val chapterName = Regex("""(?<![\p{L}])(?:ch(?:apter)?|ep(?:isode)?)\.?\s*(\d+(?:\.\d+)?)""", RegexOption.IGNORE_CASE)

    private fun numbers(
        name: String,
        chapterNumber: Float,
    ): Numbers {
        val volume = volumeName.find(name)?.groupValues?.get(1)?.toFloatOrNull()
        val chapter = chapterName.find(name)?.groupValues?.get(1)?.toFloatOrNull() ?: chapterNumber.takeIf { volume == null && it >= 0 }
        return Numbers(volume, chapter)
    }

    private suspend fun chapterList(group: SeriesGroup): List<SChapter> {
        val result = mutableListOf<SChapter>()
        var volumeOffset = 0f
        var chapterOffset = 0f
        var index = 0
        for (member in group.members) {
            // Members not opened yet have no chapters on the server; fetch them.
            var rows = memberChapters(member.mangaId)
            if (rows.isEmpty()) {
                runCatching { Chapter.getChapterList(member.mangaId, onlineFetch = true) }
                rows = memberChapters(member.mangaId)
            }
            var maxVolume = 0f
            var maxChapter = 0f
            for (row in rows) {
                index++
                val original = row[ChapterTable.name]
                val n = numbers(original, row[ChapterTable.chapter_number])
                n.volume?.let { maxVolume = maxOf(maxVolume, it) }
                n.chapter?.let { maxChapter = maxOf(maxChapter, it) }
                val continuous =
                    listOfNotNull(
                        n.volume?.let { "Vol. ${LibrarySource.number(it + volumeOffset)}" },
                        n.chapter?.takeIf { n.volume == null || chapterName.containsMatchIn(original) }?.let { "Ch. ${LibrarySource.number(it + chapterOffset)}" },
                    ).joinToString(" ")
                val label = member.displayLabel
                result +=
                    SChapter.create().apply {
                        url = "/group/${group.id}/chapter/${row[ChapterTable.id].value}"
                        name =
                            when (group.chapterLabel) {
                                ChapterLabelStyle.LABEL_PREFIX -> "$label · $original"
                                ChapterLabelStyle.CONTINUOUS -> continuous.ifEmpty { "$label · $original" }
                                ChapterLabelStyle.CONTINUOUS_WITH_LABEL -> if (continuous.isEmpty()) "$label · $original" else "$continuous · $label $original"
                                ChapterLabelStyle.ORIGINAL -> original
                            }
                        chapter_number =
                            when (group.chapterLabel) {
                                ChapterLabelStyle.CONTINUOUS, ChapterLabelStyle.CONTINUOUS_WITH_LABEL ->
                                    n.chapter?.plus(chapterOffset) ?: n.volume?.plus(volumeOffset) ?: index.toFloat()

                                else -> index.toFloat()
                            }
                        date_upload = row[ChapterTable.date_upload]
                        scanlator = label
                    }
            }
            volumeOffset += maxVolume
            chapterOffset += maxChapter
        }
        return result.reversed()
    }

    private fun memberChapters(mangaId: Int) =
        transaction {
            ChapterTable
                .selectAll()
                .where { ChapterTable.manga eq mangaId }
                .orderBy(ChapterTable.sourceOrder to SortOrder.ASC)
                .toList()
        }

    fun memberChapterId(url: String): Int? = url.substringAfter("/chapter/", "").toIntOrNull()

    override suspend fun getPageList(chapter: SChapter): List<Page> {
        val memberChapter = memberChapterId(chapter.url) ?: throw IllegalArgumentException("Not a group chapter")
        val ready = getChapterDownloadReadyById(memberChapter)
        return List(ready.pageCount) { Page(it, imageUrl = "docho-group:$memberChapter#$it") }
    }

    override suspend fun openPage(
        chapterUrl: String,
        index: Int,
    ): Pair<InputStream, String> {
        val memberChapter = memberChapterId(chapterUrl) ?: throw IllegalArgumentException("Not a group chapter")
        val mangaId =
            transaction { ChapterTable.selectAll().where { ChapterTable.id eq memberChapter }.first()[ChapterTable.manga].value }
        return ServerPage.getPageImage(mangaId = mangaId, chapterId = memberChapter, index = index)
    }
}
