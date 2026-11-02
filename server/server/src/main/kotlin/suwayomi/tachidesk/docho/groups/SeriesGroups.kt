package suwayomi.tachidesk.docho.groups

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.util.lang.compareToCaseInsensitiveNaturalOrder
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.jetbrains.exposed.v1.core.JoinType
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.inList
import org.jetbrains.exposed.v1.core.isNotNull
import org.jetbrains.exposed.v1.jdbc.deleteWhere
import org.jetbrains.exposed.v1.jdbc.insert
import org.jetbrains.exposed.v1.jdbc.insertAndGetId
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import suwayomi.tachidesk.docho.DochoGroupChapterLinkTable
import suwayomi.tachidesk.docho.DochoSeriesGroupMemberTable
import suwayomi.tachidesk.docho.DochoSeriesGroupTable
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.library.FileNameParser
import suwayomi.tachidesk.docho.library.Libraries
import suwayomi.tachidesk.manga.impl.CategoryManga
import suwayomi.tachidesk.manga.impl.Manga
import suwayomi.tachidesk.manga.impl.util.source.GetSource
import suwayomi.tachidesk.manga.model.table.CategoryMangaTable
import suwayomi.tachidesk.manga.model.table.ChapterTable
import suwayomi.tachidesk.manga.model.table.ExtensionTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import suwayomi.tachidesk.manga.model.table.SourceTable
import kotlin.time.Duration.Companion.seconds

/** How a group orders its members. */
enum class GroupSortMode {
    /** The order they were put in. */
    MANUAL,

    /** By the part or season number in their labels or titles, such as JoJo's parts. */
    PART_NUMBER,

    /** By the year they started. */
    RELEASE_YEAR,

    /** Alphabetically, numbers in order. */
    TITLE,
}

/** How a group names its chapters, which are its members' chapters. */
enum class ChapterLabelStyle {
    /** "Stardust Crusaders · Vol. 3" */
    LABEL_PREFIX,

    /** "Vol. 15", numbered on from the previous member: one long run, as in an omnibus. */
    CONTINUOUS,

    /** "Vol. 15 · Stardust Crusaders Vol. 3" */
    CONTINUOUS_WITH_LABEL,

    /** The member's chapter names as they are. */
    ORIGINAL,
}

data class GroupMember(
    val mangaId: Int,
    val position: Int,
    val label: String?,
    val title: String,
) {
    val displayLabel get() = label?.ifBlank { null } ?: title
}

data class SeriesGroup(
    val id: Int,
    val name: String,
    val description: String,
    val sortMode: GroupSortMode,
    val chapterLabel: ChapterLabelStyle,
    val hideMembers: Boolean,
    val coverMangaId: Int?,
    val mangaId: Int?,
    val metadataKey: String?,
    val members: List<GroupMember>,
)

/** A group the server thinks might be wanted, from series titles that start the same. */
data class GroupSuggestion(
    val name: String,
    val mangaIds: List<Int>,
    val labels: List<String>,
)

data class GroupInput(
    val name: String? = null,
    val description: String? = null,
    val sortMode: GroupSortMode? = null,
    val chapterLabel: ChapterLabelStyle? = null,
    val hideMembers: Boolean? = null,
    val coverMangaId: Int? = null,
)

/**
 * Series groups: several series read as one, such as the parts of JoJo's Bizarre Adventure.
 * Each group is a series of its own in the Series Groups source, so the web reader and the apps
 * show and read it like any other; its chapters are its members' chapters, named by
 * [ChapterLabelStyle], and reading one marks the member's chapter too, and back.
 */
object SeriesGroups {
    private val logger = KotlinLogging.logger { }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    const val SOURCE_ID = Libraries.SOURCE_ID_BASE
    const val SOURCE_NAME = "Series Groups"

    fun groupUrl(groupId: Int) = "/group/$groupId"

    // ---- Reading ----

    fun list(): List<SeriesGroup> =
        transaction {
            val members =
                DochoSeriesGroupMemberTable
                    .join(MangaTable, JoinType.INNER, DochoSeriesGroupMemberTable.manga, MangaTable.id)
                    .selectAll()
                    .groupBy { it[DochoSeriesGroupMemberTable.group].value }
            DochoSeriesGroupTable.selectAll().orderBy(DochoSeriesGroupTable.name to SortOrder.ASC).map { row ->
                val id = row[DochoSeriesGroupTable.id].value
                SeriesGroup(
                    id = id,
                    name = row[DochoSeriesGroupTable.name],
                    description = row[DochoSeriesGroupTable.description],
                    sortMode = runCatching { GroupSortMode.valueOf(row[DochoSeriesGroupTable.sortMode]) }.getOrDefault(GroupSortMode.MANUAL),
                    chapterLabel =
                        runCatching { ChapterLabelStyle.valueOf(row[DochoSeriesGroupTable.chapterLabel]) }
                            .getOrDefault(ChapterLabelStyle.LABEL_PREFIX),
                    hideMembers = row[DochoSeriesGroupTable.hideMembers],
                    coverMangaId = row[DochoSeriesGroupTable.coverManga],
                    mangaId = row[DochoSeriesGroupTable.manga],
                    metadataKey = row[DochoSeriesGroupTable.metadataKey],
                    members =
                        members[id]
                            .orEmpty()
                            .map {
                                GroupMember(
                                    mangaId = it[DochoSeriesGroupMemberTable.manga].value,
                                    position = it[DochoSeriesGroupMemberTable.position],
                                    label = it[DochoSeriesGroupMemberTable.label],
                                    title = it[MangaTable.title],
                                )
                            }.sortedBy { it.position },
                )
            }
        }

    fun get(id: Int): SeriesGroup? = list().firstOrNull { it.id == id }

    fun byMangaId(mangaId: Int): SeriesGroup? = list().firstOrNull { it.mangaId == mangaId }

    fun groupOfMember(mangaId: Int): SeriesGroup? = list().firstOrNull { group -> group.members.any { it.mangaId == mangaId } }

    fun isHiddenMember(mangaId: Int): Boolean = groupOfMember(mangaId)?.hideMembers == true

    // ---- Changes ----

    fun create(
        name: String,
        mangaIds: List<Int>,
        input: GroupInput = GroupInput(),
        labels: List<String?> = emptyList(),
        metadataKey: String? = null,
    ): SeriesGroup {
        require(name.isNotBlank()) { "Name the group" }
        require(mangaIds.isNotEmpty()) { "Pick the series to group" }
        val taken = mangaIds.mapNotNull { id -> groupOfMember(id)?.let { id to it.name } }
        require(taken.isEmpty()) { "Already grouped: ${taken.joinToString { "${titleOf(it.first)} (in ${it.second})" }}" }
        mangaIds.forEach { require(byMangaId(it) == null) { "A group can't be put in another group" } }

        // The group takes the place of its first member in the library's categories.
        val categories = CategoryManga.getMangaCategories(mangaIds.first()).map { it.id }.filter { it != 0 }

        val groupId =
            transaction {
                DochoSeriesGroupTable
                    .insertAndGetId {
                        it[DochoSeriesGroupTable.name] = name.trim()
                        it[description] = input.description.orEmpty()
                        it[sortMode] = (input.sortMode ?: GroupSortMode.MANUAL).name
                        it[chapterLabel] = (input.chapterLabel ?: ChapterLabelStyle.LABEL_PREFIX).name
                        it[hideMembers] = input.hideMembers ?: true
                        it[coverManga] = input.coverMangaId
                        it[DochoSeriesGroupTable.metadataKey] = metadataKey
                        it[createdAt] = System.currentTimeMillis()
                    }.value
            }
        transaction {
            mangaIds.forEachIndexed { index, mangaId ->
                DochoSeriesGroupMemberTable.insert {
                    it[group] = groupId
                    it[manga] = mangaId
                    it[position] = index
                    it[label] = labels.getOrNull(index)?.ifBlank { null }
                }
            }
        }
        val mangaId = ensureGroupManga(groupId)
        categories.ifEmpty { listOf(0) }.forEach { categoryId ->
            if (categoryId != 0) CategoryManga.addMangaToCategory(mangaId, categoryId)
        }
        applySort(groupId)
        applyHiding(groupId)
        refreshChapters(groupId)
        return get(groupId)!!
    }

    fun update(
        id: Int,
        input: GroupInput,
    ): SeriesGroup {
        get(id) ?: throw IllegalArgumentException("No group $id")
        transaction {
            DochoSeriesGroupTable.update({ DochoSeriesGroupTable.id eq id }) {
                input.name?.let { v ->
                    require(v.isNotBlank()) { "Name the group" }
                    it[name] = v.trim()
                }
                input.description?.let { v -> it[description] = v }
                input.sortMode?.let { v -> it[sortMode] = v.name }
                input.chapterLabel?.let { v -> it[chapterLabel] = v.name }
                input.hideMembers?.let { v -> it[hideMembers] = v }
                input.coverMangaId?.let { v -> it[coverManga] = v.takeIf { c -> c > 0 } }
            }
        }
        ensureGroupManga(id)
        applySort(id)
        applyHiding(id)
        refreshChapters(id)
        return get(id)!!
    }

    /** Sets the members, in order; for a manual order, this is the reading order. */
    fun setMembers(
        id: Int,
        mangaIds: List<Int>,
    ): SeriesGroup {
        val group = get(id) ?: throw IllegalArgumentException("No group $id")
        require(mangaIds.isNotEmpty()) { "A group needs at least one series" }
        val elsewhere = mangaIds.mapNotNull { mangaId -> groupOfMember(mangaId)?.takeIf { it.id != id }?.let { titleOf(mangaId) } }
        require(elsewhere.isEmpty()) { "Already in another group: ${elsewhere.joinToString()}" }
        val labels = group.members.associate { it.mangaId to it.label }
        val removed = group.members.map { it.mangaId } - mangaIds.toSet()
        transaction {
            DochoSeriesGroupMemberTable.deleteWhere { DochoSeriesGroupMemberTable.group eq id }
            mangaIds.distinct().forEachIndexed { index, mangaId ->
                DochoSeriesGroupMemberTable.insert {
                    it[DochoSeriesGroupMemberTable.group] = id
                    it[manga] = mangaId
                    it[position] = index
                    it[label] = labels[mangaId]
                }
            }
        }
        restore(removed, group)
        applySort(id)
        applyHiding(id)
        refreshChapters(id)
        return get(id)!!
    }

    fun setLabel(
        id: Int,
        mangaId: Int,
        label: String?,
    ) {
        transaction {
            DochoSeriesGroupMemberTable.update({ (DochoSeriesGroupMemberTable.group eq id) and (DochoSeriesGroupMemberTable.manga eq mangaId) }) {
                it[DochoSeriesGroupMemberTable.label] = label?.trim()?.ifBlank { null }?.take(512)
            }
        }
        applySort(id)
        refreshChapters(id)
    }

    /** Names each member from its title: "JoJo's Bizarre Adventure Part 3 - Stardust Crusaders" → "Part 3: Stardust Crusaders". */
    fun autoLabel(id: Int): SeriesGroup {
        val group = get(id) ?: throw IllegalArgumentException("No group $id")
        val labels = suggestLabels(group.name, group.members.map { it.title })
        transaction {
            group.members.zip(labels).forEach { (member, label) ->
                DochoSeriesGroupMemberTable.update({ (DochoSeriesGroupMemberTable.group eq id) and (DochoSeriesGroupMemberTable.manga eq member.mangaId) }) {
                    it[DochoSeriesGroupMemberTable.label] = label.take(512)
                }
            }
        }
        applySort(id)
        refreshChapters(id)
        return get(id)!!
    }

    /** Ungroups: the members come back to the library. */
    fun delete(id: Int) {
        val group = get(id) ?: return
        restore(group.members.map { it.mangaId }, group)
        transaction {
            group.mangaId?.let { mangaId -> MangaTable.deleteWhere { MangaTable.id eq mangaId } }
            DochoSeriesGroupTable.deleteWhere { DochoSeriesGroupTable.id eq id }
        }
    }

    private fun titleOf(mangaId: Int) = transaction { MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull()?.get(MangaTable.title) } ?: "#$mangaId"

    // ---- Keeping the group series up to date ----

    /** The series that stands for the group, made if it isn't there yet. */
    private fun ensureGroupManga(groupId: Int): Int {
        val group = get(groupId)!!
        val coverId = group.coverMangaId ?: group.members.firstOrNull()?.mangaId
        val cover = coverId?.let { id -> transaction { MangaTable.selectAll().where { MangaTable.id eq id }.firstOrNull() } }
        val description =
            group.description.ifBlank {
                "${group.members.size} series read as one: " + group.members.joinToString(" → ") { it.displayLabel }
            }
        return transaction {
            val existing = group.mangaId?.let { id -> MangaTable.selectAll().where { MangaTable.id eq id }.firstOrNull() }
            val id =
                if (existing == null) {
                    MangaTable
                        .insertAndGetId {
                            it[url] = groupUrl(groupId)
                            it[title] = group.name
                            it[sourceReference] = SOURCE_ID
                            it[initialized] = true
                            it[inLibrary] = true
                            it[inLibraryAt] = System.currentTimeMillis() / 1000
                        }.value
                        .also { mangaId -> DochoSeriesGroupTable.update({ DochoSeriesGroupTable.id eq groupId }) { it[manga] = mangaId } }
                } else {
                    existing[MangaTable.id].value
                }
            MangaTable.update({ MangaTable.id eq id }) {
                it[title] = group.name
                it[MangaTable.description] = description
                it[author] = cover?.get(MangaTable.author)
                it[artist] = cover?.get(MangaTable.artist)
                it[genre] = cover?.get(MangaTable.genre)
                it[status] = cover?.get(MangaTable.status) ?: SManga.UNKNOWN
                it[thumbnail_url] = "docho-group-cover:${coverId ?: 0}"
            }
            id
        }.also { Manga.clearThumbnail(it) }
    }

    /** The member whose cover a group series shows. */
    fun coverMemberOf(groupMangaId: Int): Int? {
        val group = byMangaId(groupMangaId) ?: return null
        return group.coverMangaId ?: group.members.firstOrNull()?.mangaId
    }

    private fun applySort(groupId: Int) {
        val group = get(groupId) ?: return
        if (group.sortMode == GroupSortMode.MANUAL) return
        val years =
            if (group.sortMode == GroupSortMode.RELEASE_YEAR) {
                transaction {
                    DochoSeriesInfoTable
                        .selectAll()
                        .where { DochoSeriesInfoTable.manga inList group.members.map { it.mangaId } }
                        .associate { it[DochoSeriesInfoTable.manga].value to it[DochoSeriesInfoTable.releaseYear] }
                } +
                    transaction {
                        // Members from online sources: the oldest chapter's date.
                        group.members.associate { member ->
                            member.mangaId to
                                ChapterTable
                                    .selectAll()
                                    .where { ChapterTable.manga eq member.mangaId }
                                    .minOfOrNull { it[ChapterTable.date_upload] }
                                    ?.takeIf { it > 0 }
                                    ?.let { java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneOffset.UTC).year }
                        }
                    }.filterValues { it != null }
            } else {
                emptyMap()
            }
        val sorted =
            when (group.sortMode) {
                GroupSortMode.PART_NUMBER ->
                    group.members.sortedWith(
                        compareBy<GroupMember> { partNumber(it.displayLabel) ?: partNumber(it.title) ?: Float.MAX_VALUE }
                            .thenComparator { a, b -> a.title.compareToCaseInsensitiveNaturalOrder(b.title) },
                    )

                GroupSortMode.RELEASE_YEAR -> group.members.sortedWith(compareBy<GroupMember> { years[it.mangaId] ?: Int.MAX_VALUE }.thenBy { it.position })
                GroupSortMode.TITLE -> group.members.sortedWith { a, b -> a.displayLabel.compareToCaseInsensitiveNaturalOrder(b.displayLabel) }
                GroupSortMode.MANUAL -> group.members
            }
        transaction {
            sorted.forEachIndexed { index, member ->
                DochoSeriesGroupMemberTable.update({ (DochoSeriesGroupMemberTable.group eq groupId) and (DochoSeriesGroupMemberTable.manga eq member.mangaId) }) {
                    it[position] = index
                }
            }
        }
    }

    private fun applyHiding(groupId: Int) {
        val group = get(groupId) ?: return
        val ids = group.members.map { it.mangaId }
        if (group.hideMembers) {
            transaction {
                MangaTable.update({ MangaTable.id inList ids }) { it[inLibrary] = false }
                CategoryMangaTable.deleteWhere { CategoryMangaTable.manga inList ids }
            }
        } else {
            restore(ids, group)
        }
    }

    /** Puts series back in the library, in the group's categories. */
    private fun restore(
        mangaIds: List<Int>,
        group: SeriesGroup,
    ) {
        if (mangaIds.isEmpty()) return
        val categories = group.mangaId?.let { id -> CategoryManga.getMangaCategories(id).map { it.id }.filter { it != 0 } }.orEmpty()
        transaction {
            MangaTable.update({ MangaTable.id inList mangaIds }) {
                it[inLibrary] = true
                it[inLibraryAt] = System.currentTimeMillis() / 1000
            }
        }
        if (categories.isNotEmpty()) CategoryManga.addMangasToCategories(mangaIds, categories)
    }

    /** Fetches the group series' chapters again, from its members. */
    fun refreshChapters(groupId: Int) {
        val mangaId = get(groupId)?.mangaId ?: return
        scope.launch {
            runCatching {
                Manga.updateMangaAndChapters(mangaId, updateManga = true, updateChapters = true)
                linkChapters(groupId)
            }.onFailure { logger.warn(it) { "Couldn't update the chapters of group $groupId" } }
        }
    }

    /** Groups whose members are in [mangaIds]: their chapter lists need refreshing. */
    fun refreshGroupsOf(mangaIds: Collection<Int>) {
        val ids = mangaIds.toSet()
        list().filter { group -> group.members.any { it.mangaId in ids } }.forEach { refreshChapters(it.id) }
    }

    private fun linkChapters(groupId: Int) {
        val group = get(groupId) ?: return
        val mangaId = group.mangaId ?: return
        transaction {
            val chapters = ChapterTable.selectAll().where { ChapterTable.manga eq mangaId }.toList()
            DochoGroupChapterLinkTable.deleteWhere { DochoGroupChapterLinkTable.groupChapter inList chapters.map { it[ChapterTable.id].value } }
            chapters.forEach { row ->
                val memberChapter = GroupSource.memberChapterId(row[ChapterTable.url]) ?: return@forEach
                val exists = ChapterTable.selectAll().where { ChapterTable.id eq memberChapter }.any()
                if (exists) {
                    DochoGroupChapterLinkTable.insert {
                        it[groupChapter] = row[ChapterTable.id].value
                        it[DochoGroupChapterLinkTable.memberChapter] = memberChapter
                    }
                }
            }
        }
        reconcile()
    }

    /**
     * Keeps a group's chapters and its members' chapters read alike: whichever changed last
     * wins. Runs every few seconds; only differing rows are written.
     */
    fun reconcile() {
        transaction {
            val links = DochoGroupChapterLinkTable.selectAll().toList()
            if (links.isEmpty()) return@transaction
            val ids = links.flatMap { listOf(it[DochoGroupChapterLinkTable.groupChapter].value, it[DochoGroupChapterLinkTable.memberChapter].value) }
            val rows = ids.chunked(1000).flatMap { chunk -> ChapterTable.selectAll().where { ChapterTable.id inList chunk }.toList() }.associateBy { it[ChapterTable.id].value }
            for (link in links) {
                val a = rows[link[DochoGroupChapterLinkTable.groupChapter].value] ?: continue
                val b = rows[link[DochoGroupChapterLinkTable.memberChapter].value] ?: continue
                val same =
                    a[ChapterTable.isRead] == b[ChapterTable.isRead] &&
                        a[ChapterTable.isBookmarked] == b[ChapterTable.isBookmarked] &&
                        a[ChapterTable.lastPageRead] == b[ChapterTable.lastPageRead]
                if (same) continue
                val aNewer =
                    compareValuesBy(a, b, { it[ChapterTable.lastModifiedAt] }, { it[ChapterTable.lastReadAt] }) > 0
                val (from, to) = if (aNewer) a to b else b to a
                ChapterTable.update({ ChapterTable.id eq to[ChapterTable.id].value }) {
                    it[isRead] = from[ChapterTable.isRead]
                    it[isBookmarked] = from[ChapterTable.isBookmarked]
                    it[lastPageRead] = from[ChapterTable.lastPageRead]
                    it[lastReadAt] = maxOf(from[ChapterTable.lastReadAt], to[ChapterTable.lastReadAt])
                }
            }
        }
    }

    // ---- Labels and suggestions ----

    private val partPattern =
        Regex(
            """(?<![\p{L}])(part|season|arc|book|phase|chapter|series|stage)\s*\.?\s*(\d+(?:\.\d+)?|[ivxlc]+)(?![\p{L}\d])""",
            RegexOption.IGNORE_CASE,
        )

    private fun romanToInt(value: String): Int? {
        val map = mapOf('i' to 1, 'v' to 5, 'x' to 10, 'l' to 50, 'c' to 100)
        var total = 0
        var previous = 0
        for (ch in value.lowercase().reversed()) {
            val n = map[ch] ?: return null
            if (n < previous) total -= n else total += n
            previous = n
        }
        return total.takeIf { it > 0 }
    }

    fun partNumber(text: String): Float? {
        val match = partPattern.find(text) ?: return null
        val value = match.groupValues[2]
        return value.toFloatOrNull() ?: romanToInt(value)?.toFloat()
    }

    /** Labels for members, from their titles less the group's name. */
    fun suggestLabels(
        groupName: String,
        titles: List<String>,
    ): List<String> {
        val prefix = commonPrefix(titles + groupName)
        return titles.map { title ->
            var rest = title
            listOf(groupName, prefix).filter { it.length >= 3 }.forEach { p ->
                if (rest.startsWith(p, ignoreCase = true)) rest = rest.substring(p.length)
            }
            rest = rest.trim().trimStart(':', '-', '–', '—', '~', '|', ',', '.').trim()
            if (rest.isEmpty()) return@map title
            val part = partPattern.find(rest)
            if (part != null && part.range.first == 0) {
                val word = part.groupValues[1].replaceFirstChar { it.uppercase() }
                val number = part.groupValues[2].let { if (it.toFloatOrNull() != null) it else it.uppercase() }
                val after = rest.substring(part.range.last + 1).trim().trimStart(':', '-', '–', '—', '~', '|', ',', '.').trim()
                if (after.isEmpty()) "$word $number" else "$word $number: $after"
            } else {
                rest
            }
        }
    }

    private fun commonPrefix(titles: List<String>): String {
        if (titles.size < 2) return ""
        var prefix = titles.first()
        for (t in titles.drop(1)) {
            var i = 0
            while (i < prefix.length && i < t.length && prefix[i].lowercaseChar() == t[i].lowercaseChar()) i++
            prefix = prefix.substring(0, i)
        }
        // Whole words only.
        val cut = prefix.lastIndexOfAny(charArrayOf(' ', ':', '-', '–'))
        return if (cut <= 0) "" else prefix.substring(0, cut).trim()
    }

    /** Library series whose titles share a start and differ by part, season or subtitle. */
    fun suggest(): List<GroupSuggestion> {
        val grouped = list().flatMap { g -> g.members.map { it.mangaId } + listOfNotNull(g.mangaId) }.toSet()
        val series =
            transaction {
                MangaTable
                    .selectAll()
                    .where { (MangaTable.inLibrary eq true) and MangaTable.title.isNotNull() }
                    .map { it[MangaTable.id].value to it[MangaTable.title] }
            }.filter { it.first !in grouped }

        fun base(title: String): String {
            val cleaned = FileNameParser.clean(title)
            val part = partPattern.find(cleaned)
            val cut =
                listOfNotNull(
                    part?.range?.first,
                    cleaned.indexOfAny(charArrayOf(':', '–', '—')).takeIf { it > 0 },
                    Regex("""\s-\s""").find(cleaned)?.range?.first,
                ).minOrNull() ?: cleaned.length
            return cleaned.substring(0, cut).trim()
        }
        return series
            .groupBy { FileNameParser.normalize(base(it.second)) }
            .filter { (key, members) -> members.size >= 2 && key.length >= 4 }
            .map { (_, members) ->
                val name = base(members.first().second)
                val sorted = members.sortedWith(compareBy<Pair<Int, String>> { partNumber(it.second) ?: Float.MAX_VALUE }.thenBy { it.second })
                GroupSuggestion(name, sorted.map { it.first }, suggestLabels(name, sorted.map { it.second }))
            }.sortedBy { it.name.lowercase() }
    }

    /** Groups from ComicInfo SeriesGroup, for libraries that manage them. */
    fun syncMetadataGroups(seriesAndGroup: List<Pair<Int, String>>) {
        val byName = seriesAndGroup.groupBy({ it.second.trim() }, { it.first }).mapValues { it.value.distinct() }
        for ((name, mangaIds) in byName) {
            if (name.isEmpty() || mangaIds.size < 2) continue
            val key = FileNameParser.normalize(name)
            val existing = list().firstOrNull { it.metadataKey == key }
            runCatching {
                if (existing == null) {
                    val free = mangaIds.filter { groupOfMember(it) == null }
                    if (free.size >= 2) create(name, free, GroupInput(sortMode = GroupSortMode.PART_NUMBER), metadataKey = key)
                } else {
                    val add = mangaIds.filter { id -> existing.members.none { it.mangaId == id } && groupOfMember(id) == null }
                    if (add.isNotEmpty()) setMembers(existing.id, existing.members.map { it.mangaId } + add)
                }
            }.onFailure { logger.warn(it) { "Couldn't group $name from metadata" } }
        }
    }

    // ---- Setup ----

    fun start() {
        transaction {
            if (SourceTable.selectAll().where { SourceTable.id eq SOURCE_ID }.none()) {
                val extension =
                    ExtensionTable.selectAll().where { ExtensionTable.pkgName eq "docho.libraries" }.firstOrNull()?.get(ExtensionTable.id)?.value
                        ?: ExtensionTable
                            .insertAndGetId {
                                it[apkName] = "dochoLibraries"
                                it[name] = Libraries.EXTENSION_NAME
                                it[pkgName] = "docho.libraries"
                                it[versionName] = "1.0"
                                it[versionCode] = 0
                                it[lang] = "all"
                                it[extensionLib] = "1.5"
                                it[contentWarning] = 0
                                it[isInstalled] = true
                            }.value
                SourceTable.insert {
                    it[id] = SOURCE_ID
                    it[name] = SOURCE_NAME
                    it[lang] = "all"
                    it[SourceTable.extension] = extension
                }
            }
        }
        GetSource.registerSource(SOURCE_ID to GroupSource)
        scope.launch {
            while (true) {
                runCatching { reconcile() }.onFailure { logger.warn(it) { "Group read-state sync failed" } }
                delay(5.seconds)
            }
        }
    }
}
