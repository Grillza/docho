package suwayomi.tachidesk.docho

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.jetbrains.exposed.v1.core.ReferenceOption
import org.jetbrains.exposed.v1.core.Table
import org.jetbrains.exposed.v1.core.dao.id.IntIdTable
import suwayomi.tachidesk.manga.model.table.ChapterTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import suwayomi.tachidesk.manga.model.table.columns.unlimitedVarchar

/**
 * A Kavita-style library: a named set of folders of one type, scanned into series. Each library
 * is offered as a source, and its series are kept in the server library under a category of the
 * same name.
 */
object DochoLibraryTable : IntIdTable("docho_library") {
    val name = varchar("name", 256)
    val type = varchar("type", 32)

    /** Folders, one per line. */
    val folders = unlimitedVarchar("folders")

    /** Comma-separated [suwayomi.tachidesk.docho.library.FileType] names. */
    val fileTypes = varchar("file_types", 128)

    /** Glob patterns, one per line, matched against paths relative to a library folder. */
    val excludePatterns = unlimitedVarchar("exclude_patterns")

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

/**
 * What the tracker fill remembers about a series. `status` is the status it last gave: while the
 * series still has it, nobody has changed it since, so it's only out of date. `ignored` is what
 * the user decided against, as JSON, so it isn't asked about again.
 */
object DochoSeriesFillTable : Table("docho_series_fill") {
    val manga = reference("manga", MangaTable, ReferenceOption.CASCADE)
    val status = integer("status").nullable()
    val ignored = unlimitedVarchar("ignored")

    override val primaryKey = PrimaryKey(manga)
}

/** The tracker fill's review list: what a scan found, waiting to be decided on. */
object DochoTrackerFillItemTable : Table("docho_tracker_fill_item") {
    val manga = reference("manga", MangaTable, ReferenceOption.CASCADE)
    val problem = varchar("problem", 32)
    val data = unlimitedVarchar("data")

    override val primaryKey = PrimaryKey(manga)
}

/** One file (or image folder) found by a scan, which is one chapter of a series. */
object DochoLibraryFileTable : IntIdTable("docho_library_file") {
    val library = reference("library", DochoLibraryTable, ReferenceOption.CASCADE)
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

    /** ComicInfo.xml / OPF metadata, as JSON, so unchanged files aren't opened again. */
    val metadata = unlimitedVarchar("metadata")
}

/** Kavita's extra series fields that Mihon's model has no place for. */
object DochoSeriesInfoTable : IntIdTable("docho_series_info") {
    val manga = reference("manga", MangaTable, ReferenceOption.CASCADE).uniqueIndex()
    val library = reference("library", DochoLibraryTable, ReferenceOption.CASCADE)
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

    /** Fields edited on the server, as a JSON object; scans keep them (Kavita's locked fields). */
    val overrides = unlimitedVarchar("overrides").default("{}")

    /** When [overrides] last changed, in milliseconds. */
    val editedAt = long("edited_at").default(0)
}

/**
 * Several series read as one, such as the parts of JoJo's Bizarre Adventure. A group is also a
 * series of its own (in the Series Groups source), whose chapters are its members' chapters in
 * order, named with each member's label.
 */
object DochoSeriesGroupTable : IntIdTable("docho_series_group") {
    val name = varchar("name", 512)
    val description = unlimitedVarchar("description")

    /** [suwayomi.tachidesk.docho.groups.GroupSortMode] */
    val sortMode = varchar("sort_mode", 32)

    /** [suwayomi.tachidesk.docho.groups.ChapterLabelStyle] */
    val chapterLabel = varchar("chapter_label", 32)
    val hideMembers = bool("hide_members").default(true)
    val coverManga = integer("cover_manga").nullable()
    val manga = integer("manga").nullable()
    val metadataKey = varchar("metadata_key", 512).nullable()
    val createdAt = long("created_at").default(0)
}

object DochoSeriesGroupMemberTable : IntIdTable("docho_series_group_member") {
    val group = reference("group", DochoSeriesGroupTable, ReferenceOption.CASCADE)
    val manga = reference("manga", MangaTable, ReferenceOption.CASCADE).uniqueIndex()
    val position = integer("position").default(0)
    val label = varchar("label", 512).nullable()
}

/** Keeps a group series' chapter in step with the member chapter it stands for. */
object DochoGroupChapterLinkTable : Table("docho_group_chapter_link") {
    val groupChapter = reference("group_chapter", ChapterTable, ReferenceOption.CASCADE).uniqueIndex()
    val memberChapter = reference("member_chapter", ChapterTable, ReferenceOption.CASCADE)
}

/** Kavita collections: made by hand, from ComicInfo SeriesGroup, or from folders in a book library. */
object DochoCollectionTable : IntIdTable("docho_collection") {
    val name = varchar("name", 512)
    val summary = unlimitedVarchar("summary")

    /** MANUAL, METADATA or FOLDER */
    val origin = varchar("origin", 16)
    val library = integer("library").nullable()
    val promoted = bool("promoted").default(false)
}

object DochoCollectionMangaTable : IntIdTable("docho_collection_manga") {
    val collection = reference("collection", DochoCollectionTable, ReferenceOption.CASCADE)
    val manga = reference("manga", MangaTable, ReferenceOption.CASCADE)
    val position = integer("position").default(0)
}

// Dōchō Sync: the app's library, renames, read state and history, per account.

object DochoSyncUserTable : IntIdTable("docho_sync_user") {
    val username = varchar("username", 100).uniqueIndex()
    val salt = varchar("salt", 64)
    val passwordHash = varchar("password_hash", 128)
    val createdAt = long("created_at")
}

object DochoSyncTokenTable : Table("docho_sync_token") {
    val tokenHash = varchar("token_hash", 64)
    val user = reference("user", DochoSyncUserTable, ReferenceOption.CASCADE)
    val device = varchar("device", 200)
    val createdAt = long("created_at")
    val lastUsedAt = long("last_used_at")
    override val primaryKey = PrimaryKey(tokenHash)
}

object DochoSyncRecordTable : Table("docho_sync_record") {
    val user = reference("user", DochoSyncUserTable, ReferenceOption.CASCADE)
    val kind = varchar("kind", 32)
    val key = varchar("key", 2000)
    val value = unlimitedVarchar("value").nullable()
    val updatedAt = long("updated_at")
    val device = varchar("device", 200)
    val seq = long("seq")
    override val primaryKey = PrimaryKey(user, kind, key)

    init {
        index(false, user, seq)
    }
}

object DochoSyncCounterTable : Table("docho_sync_counter") {
    val user = reference("user", DochoSyncUserTable, ReferenceOption.CASCADE)
    val seq = long("seq")
    override val primaryKey = PrimaryKey(user)
}
