package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.jetbrains.exposed.v1.core.ResultRow
import suwayomi.tachidesk.docho.DochoLibraryTable

/** Kavita's library types, which decide how files become series. */
enum class LibraryType(
    val defaultFileTypes: Set<FileType>,
) {
    /** A folder per series; files are volumes and chapters. */
    MANGA(setOf(FileType.ARCHIVE, FileType.IMAGES, FileType.EPUB, FileType.PDF)),
    COMIC(setOf(FileType.ARCHIVE, FileType.IMAGES, FileType.EPUB, FileType.PDF)),

    /** Each book is its own series, unless its metadata names a series. */
    BOOK(setOf(FileType.EPUB, FileType.PDF)),

    /** Like manga, for novels: a folder per series. */
    LIGHT_NOVEL(setOf(FileType.EPUB, FileType.PDF)),

    /** Folders of images; each folder is a chapter. */
    IMAGE(setOf(FileType.IMAGES)),
    ;

    val filePerSeries get() = this == BOOK
}

data class LibrarySettings(
    val id: Int,
    val name: String,
    val type: LibraryType,
    val folders: List<String>,
    val fileTypes: Set<FileType>,
    val excludePatterns: List<String>,
    val includeInDashboard: Boolean,
    val includeInSearch: Boolean,
    val useMetadata: Boolean,
    val manageCollections: Boolean,
    val manageGroups: Boolean,
    val folderCollections: Boolean,
    val folderWatching: Boolean,
    val scanIntervalMinutes: Int,
    val sortOrder: Int,
    val categoryId: Int?,
    val lastScannedAt: Long,
    val lastScanResult: String?,
) {
    val sourceId get() = Libraries.sourceId(id)

    companion object {
        fun from(row: ResultRow) =
            LibrarySettings(
                id = row[DochoLibraryTable.id].value,
                name = row[DochoLibraryTable.name],
                type = runCatching { LibraryType.valueOf(row[DochoLibraryTable.type]) }.getOrDefault(LibraryType.MANGA),
                folders = row[DochoLibraryTable.folders].lines().map { it.trim() }.filter { it.isNotEmpty() },
                fileTypes =
                    row[DochoLibraryTable.fileTypes]
                        .split(',')
                        .mapNotNull { runCatching { FileType.valueOf(it.trim()) }.getOrNull() }
                        .toSet(),
                excludePatterns = row[DochoLibraryTable.excludePatterns].lines().map { it.trim() }.filter { it.isNotEmpty() },
                includeInDashboard = row[DochoLibraryTable.includeInDashboard],
                includeInSearch = row[DochoLibraryTable.includeInSearch],
                useMetadata = row[DochoLibraryTable.useMetadata],
                manageCollections = row[DochoLibraryTable.manageCollections],
                manageGroups = row[DochoLibraryTable.manageGroups],
                folderCollections = row[DochoLibraryTable.folderCollections],
                folderWatching = row[DochoLibraryTable.folderWatching],
                scanIntervalMinutes = row[DochoLibraryTable.scanIntervalMinutes],
                sortOrder = row[DochoLibraryTable.sortOrder],
                categoryId = row[DochoLibraryTable.categoryId],
                lastScannedAt = row[DochoLibraryTable.lastScannedAt],
                lastScanResult = row[DochoLibraryTable.lastScanResult],
            )
    }
}
