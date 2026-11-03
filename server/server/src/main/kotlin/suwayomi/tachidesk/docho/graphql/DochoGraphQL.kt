package suwayomi.tachidesk.docho.graphql

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.jetbrains.exposed.v1.core.JoinType
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.inList
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.collections.CollectionOrigin
import suwayomi.tachidesk.docho.collections.Collections
import suwayomi.tachidesk.docho.collections.SeriesCollection
import suwayomi.tachidesk.docho.groups.ChapterLabelStyle
import suwayomi.tachidesk.docho.groups.GroupInput
import suwayomi.tachidesk.docho.groups.GroupMember
import suwayomi.tachidesk.docho.groups.GroupSortMode
import suwayomi.tachidesk.docho.groups.GroupSuggestion
import suwayomi.tachidesk.docho.groups.SeriesGroup
import suwayomi.tachidesk.docho.groups.SeriesGroups
import suwayomi.tachidesk.docho.library.FileType
import suwayomi.tachidesk.docho.library.Libraries
import suwayomi.tachidesk.docho.library.LibraryInput
import suwayomi.tachidesk.docho.library.LibrarySettings
import suwayomi.tachidesk.docho.library.LibraryType
import suwayomi.tachidesk.docho.library.SeriesMetadata
import suwayomi.tachidesk.docho.library.Shelf
import suwayomi.tachidesk.docho.sync.SyncBridge
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import suwayomi.tachidesk.graphql.directives.RequireAuth
import suwayomi.tachidesk.graphql.types.MangaType
import suwayomi.tachidesk.manga.model.table.MangaTable
import java.io.File

private fun mangas(ids: List<Int>): List<MangaType> {
    if (ids.isEmpty()) return emptyList()
    val byId = transaction { MangaTable.selectAll().where { MangaTable.id inList ids }.associate { it[MangaTable.id].value to MangaType(it) } }
    return ids.mapNotNull(byId::get)
}

// ---- Types ----

class DochoLibrary(
    private val settings: LibrarySettings,
) {
    val id = settings.id
    val name = settings.name
    val type: LibraryType = settings.type
    val folders: List<String> = settings.folders
    val fileTypes: List<FileType> = settings.fileTypes.sortedBy { it.ordinal }
    val excludePatterns: List<String> = settings.excludePatterns
    val includeInDashboard = settings.includeInDashboard
    val includeInSearch = settings.includeInSearch
    val useMetadata = settings.useMetadata
    val manageCollections = settings.manageCollections
    val manageGroups = settings.manageGroups
    val folderCollections = settings.folderCollections
    val folderWatching = settings.folderWatching
    val scanIntervalMinutes = settings.scanIntervalMinutes
    val sortOrder = settings.sortOrder
    val categoryId = settings.categoryId
    val sourceId: Long = settings.sourceId
    val lastScannedAt = settings.lastScannedAt
    val lastScanResult = settings.lastScanResult
    val scanning: Boolean = Libraries.status.value[settings.id]?.running == true

    fun seriesCount(): Int = transaction { MangaTable.selectAll().where { MangaTable.sourceReference eq settings.sourceId }.count().toInt() }

    fun series(): List<MangaType> =
        transaction {
            MangaTable
                .join(DochoSeriesInfoTable, JoinType.INNER, MangaTable.id, DochoSeriesInfoTable.manga)
                .selectAll()
                .where { MangaTable.sourceReference eq settings.sourceId }
                .sortedBy { it[DochoSeriesInfoTable.sortName].lowercase() }
                .map { MangaType(it) }
        }
}

class DochoGroupMember(
    private val member: GroupMember,
) {
    val mangaId = member.mangaId
    val position = member.position
    val label = member.label
    val displayLabel = member.displayLabel
    val title = member.title

    fun manga(): MangaType? = mangas(listOf(member.mangaId)).firstOrNull()
}

class DochoSeriesGroup(
    private val group: SeriesGroup,
) {
    val id = group.id
    val name = group.name
    val description = group.description
    val sortMode: GroupSortMode = group.sortMode
    val chapterLabel: ChapterLabelStyle = group.chapterLabel
    val hideMembers = group.hideMembers
    val coverMangaId = group.coverMangaId
    val mangaId = group.mangaId

    fun members(): List<DochoGroupMember> = group.members.map(::DochoGroupMember)

    /** The series that stands for the whole group. */
    fun manga(): MangaType? = group.mangaId?.let { mangas(listOf(it)).firstOrNull() }
}

class DochoCollection(
    private val collection: SeriesCollection,
) {
    val id = collection.id
    val name = collection.name
    val summary = collection.summary
    val origin: CollectionOrigin = collection.origin
    val libraryId = collection.libraryId
    val promoted = collection.promoted
    val seriesCount = collection.mangaIds.size

    fun series(): List<MangaType> = mangas(collection.mangaIds)
}

class DochoGroupSuggestion(
    private val suggestion: GroupSuggestion,
) {
    val name = suggestion.name
    val mangaIds = suggestion.mangaIds
    val labels = suggestion.labels

    fun series(): List<MangaType> = mangas(suggestion.mangaIds)
}

/** Kavita's series fields, and what the series belongs to. */
class DochoSeriesInfo(
    val mangaId: Int,
) {
    private val row by lazy { transaction { DochoSeriesInfoTable.selectAll().where { DochoSeriesInfoTable.manga eq mangaId }.firstOrNull() } }

    fun libraryId(): Int? = row?.get(DochoSeriesInfoTable.library)?.value

    fun folder(): String? = row?.get(DochoSeriesInfoTable.folder)

    fun sortName(): String? = row?.get(DochoSeriesInfoTable.sortName)

    fun localizedName(): String? = row?.get(DochoSeriesInfoTable.localizedName)

    fun format(): String? = row?.get(DochoSeriesInfoTable.format)

    fun ageRating(): String? = row?.get(DochoSeriesInfoTable.ageRating)

    fun releaseYear(): Int? = row?.get(DochoSeriesInfoTable.releaseYear)

    fun language(): String? = row?.get(DochoSeriesInfoTable.language)

    fun publisher(): String? = row?.get(DochoSeriesInfoTable.publisher)

    fun pageCount(): Int? = row?.get(DochoSeriesInfoTable.pageCount)

    fun addedAt(): Long? = row?.get(DochoSeriesInfoTable.addedAt)

    private val manga by lazy { transaction { MangaTable.selectAll().where { MangaTable.id eq mangaId }.firstOrNull() } }

    private fun names(value: String?): List<String> = value.orEmpty().split(",").map { it.trim() }.filter { it.isNotEmpty() }

    fun title(): String? = manga?.get(MangaTable.title)

    fun summary(): String? = manga?.get(MangaTable.description)

    fun writers(): List<String> = names(manga?.get(MangaTable.author))

    fun artists(): List<String> = names(manga?.get(MangaTable.artist))

    fun genres(): List<String> = names(manga?.get(MangaTable.genre))

    /** Suwayomi's status number: 0 unknown, 1 ongoing, 2 completed, 3 licensed, 4 publishing finished, 5 cancelled, 6 on hiatus. */
    fun status(): Int? = manga?.get(MangaTable.status)

    /** Fields edited on the server, which scans leave alone. */
    fun editedFields(): List<SeriesMetadata.Field> =
        if (row != null) {
            SeriesMetadata.Overrides.parse(row?.get(DochoSeriesInfoTable.overrides)).values.keys.toList()
        } else {
            SyncBridge.editedDetails(mangaId).mapNotNull(SeriesMetadata.syncedFields::get)
        }

    /** Every series can be edited; series from extensions only in the fields the apps share. */
    fun editable(): Boolean = manga != null

    /** The fields that can be edited: all of them on library series. */
    fun editableFields(): List<SeriesMetadata.Field> =
        if (row != null) SeriesMetadata.Field.entries.toList() else SeriesMetadata.syncedFields.values.toList()

    fun collections(): List<DochoCollection> = Collections.ofManga(mangaId).map(::DochoCollection)

    /** The group the series is in, or the group it stands for. */
    fun group(): DochoSeriesGroup? = (SeriesGroups.groupOfMember(mangaId) ?: SeriesGroups.byMangaId(mangaId))?.let(::DochoSeriesGroup)
}

data class DochoStack(
    val mangaId: Int,
    val books: Int,
    /** Image URLs of the covers behind the series' own, nearest first. */
    val behind: List<String>,
)

data class DochoFolder(
    val name: String,
    val path: String,
)

data class DochoServerInfo(
    val name: String,
    val syncVersion: String,
    val librarySourceIdBase: Long,
    val groupSourceId: Long,
    /** Where the folder picker opens: DOCHO_LIBRARY_ROOT (the Docker image's /books), else "/". */
    val libraryRoot: String,
)

// ---- Queries ----

private fun libraryRoot(): String =
    System.getenv("DOCHO_LIBRARY_ROOT")?.ifBlank { null }?.takeIf { File(it).isDirectory } ?: "/"

class DochoQuery {
    @RequireAuth
    fun dochoServerInfo(): DochoServerInfo =
        DochoServerInfo(
            name = "Dōchō Server",
            syncVersion = suwayomi.tachidesk.docho.sync.DochoSync.VERSION,
            librarySourceIdBase = Libraries.SOURCE_ID_BASE,
            groupSourceId = SeriesGroups.SOURCE_ID,
            libraryRoot = libraryRoot(),
        )

    @RequireAuth
    fun dochoLibraries(): List<DochoLibrary> = Libraries.list().map(::DochoLibrary)

    @RequireAuth
    fun dochoLibrary(id: Int): DochoLibrary? = Libraries.get(id)?.let(::DochoLibrary)

    @RequireAuth
    fun dochoSeriesGroups(): List<DochoSeriesGroup> = SeriesGroups.list().map(::DochoSeriesGroup)

    @RequireAuth
    fun dochoSeriesGroup(id: Int): DochoSeriesGroup? = SeriesGroups.get(id)?.let(::DochoSeriesGroup)

    @RequireAuth
    fun dochoGroupSuggestions(): List<DochoGroupSuggestion> = SeriesGroups.suggest().map(::DochoGroupSuggestion)

    /** Labels the server would give these series in a group of this name. */
    @RequireAuth
    fun dochoSuggestLabels(
        name: String,
        mangaIds: List<Int>,
    ): List<String> = SeriesGroups.suggestLabels(name, mangas(mangaIds).map { it.title })

    @RequireAuth
    fun dochoCollections(): List<DochoCollection> = Collections.list().map(::DochoCollection)

    @RequireAuth
    fun dochoCollection(id: Int): DochoCollection? = Collections.get(id)?.let(::DochoCollection)

    @RequireAuth
    fun dochoSeriesInfo(mangaId: Int): DochoSeriesInfo = DochoSeriesInfo(mangaId)

    /** Chapters of a series renamed or given a Volume/Chapter type, in the WebUI or the apps. */
    @RequireAuth
    fun dochoChapterEdits(mangaId: Int): List<SyncBridge.ChapterEdit> = SyncBridge.chapterEdits(mangaId)

    /** Series as stacks of their books' covers, as BookOrbit shows them. */
    @RequireAuth
    fun dochoStack(mangaId: Int): DochoStack = Shelf.stack(mangaId).let { DochoStack(it.mangaId, it.books, it.behind) }

    /** The series read most recently and not finished, to resume from the top of the library. */
    @RequireAuth
    fun dochoContinueReading(limit: Int? = 3): List<Shelf.Reading> = Shelf.reading(limit ?: 3)

    /** Folders on the server, for picking a library's folders. */
    @RequireAuth
    fun dochoFolders(path: String? = null): List<DochoFolder> {
        val dir = File(path?.ifBlank { null } ?: libraryRoot())
        require(dir.isDirectory) {
            val root = libraryRoot()
            if (root != "/" && !dir.path.startsWith(root)) {
                "${dir.path} isn't a folder on the server. Your library is mounted at $root"
            } else {
                "${dir.path} isn't a folder on the server"
            }
        }
        return dir
            .listFiles()
            .orEmpty()
            .filter { it.isDirectory && !it.name.startsWith('.') }
            .sortedBy { it.name.lowercase() }
            .map { DochoFolder(it.name, it.absolutePath) }
    }
}

// ---- Mutations ----

/** Series details to change: only the fields given are set; [reset] ones go back to the files'. */
data class DochoSeriesEditInput(
    val mangaId: Int,
    val title: String? = null,
    val localizedName: String? = null,
    val sortName: String? = null,
    val summary: String? = null,
    val writers: List<String>? = null,
    val artists: List<String>? = null,
    val genres: List<String>? = null,
    val status: Int? = null,
    val publisher: String? = null,
    val releaseYear: Int? = null,
    val ageRating: String? = null,
    val language: String? = null,
    val reset: List<SeriesMetadata.Field>? = null,
)

class DochoMutation {
    @RequireAuth
    fun editDochoSeries(input: DochoSeriesEditInput): DochoSeriesInfo {
        val set = mutableMapOf<SeriesMetadata.Field, JsonElement>()
        fun text(
            field: SeriesMetadata.Field,
            value: String?,
        ) = value?.let { set[field] = JsonPrimitive(it) }
        fun list(
            field: SeriesMetadata.Field,
            value: List<String>?,
        ) = value?.let { set[field] = JsonArray(it.map(::JsonPrimitive)) }
        text(SeriesMetadata.Field.TITLE, input.title)
        text(SeriesMetadata.Field.LOCALIZED_NAME, input.localizedName)
        text(SeriesMetadata.Field.SORT_NAME, input.sortName)
        text(SeriesMetadata.Field.SUMMARY, input.summary)
        list(SeriesMetadata.Field.WRITERS, input.writers)
        list(SeriesMetadata.Field.ARTISTS, input.artists)
        list(SeriesMetadata.Field.GENRES, input.genres)
        input.status?.let { set[SeriesMetadata.Field.STATUS] = JsonPrimitive(it) }
        text(SeriesMetadata.Field.PUBLISHER, input.publisher)
        input.releaseYear?.let { set[SeriesMetadata.Field.RELEASE_YEAR] = JsonPrimitive(it) }
        text(SeriesMetadata.Field.AGE_RATING, input.ageRating)
        text(SeriesMetadata.Field.LANGUAGE, input.language)
        val reset = input.reset.orEmpty().toSet()
        SeriesMetadata.edit(input.mangaId, SeriesMetadata.Edit(set - reset, reset))
        return DochoSeriesInfo(input.mangaId)
    }

    /**
     * Renames a chapter or sets its Volume/Chapter type, as the apps do, and sends that to them.
     * A null name drops the rename; a null kind lets the chapter's name decide.
     */
    @RequireAuth
    fun renameDochoChapter(
        chapterId: Int,
        name: String? = null,
        number: Double? = null,
        kind: String? = null,
    ): Boolean {
        require(kind == null || kind == "volume" || kind == "chapter") { "kind is volume or chapter" }
        SyncBridge.renameChapter(chapterId, name?.trim()?.ifEmpty { null }, number?.toFloat(), kind)
        return true
    }

    @RequireAuth
    fun createDochoLibrary(input: LibraryInput): DochoLibrary = DochoLibrary(Libraries.create(input))

    @RequireAuth
    fun updateDochoLibrary(
        id: Int,
        input: LibraryInput,
    ): DochoLibrary = DochoLibrary(Libraries.update(id, input))

    @RequireAuth
    fun deleteDochoLibrary(id: Int): Boolean {
        Libraries.delete(id)
        return true
    }

    @RequireAuth
    fun scanDochoLibrary(id: Int): Boolean = Libraries.scan(id) != null

    @RequireAuth
    fun scanAllDochoLibraries(): Boolean {
        Libraries.scanAll()
        return true
    }

    @RequireAuth
    fun createDochoSeriesGroup(
        name: String,
        mangaIds: List<Int>,
        labels: List<String?>? = null,
        input: GroupInput? = null,
    ): DochoSeriesGroup = DochoSeriesGroup(SeriesGroups.create(name, mangaIds, input ?: GroupInput(), labels.orEmpty()))

    @RequireAuth
    fun updateDochoSeriesGroup(
        id: Int,
        input: GroupInput,
    ): DochoSeriesGroup = DochoSeriesGroup(SeriesGroups.update(id, input))

    @RequireAuth
    fun setDochoSeriesGroupMembers(
        id: Int,
        mangaIds: List<Int>,
    ): DochoSeriesGroup = DochoSeriesGroup(SeriesGroups.setMembers(id, mangaIds))

    @RequireAuth
    fun setDochoSeriesGroupLabel(
        id: Int,
        mangaId: Int,
        label: String? = null,
    ): DochoSeriesGroup {
        SeriesGroups.setLabel(id, mangaId, label)
        return DochoSeriesGroup(SeriesGroups.get(id)!!)
    }

    @RequireAuth
    fun autoLabelDochoSeriesGroup(id: Int): DochoSeriesGroup = DochoSeriesGroup(SeriesGroups.autoLabel(id))

    @RequireAuth
    fun deleteDochoSeriesGroup(id: Int): Boolean {
        SeriesGroups.delete(id)
        return true
    }

    @RequireAuth
    fun createDochoCollection(
        name: String,
        summary: String? = null,
        mangaIds: List<Int>? = null,
    ): DochoCollection = DochoCollection(Collections.create(name, summary.orEmpty(), mangaIds.orEmpty()))

    @RequireAuth
    fun updateDochoCollection(
        id: Int,
        name: String? = null,
        summary: String? = null,
        promoted: Boolean? = null,
    ): DochoCollection = DochoCollection(Collections.update(id, name, summary, promoted))

    @RequireAuth
    fun setDochoCollectionSeries(
        id: Int,
        mangaIds: List<Int>,
    ): DochoCollection {
        Collections.setSeries(id, mangaIds)
        return DochoCollection(Collections.get(id)!!)
    }

    @RequireAuth
    fun addToDochoCollection(
        id: Int,
        mangaIds: List<Int>,
    ): DochoCollection {
        Collections.addSeries(id, mangaIds)
        return DochoCollection(Collections.get(id)!!)
    }

    @RequireAuth
    fun removeFromDochoCollection(
        id: Int,
        mangaIds: List<Int>,
    ): DochoCollection {
        Collections.removeSeries(id, mangaIds)
        return DochoCollection(Collections.get(id)!!)
    }

    @RequireAuth
    fun deleteDochoCollection(id: Int): Boolean {
        Collections.delete(id)
        return true
    }
}
