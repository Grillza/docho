package suwayomi.tachidesk.server.database.migration

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import de.neonew.exposed.migrations.helpers.AddTableMigration
import org.jetbrains.exposed.v1.core.ReferenceOption
import org.jetbrains.exposed.v1.core.Table
import org.jetbrains.exposed.v1.core.dao.id.IntIdTable
import suwayomi.tachidesk.manga.model.table.ChapterTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import org.jetbrains.exposed.v1.core.Column
import suwayomi.tachidesk.graphql.types.DatabaseType
import suwayomi.tachidesk.server.serverConfig

/**
 * Dōchō Server: libraries, series groups, collections and Dōchō Sync. The tables are copied here
 * as they were when added, so later changes to docho/DochoTables.kt need migrations of their own.
 */
@Suppress("ClassName", "unused")
class M0066_DochoServer : AddTableMigration() {
    private companion object {
        /** Unlimited text: H2 can't create VARCHAR(Int.MAX_VALUE), which unlimitedVarchar asks for. */
        fun Table.longText(name: String): Column<String> =
            when (serverConfig.databaseType.value) {
                DatabaseType.H2 -> varchar(name, 1_000_000_000)
                DatabaseType.POSTGRESQL -> text(name)
            }
    }

    private class Library : IntIdTable("docho_library") {
        val name = varchar("name", 256)
        val type = varchar("type", 32)
        val folders = longText("folders")
        val fileTypes = varchar("file_types", 128)
        val excludePatterns = longText("exclude_patterns")
        val includeInDashboard = bool("include_in_dashboard").default(true)
        val includeInSearch = bool("include_in_search").default(true)
        val useMetadata = bool("use_metadata").default(true)
        val manageCollections = bool("manage_collections").default(true)
        val manageGroups = bool("manage_groups").default(true)
        val folderCollections = bool("folder_collections").default(false)
        val folderWatching = bool("folder_watching").default(true)
        val scanIntervalMinutes = integer("scan_interval_minutes").default(360)
        val sortOrder = integer("sort_order").default(0)
        val categoryId = integer("category_id").nullable()
        val lastScannedAt = long("last_scanned_at").default(0)
        val lastScanResult = varchar("last_scan_result", 1024).nullable()
    }

    private class LibraryFile(
        library: Library,
    ) : IntIdTable("docho_library_file") {
        val library = reference("library", library, ReferenceOption.CASCADE)
        val manga = reference("manga", MangaTable, ReferenceOption.CASCADE).nullable()
        val path = varchar("path", 4096)
        val chapterUrl = varchar("chapter_url", 2048)
        val format = varchar("format", 16)
        val seriesName = varchar("series_name", 512)
        val seriesKey = varchar("series_key", 512)
        val title = varchar("title", 512).nullable()
        val volume = float("volume").nullable()
        val chapter = float("chapter").nullable()
        val isSpecial = bool("is_special").default(false)
        val releaseGroup = varchar("release_group", 256).nullable()
        val pageCount = integer("page_count").default(-1)
        val size = long("size").default(0)
        val modifiedAt = long("modified_at").default(0)
        val metadata = longText("metadata")
    }

    private class SeriesInfo(
        library: Library,
    ) : IntIdTable("docho_series_info") {
        val manga = reference("manga", MangaTable, ReferenceOption.CASCADE).uniqueIndex()
        val library = reference("library", library, ReferenceOption.CASCADE)
        val folder = varchar("folder", 4096).nullable()
        val sortName = varchar("sort_name", 512)
        val localizedName = varchar("localized_name", 512).nullable()
        val format = varchar("format", 16)
        val ageRating = varchar("age_rating", 64).nullable()
        val releaseYear = integer("release_year").nullable()
        val language = varchar("language", 32).nullable()
        val publisher = varchar("publisher", 256).nullable()
        val pageCount = integer("page_count").default(0)
        val addedAt = long("added_at").default(0)
        val updatedAt = long("updated_at").default(0)
    }

    private class SeriesGroup : IntIdTable("docho_series_group") {
        val name = varchar("name", 512)
        val description = longText("description")
        val sortMode = varchar("sort_mode", 32)
        val chapterLabel = varchar("chapter_label", 32)
        val hideMembers = bool("hide_members").default(true)
        val coverManga = integer("cover_manga").nullable()
        val manga = integer("manga").nullable()
        val metadataKey = varchar("metadata_key", 512).nullable()
        val createdAt = long("created_at").default(0)
    }

    private class SeriesGroupMember(
        group: SeriesGroup,
    ) : IntIdTable("docho_series_group_member") {
        val group = reference("group", group, ReferenceOption.CASCADE)
        val manga = reference("manga", MangaTable, ReferenceOption.CASCADE).uniqueIndex()
        val position = integer("position").default(0)
        val label = varchar("label", 512).nullable()
    }

    private class GroupChapterLink : Table("docho_group_chapter_link") {
        val groupChapter = reference("group_chapter", ChapterTable, ReferenceOption.CASCADE).uniqueIndex()
        val memberChapter = reference("member_chapter", ChapterTable, ReferenceOption.CASCADE)
    }

    private class Collection : IntIdTable("docho_collection") {
        val name = varchar("name", 512)
        val summary = longText("summary")
        val origin = varchar("origin", 16)
        val library = integer("library").nullable()
        val promoted = bool("promoted").default(false)
    }

    private class CollectionManga(
        collection: Collection,
    ) : IntIdTable("docho_collection_manga") {
        val collection = reference("collection", collection, ReferenceOption.CASCADE)
        val manga = reference("manga", MangaTable, ReferenceOption.CASCADE)
        val position = integer("position").default(0)
    }

    private class SyncUser : IntIdTable("docho_sync_user") {
        val username = varchar("username", 100).uniqueIndex()
        val salt = varchar("salt", 64)
        val passwordHash = varchar("password_hash", 128)
        val createdAt = long("created_at")
    }

    private class SyncToken(
        users: SyncUser,
    ) : Table("docho_sync_token") {
        val tokenHash = varchar("token_hash", 64)
        val user = reference("user", users, ReferenceOption.CASCADE)
        val device = varchar("device", 200)
        val createdAt = long("created_at")
        val lastUsedAt = long("last_used_at")
        override val primaryKey = PrimaryKey(tokenHash)
    }

    private class SyncRecord(
        users: SyncUser,
    ) : Table("docho_sync_record") {
        val user = reference("user", users, ReferenceOption.CASCADE)
        val kind = varchar("kind", 32)
        val key = varchar("key", 2000)
        val value = longText("value").nullable()
        val updatedAt = long("updated_at")
        val device = varchar("device", 200)
        val seq = long("seq")
        override val primaryKey = PrimaryKey(user, kind, key)

        init {
            index(false, user, seq)
        }
    }

    private class SyncCounter(
        users: SyncUser,
    ) : Table("docho_sync_counter") {
        val user = reference("user", users, ReferenceOption.CASCADE)
        val seq = long("seq")
        override val primaryKey = PrimaryKey(user)
    }

    override val tables: Array<Table>
        get() {
            val library = Library()
            val group = SeriesGroup()
            val collection = Collection()
            val users = SyncUser()
            return arrayOf(
                library,
                LibraryFile(library),
                SeriesInfo(library),
                group,
                SeriesGroupMember(group),
                GroupChapterLink(),
                collection,
                CollectionManga(collection),
                users,
                SyncToken(users),
                SyncRecord(users),
                SyncCounter(users),
            )
        }
}
