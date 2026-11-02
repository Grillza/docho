package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.util.lang.compareToCaseInsensitiveNaturalOrder
import io.github.oshai.kotlinlogging.KotlinLogging
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.inList
import org.jetbrains.exposed.v1.jdbc.deleteWhere
import org.jetbrains.exposed.v1.jdbc.insert
import org.jetbrains.exposed.v1.jdbc.insertAndGetId
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import suwayomi.tachidesk.docho.DochoLibraryFileTable
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.collections.Collections
import suwayomi.tachidesk.docho.groups.SeriesGroups
import suwayomi.tachidesk.manga.impl.CategoryManga
import suwayomi.tachidesk.manga.impl.Manga
import suwayomi.tachidesk.manga.model.table.CategoryMangaTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import suwayomi.tachidesk.server.ApplicationDirs
import uy.kohesive.injekt.injectLazy
import java.io.File
import java.nio.file.FileSystems
import java.nio.file.PathMatcher
import java.time.Instant

/** What a scan did, for the library's status line. */
data class ScanResult(
    val series: Int,
    val files: Int,
    val added: Int,
    val updated: Int,
    val removed: Int,
    val millis: Long,
) {
    override fun toString() = "$series series, $files files ($added new, $updated changed, $removed removed) in ${millis / 1000}s"
}

/**
 * Scans a library's folders into series and chapters, as Kavita does: a folder per series
 * (except in book libraries, where each file is one), volumes and chapters read from file names,
 * and ComicInfo.xml or EPUB metadata, when present, taking precedence. Files that haven't changed
 * since the last scan are not opened again.
 */
class LibraryScanner(
    private val library: LibrarySettings,
) {
    private val logger = KotlinLogging.logger { }
    private val applicationDirs: ApplicationDirs by injectLazy()

    private data class Found(
        val file: File,
        val format: BookFormat,
        val root: File,
        /** The top-level folder the file is in, or null for a file directly in a library folder. */
        val seriesFolder: File?,
        /** Folders between [seriesFolder] (or the root, in book libraries) and the file. */
        val between: List<String>,
    )

    private data class Entry(
        val found: Found,
        val parsed: ParsedName,
        val metadata: BookMetadata,
        val pageCount: Int,
        val seriesName: String,
        val existingId: Int?,
        val changed: Boolean,
    ) {
        val seriesKey get() = FileNameParser.normalize(seriesName)
    }

    private val excludes: List<PathMatcher> =
        library.excludePatterns.map { pattern ->
            FileSystems.getDefault().getPathMatcher("glob:" + pattern.removePrefix("/"))
        }

    private fun excluded(
        root: File,
        file: File,
    ): Boolean {
        if (file.name.startsWith('.') || file.name.startsWith("@eaDir") || file.name == "__MACOSX") return true
        if (excludes.isEmpty()) return false
        val relative = root.toPath().relativize(file.toPath())
        return excludes.any { it.matches(relative) || it.matches(file.toPath().fileName) }
    }

    fun scan(): ScanResult {
        val started = System.currentTimeMillis()
        val roots = library.folders.map(::File)
        require(roots.isNotEmpty()) { "Add a folder to ${library.name} first" }
        // A missing or empty folder is more likely an unmounted drive than a deleted library;
        // scanning it would remove every series.
        roots.forEach { root ->
            require(root.isDirectory) { "${root.path} isn't there; is the drive mounted?" }
            require(root.listFiles().orEmpty().any { !it.name.startsWith('.') }) { "${root.path} is empty; is the drive mounted?" }
        }

        val found = roots.flatMap { root -> walk(root) }
        val known =
            transaction {
                DochoLibraryFileTable
                    .selectAll()
                    .where { DochoLibraryFileTable.library eq library.id }
                    .associateBy { it[DochoLibraryFileTable.path] }
            }

        var added = 0
        var updated = 0
        val entries =
            found.mapNotNull { item ->
                val row = known[item.file.absolutePath]
                val size = sizeOf(item.file)
                val modified = item.file.lastModified()
                val unchanged = row != null && row[DochoLibraryFileTable.size] == size && row[DochoLibraryFileTable.modifiedAt] == modified
                val (metadata, pages) =
                    if (unchanged) {
                        BookMetadata.fromJson(row!![DochoLibraryFileTable.metadata]) to row[DochoLibraryFileTable.pageCount]
                    } else {
                        try {
                            val inspection = BookFiles.inspect(item.file, item.format)
                            inspection.metadata to inspection.pageCount
                        } catch (e: Exception) {
                            logger.warn(e) { "Skipping ${item.file.absolutePath}: can't be opened" }
                            return@mapNotNull null
                        }
                    }
                if (row == null) added++ else if (!unchanged) updated++
                val parsed =
                    FileNameParser.parse(
                        if (item.file.isDirectory) item.file.name else item.file.nameWithoutExtension,
                        item.seriesFolder?.name,
                        item.between,
                    )
                Entry(
                    found = item,
                    parsed = parsed,
                    metadata = if (library.useMetadata) metadata else BookMetadata.EMPTY,
                    pageCount = pages,
                    seriesName = seriesNameFor(item, parsed, if (library.useMetadata) metadata else BookMetadata.EMPTY),
                    existingId = row?.get(DochoLibraryFileTable.id)?.value,
                    changed = !unchanged,
                ).also {
                    if (!unchanged) {
                        // Keep the metadata even when it isn't used, so turning it on doesn't need a rescan.
                        rawMetadata[item.file.absolutePath] = metadata
                    }
                }
            }

        val bySeries = entries.groupBy { it.seriesKey }
        val now = Instant.now().toEpochMilli()
        val seriesIds = mutableMapOf<String, Int>()
        for ((key, files) in bySeries) {
            seriesIds[key] = saveSeries(key, files, now)
        }

        // Files that are gone, and series with nothing left.
        val foundPaths = entries.map { it.found.file.absolutePath }.toSet()
        val removedRows = known.filterKeys { it !in foundPaths }.values
        val keptSeries = seriesIds.values.toSet()
        transaction {
            val gone = removedRows.map { it[DochoLibraryFileTable.id].value }
            gone.chunked(500).forEach { chunk -> DochoLibraryFileTable.deleteWhere { DochoLibraryFileTable.id inList chunk } }
            val emptySeries =
                MangaTable
                    .selectAll()
                    .where { MangaTable.sourceReference eq library.sourceId }
                    .map { it[MangaTable.id].value }
                    .filter { it !in keptSeries }
            emptySeries.chunked(500).forEach { chunk -> MangaTable.deleteWhere { MangaTable.id inList chunk } }
        }

        // Chapters: let the server's own chapter update take the new list, so read state stays.
        seriesIds.values.forEach { mangaId ->
            runCatching {
                kotlinx.coroutines.runBlocking { Manga.updateMangaAndChapters(mangaId, updateManga = false, updateChapters = true) }
            }.onFailure { logger.warn(it) { "Couldn't update chapters of series $mangaId" } }
        }

        if (library.manageCollections || library.folderCollections) {
            Collections.syncLibraryCollections(library, entries.map { seriesIds.getValue(it.seriesKey) to it.collectionNames() })
        }
        if (library.manageGroups) {
            SeriesGroups.syncMetadataGroups(
                entries.mapNotNull { entry ->
                    entry.metadata.seriesGroups.firstOrNull()?.let { seriesIds.getValue(entry.seriesKey) to it }
                },
            )
        }

        // Groups with members from this library pick up their new chapters.
        SeriesGroups.refreshGroupsOf(seriesIds.values)

        return ScanResult(
            series = seriesIds.size,
            files = entries.size,
            added = added,
            updated = updated,
            removed = removedRows.size,
            millis = System.currentTimeMillis() - started,
        )
    }

    private val rawMetadata = mutableMapOf<String, BookMetadata>()

    /**
     * The chapter number, from the file name or ComicInfo Number. Taggers often set Number to the
     * volume for a whole volume (v01 with Number 1); as in Kavita, that is a volume, not chapter 1.
     */
    private fun chapterNumberOf(
        entry: Entry,
        volume: Float?,
    ): Float? {
        entry.parsed.chapter?.let { return it }
        val number = entry.metadata.number ?: return null
        if (library.type.filePerSeries && volume == null && entry.metadata.series == null) return null
        if (volume != null && number == volume) return null
        return number
    }

    private fun Entry.collectionNames(): List<Pair<String, String>> {
        val names = mutableListOf<Pair<String, String>>()
        if (library.manageCollections) metadata.seriesGroups.forEach { names += "METADATA" to it }
        if (library.folderCollections) {
            found.between.firstOrNull()?.let { names += "FOLDER" to it }
        }
        return names
    }

    private fun sizeOf(file: File): Long =
        if (file.isDirectory) {
            file.listFiles().orEmpty().filter { it.isFile }.sumOf { it.length() }
        } else {
            file.length()
        }

    private fun seriesNameFor(
        item: Found,
        parsed: ParsedName,
        metadata: BookMetadata,
    ): String {
        metadata.series?.let { return it }
        if (library.type.filePerSeries) {
            return metadata.title ?: FileNameParser.clean(item.file.nameWithoutExtension).replace(Regex("""\s*\(\d{4}\)\s*"""), " ").trim()
        }
        return item.seriesFolder?.let { FileNameParser.clean(it.name).ifBlank { it.name } } ?: parsed.series
    }

    // ---- Walking folders ----

    private fun walk(root: File): List<Found> {
        val result = mutableListOf<Found>()
        val top = root.listFiles().orEmpty().filterNot { excluded(root, it) }.sortedWith { a, b -> a.name.compareToCaseInsensitiveNaturalOrder(b.name) }
        for (entry in top) {
            if (library.type.filePerSeries) {
                collect(root, entry, seriesFolder = null, between = emptyList(), result, depth = 0, betweenFromRoot = true)
            } else if (entry.isDirectory) {
                collect(root, entry, seriesFolder = entry, between = emptyList(), result, depth = 0, betweenFromRoot = false)
            } else {
                accept(root, entry, null, emptyList())?.let(result::add)
            }
        }
        return result
    }

    private fun collect(
        root: File,
        file: File,
        seriesFolder: File?,
        between: List<String>,
        result: MutableList<Found>,
        depth: Int,
        betweenFromRoot: Boolean,
    ) {
        if (excluded(root, file)) return
        if (!file.isDirectory) {
            accept(root, file, seriesFolder, between)?.let(result::add)
            return
        }
        if (depth > MAX_DEPTH) return
        val children = file.listFiles().orEmpty().filterNot { excluded(root, it) }
        // A folder of images is one chapter (Kavita's Images file type).
        if (FileType.IMAGES in library.fileTypes &&
            (file != seriesFolder || library.type == LibraryType.IMAGE) &&
            children.any { it.isFile && BookFormat.isImageName(it.name) }) {
            result += Found(file, BookFormat.IMAGES, root, seriesFolder, between)
        }
        val nextBetween =
            when {
                betweenFromRoot -> between + file.name
                file == seriesFolder -> between
                else -> between + file.name
            }
        children
            .filter { it.isDirectory || BookFormat.of(it) != null }
            .forEach { collect(root, it, seriesFolder, nextBetween, result, depth + 1, betweenFromRoot) }
    }

    private fun accept(
        root: File,
        file: File,
        seriesFolder: File?,
        between: List<String>,
    ): Found? {
        val format = BookFormat.of(file)?.takeIf { it != BookFormat.IMAGES } ?: return null
        if (format.fileType !in library.fileTypes) return null
        return Found(file, format, root, seriesFolder, between)
    }

    // ---- Saving ----

    private fun saveSeries(
        key: String,
        files: List<Entry>,
        now: Long,
    ): Int {
        val first =
            files.sortedWith(
                compareBy<Entry> { it.parsed.isSpecial }
                    .thenBy { it.metadata.volume ?: it.parsed.volume ?: Float.MAX_VALUE }
                    .thenBy { it.metadata.number ?: it.parsed.chapter ?: -1f },
            ).first()
        val meta = files.map { it.metadata }.firstOrNull { !it.isEmpty() } ?: BookMetadata.EMPTY
        val title = files.groupingBy { it.seriesName }.eachCount().maxBy { it.value }.key
        val url = "/library/${library.id}/$key"
        val seriesFolder = first.found.seriesFolder

        val mangaId =
            transaction {
                val existing =
                    MangaTable
                        .selectAll()
                        .where { (MangaTable.sourceReference eq library.sourceId) and (MangaTable.url eq url) }
                        .firstOrNull()
                val description = meta.summary
                val id =
                    if (existing == null) {
                        MangaTable
                            .insertAndGetId {
                                it[MangaTable.url] = url
                                it[MangaTable.title] = title
                                it[MangaTable.sourceReference] = library.sourceId
                                it[MangaTable.initialized] = true
                                it[MangaTable.inLibrary] = true
                                it[MangaTable.inLibraryAt] = now / 1000
                                it[MangaTable.author] = meta.writers.joinToString(", ").ifBlank { null }
                                it[MangaTable.artist] = meta.artists.joinToString(", ").ifBlank { null }
                                it[MangaTable.description] = description
                                it[MangaTable.genre] = meta.genres.joinToString(", ").ifBlank { null }
                                it[MangaTable.status] = meta.status ?: SManga.UNKNOWN
                                it[MangaTable.lastFetchedAt] = now / 1000
                            }.value
                    } else {
                        val id = existing[MangaTable.id].value
                        MangaTable.update({ MangaTable.id eq id }) {
                            it[MangaTable.title] = title
                            it[MangaTable.initialized] = true
                            meta.writers.takeIf { w -> w.isNotEmpty() }?.let { w -> it[MangaTable.author] = w.joinToString(", ") }
                            meta.artists.takeIf { a -> a.isNotEmpty() }?.let { a -> it[MangaTable.artist] = a.joinToString(", ") }
                            description?.let { d -> it[MangaTable.description] = d }
                            meta.genres.takeIf { g -> g.isNotEmpty() }?.let { g -> it[MangaTable.genre] = g.joinToString(", ") }
                            meta.status?.let { s -> it[MangaTable.status] = s }
                        }
                        id
                    }

                // Files
                files.forEach { entry ->
                    val volume = entry.metadata.volume ?: entry.parsed.volume
                    val chapter = chapterNumberOf(entry, volume)
                    val chapterUrl = "/file" + entry.found.file.absolutePath
                    val apply: (org.jetbrains.exposed.v1.core.statements.UpdateBuilder<*>) -> Unit = { it ->
                        it[DochoLibraryFileTable.manga] = id
                        it[DochoLibraryFileTable.path] = entry.found.file.absolutePath
                        it[DochoLibraryFileTable.chapterUrl] = chapterUrl
                        it[DochoLibraryFileTable.format] = entry.found.format.name
                        it[DochoLibraryFileTable.seriesName] = entry.seriesName.take(512)
                        it[DochoLibraryFileTable.seriesKey] = key.take(512)
                        it[DochoLibraryFileTable.title] = entry.metadata.title?.take(512)
                        it[DochoLibraryFileTable.volume] = volume
                        it[DochoLibraryFileTable.chapter] = chapter
                        it[DochoLibraryFileTable.isSpecial] = entry.parsed.isSpecial && volume == null && chapter == null
                        it[DochoLibraryFileTable.releaseGroup] = entry.parsed.releaseGroup?.take(256)
                        it[DochoLibraryFileTable.pageCount] = entry.pageCount
                        it[DochoLibraryFileTable.size] = sizeOf(entry.found.file)
                        it[DochoLibraryFileTable.modifiedAt] = entry.found.file.lastModified()
                        it[DochoLibraryFileTable.metadata] = (rawMetadata[entry.found.file.absolutePath] ?: entry.metadata).toJson()
                    }
                    if (entry.existingId == null) {
                        DochoLibraryFileTable.insert {
                            it[DochoLibraryFileTable.library] = this@LibraryScanner.library.id
                            apply(it)
                        }
                    } else {
                        DochoLibraryFileTable.update({ DochoLibraryFileTable.id eq entry.existingId }) { apply(it) }
                    }
                }

                // Kavita's series fields
                val info = DochoSeriesInfoTable.selectAll().where { DochoSeriesInfoTable.manga eq id }.firstOrNull()
                val newest = files.maxOf { it.found.file.lastModified() }
                val fill: (org.jetbrains.exposed.v1.core.statements.UpdateBuilder<*>) -> Unit = {
                    it[DochoSeriesInfoTable.library] = library.id
                    it[DochoSeriesInfoTable.folder] = seriesFolder?.absolutePath
                    it[DochoSeriesInfoTable.sortName] = (meta.seriesSort ?: FileNameParser.sortName(title)).take(512)
                    it[DochoSeriesInfoTable.localizedName] = meta.localizedSeries?.take(512)
                    it[DochoSeriesInfoTable.format] = first.found.format.name
                    it[DochoSeriesInfoTable.ageRating] = meta.ageRating?.take(64)
                    it[DochoSeriesInfoTable.releaseYear] = files.mapNotNull { e -> e.metadata.year ?: e.parsed.year }.minOrNull()
                    it[DochoSeriesInfoTable.language] = meta.language?.take(32)
                    it[DochoSeriesInfoTable.publisher] = meta.publisher?.take(256)
                    it[DochoSeriesInfoTable.pageCount] = files.sumOf { e -> e.pageCount.coerceAtLeast(0) }
                    it[DochoSeriesInfoTable.updatedAt] = newest
                }
                if (info == null) {
                    DochoSeriesInfoTable.insert {
                        it[DochoSeriesInfoTable.manga] = id
                        it[DochoSeriesInfoTable.addedAt] = now
                        fill(it)
                    }
                } else {
                    DochoSeriesInfoTable.update({ DochoSeriesInfoTable.manga eq id }) { fill(it) }
                }
                id
            }

        // In the library, under the library's category.
        library.categoryId?.let { categoryId ->
            val inCategory =
                transaction {
                    CategoryMangaTable
                        .selectAll()
                        .where { (CategoryMangaTable.category eq categoryId) and (CategoryMangaTable.manga eq mangaId) }
                        .any()
                }
            val grouped = SeriesGroups.isHiddenMember(mangaId)
            if (!inCategory && !grouped) CategoryManga.addMangaToCategory(mangaId, categoryId)
        }

        updateCover(mangaId, files, seriesFolder)
        return mangaId
    }

    private fun updateCover(
        mangaId: Int,
        files: List<Entry>,
        seriesFolder: File?,
    ) {
        val coverFile = File(Libraries.coversDir(applicationDirs), "$mangaId")
        val anyChanged = files.any { it.changed }
        if (coverFile.exists() && !anyChanged) {
            ensureThumbnail(mangaId, coverFile)
            return
        }
        // A cover image in the series folder (cover.jpg, folder.png), as Kavita uses.
        val folderCover =
            seriesFolder?.listFiles()?.firstOrNull { f ->
                f.isFile && BookFormat.isImageName(f.name) && f.nameWithoutExtension.lowercase() in setOf("cover", "folder", "poster")
            }
        val bytes =
            folderCover?.readBytes() ?: run {
                val first =
                    files
                        .sortedWith(
                            compareBy<Entry> { it.parsed.isSpecial }
                                .thenBy { it.metadata.volume ?: it.parsed.volume ?: Float.MAX_VALUE }
                                .thenBy { it.metadata.number ?: it.parsed.chapter ?: -1f }
                                .thenComparator { a, b -> a.found.file.name.compareToCaseInsensitiveNaturalOrder(b.found.file.name) },
                        ).first()
                BookFiles.cover(first.found.file, first.found.format)
            } ?: return
        coverFile.parentFile.mkdirs()
        coverFile.writeBytes(shrinkCover(bytes))
        ensureThumbnail(mangaId, coverFile, force = true)
    }

    private fun ensureThumbnail(
        mangaId: Int,
        coverFile: File,
        force: Boolean = false,
    ) {
        val current = transaction { MangaTable.selectAll().where { MangaTable.id eq mangaId }.first()[MangaTable.thumbnail_url] }
        if (!force && current == coverFile.absolutePath) return
        transaction {
            MangaTable.update({ MangaTable.id eq mangaId }) {
                it[MangaTable.thumbnail_url] = coverFile.absolutePath
                it[MangaTable.thumbnailUrlLastFetched] = System.currentTimeMillis() / 1000
            }
        }
        Manga.clearThumbnail(mangaId)
    }

    /** Covers at most 600 pixels wide, as JPEG, so library pages load quickly. */
    private fun shrinkCover(bytes: ByteArray): ByteArray =
        runCatching {
            val image = javax.imageio.ImageIO.read(java.io.ByteArrayInputStream(bytes)) ?: return bytes
            if (image.width <= COVER_WIDTH && bytes.size < 400_000) return bytes
            val width = minOf(COVER_WIDTH, image.width)
            val height = (image.height.toLong() * width / image.width).toInt().coerceAtLeast(1)
            val scaled = java.awt.image.BufferedImage(width, height, java.awt.image.BufferedImage.TYPE_INT_RGB)
            val g = scaled.createGraphics()
            g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION, java.awt.RenderingHints.VALUE_INTERPOLATION_BICUBIC)
            g.setRenderingHint(java.awt.RenderingHints.KEY_RENDERING, java.awt.RenderingHints.VALUE_RENDER_QUALITY)
            g.drawImage(image, 0, 0, width, height, null)
            g.dispose()
            BookFiles.encodeJpeg(scaled, 0.85f)
        }.getOrDefault(bytes)

    companion object {
        private const val MAX_DEPTH = 6
        private const val COVER_WIDTH = 600
    }
}
