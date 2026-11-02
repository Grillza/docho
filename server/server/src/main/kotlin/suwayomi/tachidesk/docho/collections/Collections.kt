package suwayomi.tachidesk.docho.collections

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.inList
import org.jetbrains.exposed.v1.jdbc.deleteWhere
import org.jetbrains.exposed.v1.jdbc.insert
import org.jetbrains.exposed.v1.jdbc.insertAndGetId
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import suwayomi.tachidesk.docho.DochoCollectionMangaTable
import suwayomi.tachidesk.docho.DochoCollectionTable
import suwayomi.tachidesk.docho.library.FileNameParser
import suwayomi.tachidesk.docho.library.LibrarySettings

enum class CollectionOrigin {
    /** Made by hand. */
    MANUAL,

    /** From ComicInfo SeriesGroup, kept up to date by scans. */
    METADATA,

    /** From the folders of a book library, kept up to date by scans. */
    FOLDER,
}

data class SeriesCollection(
    val id: Int,
    val name: String,
    val summary: String,
    val origin: CollectionOrigin,
    val libraryId: Int?,
    val promoted: Boolean,
    val mangaIds: List<Int>,
)

/** Kavita's collections: series that belong together without being read as one. */
object Collections {
    fun list(): List<SeriesCollection> =
        transaction {
            val members =
                DochoCollectionMangaTable
                    .selectAll()
                    .orderBy(DochoCollectionMangaTable.position to SortOrder.ASC)
                    .groupBy({ it[DochoCollectionMangaTable.collection].value }, { it[DochoCollectionMangaTable.manga].value })
            DochoCollectionTable.selectAll().orderBy(DochoCollectionTable.name to SortOrder.ASC).map { row ->
                val id = row[DochoCollectionTable.id].value
                SeriesCollection(
                    id = id,
                    name = row[DochoCollectionTable.name],
                    summary = row[DochoCollectionTable.summary],
                    origin = runCatching { CollectionOrigin.valueOf(row[DochoCollectionTable.origin]) }.getOrDefault(CollectionOrigin.MANUAL),
                    libraryId = row[DochoCollectionTable.library],
                    promoted = row[DochoCollectionTable.promoted],
                    mangaIds = members[id].orEmpty().distinct(),
                )
            }
        }

    fun get(id: Int) = list().firstOrNull { it.id == id }

    fun ofManga(mangaId: Int) = list().filter { mangaId in it.mangaIds }

    fun create(
        name: String,
        summary: String = "",
        mangaIds: List<Int> = emptyList(),
        origin: CollectionOrigin = CollectionOrigin.MANUAL,
        libraryId: Int? = null,
    ): SeriesCollection {
        require(name.isNotBlank()) { "Name the collection" }
        val id =
            transaction {
                DochoCollectionTable
                    .insertAndGetId {
                        it[DochoCollectionTable.name] = name.trim().take(512)
                        it[DochoCollectionTable.summary] = summary
                        it[DochoCollectionTable.origin] = origin.name
                        it[library] = libraryId
                    }.value
            }
        setSeries(id, mangaIds)
        return get(id)!!
    }

    fun update(
        id: Int,
        name: String? = null,
        summary: String? = null,
        promoted: Boolean? = null,
    ): SeriesCollection {
        transaction {
            DochoCollectionTable.update({ DochoCollectionTable.id eq id }) {
                name?.let { v ->
                    require(v.isNotBlank()) { "Name the collection" }
                    it[DochoCollectionTable.name] = v.trim().take(512)
                    // Renamed by hand: scans no longer manage it.
                    it[origin] = CollectionOrigin.MANUAL.name
                }
                summary?.let { v -> it[DochoCollectionTable.summary] = v }
                promoted?.let { v -> it[DochoCollectionTable.promoted] = v }
            }
        }
        return get(id) ?: throw IllegalArgumentException("No collection $id")
    }

    fun setSeries(
        id: Int,
        mangaIds: List<Int>,
    ) {
        transaction {
            DochoCollectionMangaTable.deleteWhere { DochoCollectionMangaTable.collection eq id }
            mangaIds.distinct().forEachIndexed { index, mangaId ->
                DochoCollectionMangaTable.insert {
                    it[collection] = id
                    it[manga] = mangaId
                    it[position] = index
                }
            }
        }
    }

    fun addSeries(
        id: Int,
        mangaIds: List<Int>,
    ) {
        val current = get(id)?.mangaIds ?: throw IllegalArgumentException("No collection $id")
        setSeries(id, current + mangaIds.filter { it !in current })
    }

    fun removeSeries(
        id: Int,
        mangaIds: List<Int>,
    ) {
        transaction {
            DochoCollectionMangaTable.deleteWhere { (DochoCollectionMangaTable.collection eq id) and (DochoCollectionMangaTable.manga inList mangaIds) }
        }
    }

    fun delete(id: Int) {
        transaction { DochoCollectionTable.deleteWhere { DochoCollectionTable.id eq id } }
    }

    /**
     * After a scan: the library's series join the collections their metadata or folders name,
     * and leave the scan-made ones they no longer belong to. Collections made by hand are left
     * alone.
     */
    fun syncLibraryCollections(
        library: LibrarySettings,
        seriesCollections: List<Pair<Int, List<Pair<String, String>>>>,
    ) {
        val wanted = mutableMapOf<Pair<CollectionOrigin, String>, MutableSet<Int>>()
        val names = mutableMapOf<Pair<CollectionOrigin, String>, String>()
        for ((mangaId, collections) in seriesCollections) {
            for ((origin, name) in collections) {
                val key = CollectionOrigin.valueOf(origin) to FileNameParser.normalize(name)
                wanted.getOrPut(key) { mutableSetOf() } += mangaId
                names.putIfAbsent(key, name)
            }
        }
        val librarySeries = seriesCollections.map { it.first }.toSet()
        val existing = list().filter { it.origin != CollectionOrigin.MANUAL }
        // Collections a scan made: drop this library's series that no longer belong.
        for (collection in existing) {
            val key = collection.origin to FileNameParser.normalize(collection.name)
            val keep = wanted[key].orEmpty()
            val stale = collection.mangaIds.filter { it in librarySeries && it !in keep }
            if (stale.isNotEmpty()) removeSeries(collection.id, stale)
        }
        for ((key, mangaIds) in wanted) {
            val match = existing.firstOrNull { it.origin == key.first && FileNameParser.normalize(it.name) == key.second }
            if (match == null) {
                create(names.getValue(key), mangaIds = mangaIds.toList(), origin = key.first, libraryId = library.id)
            } else {
                addSeries(match.id, mangaIds.toList())
            }
        }
        // Scan-made collections left empty go.
        list().filter { it.origin != CollectionOrigin.MANUAL && it.mangaIds.isEmpty() }.forEach { delete(it.id) }
    }
}
