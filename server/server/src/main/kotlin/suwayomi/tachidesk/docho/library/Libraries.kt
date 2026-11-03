package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.jdbc.deleteWhere
import org.jetbrains.exposed.v1.jdbc.insert
import org.jetbrains.exposed.v1.jdbc.insertAndGetId
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import org.jetbrains.exposed.v1.jdbc.select
import suwayomi.tachidesk.manga.model.table.ChapterTable
import org.jetbrains.exposed.v1.core.isNotNull
import org.jetbrains.exposed.v1.core.inSubQuery
import org.jetbrains.exposed.v1.core.lessEq
import org.jetbrains.exposed.v1.core.greater
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.greaterEq
import suwayomi.tachidesk.docho.DochoLibraryTable
import suwayomi.tachidesk.manga.impl.Category
import suwayomi.tachidesk.manga.impl.util.source.GetSource
import suwayomi.tachidesk.manga.model.table.CategoryTable
import suwayomi.tachidesk.manga.model.table.ExtensionTable
import suwayomi.tachidesk.manga.model.table.MangaTable
import suwayomi.tachidesk.manga.model.table.SourceTable
import suwayomi.tachidesk.server.ApplicationDirs
import uy.kohesive.injekt.injectLazy
import java.io.File
import java.nio.file.ClosedWatchServiceException
import java.nio.file.FileSystems
import java.nio.file.Path
import java.nio.file.StandardWatchEventKinds
import java.nio.file.WatchKey
import java.nio.file.WatchService
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** Changes to a library; null fields are left as they are. */
data class LibraryInput(
    val name: String? = null,
    val type: LibraryType? = null,
    val folders: List<String>? = null,
    val fileTypes: List<FileType>? = null,
    val excludePatterns: List<String>? = null,
    val includeInDashboard: Boolean? = null,
    val includeInSearch: Boolean? = null,
    val useMetadata: Boolean? = null,
    val manageCollections: Boolean? = null,
    val manageGroups: Boolean? = null,
    val folderCollections: Boolean? = null,
    val folderWatching: Boolean? = null,
    val scanIntervalMinutes: Int? = null,
    val sortOrder: Int? = null,
)

data class ScanStatus(
    val libraryId: Int,
    val running: Boolean,
    val message: String?,
)

/**
 * Kavita-style libraries: kept in the database, offered as sources, scanned on a schedule and
 * when their folders change.
 */
object Libraries {
    private val logger = KotlinLogging.logger { }
    private val applicationDirs: ApplicationDirs by injectLazy()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Library sources use ids from here up; the series groups source is this id itself. */
    const val SOURCE_ID_BASE = 0x0D0C_0000_0000_0000L

    /**
     * The language Dōchō's own sources report: "other", like built-in sources (Local, Kavita), not
     * "all", which the apps show as "Multi" for extensions in many languages.
     */
    const val SOURCE_LANG = "other"
    const val EXTENSION_NAME = "Dōchō Libraries"
    private const val EXTENSION_PKG = "docho.libraries"

    fun sourceId(libraryId: Int) = SOURCE_ID_BASE + libraryId

    fun libraryIdOf(sourceId: Long): Int? = (sourceId - SOURCE_ID_BASE).takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt()

    /** Library sources and the series groups source, whose covers and pages the server makes itself. */
    fun isDochoSource(sourceId: Long) = sourceId in SOURCE_ID_BASE..(SOURCE_ID_BASE + Int.MAX_VALUE)

    fun coversDir(dirs: ApplicationDirs = applicationDirs) = File(dirs.dataRoot, "docho/covers")

    private val sources = ConcurrentHashMap<Int, LibrarySource>()

    fun source(sourceId: Long): FileBackedSource? = libraryIdOf(sourceId)?.let { sources[it] }

    fun list(): List<LibrarySettings> =
        transaction {
            DochoLibraryTable.selectAll().map(LibrarySettings::from)
        }.sortedWith(compareBy<LibrarySettings> { it.sortOrder }.thenBy { it.name.lowercase() })

    fun get(id: Int): LibrarySettings? =
        transaction {
            DochoLibraryTable.selectAll().where { DochoLibraryTable.id eq id }.firstOrNull()?.let(LibrarySettings::from)
        }

    // ---- Setup ----

    private fun extensionId(): Int =
        transaction {
            ExtensionTable.selectAll().where { ExtensionTable.pkgName eq EXTENSION_PKG }.firstOrNull()?.get(ExtensionTable.id)?.value
                ?: ExtensionTable
                    .insertAndGetId {
                        it[apkName] = "dochoLibraries"
                        it[name] = EXTENSION_NAME
                        it[pkgName] = EXTENSION_PKG
                        it[versionName] = "1.0"
                        it[versionCode] = 0
                        it[lang] = SOURCE_LANG
                        it[extensionLib] = "1.5"
                        it[contentWarning] = 0
                        it[isInstalled] = true
                    }.value
        }

    private fun register(library: LibrarySettings) {
        val extension = extensionId()
        transaction {
            val row = SourceTable.selectAll().where { SourceTable.id eq library.sourceId }.firstOrNull()
            if (row == null) {
                SourceTable.insert {
                    it[id] = library.sourceId
                    it[name] = library.name.take(128)
                    it[lang] = SOURCE_LANG
                    it[SourceTable.extension] = extension
                }
            } else if (row[SourceTable.name] != library.name) {
                SourceTable.update({ SourceTable.id eq library.sourceId }) { it[name] = library.name.take(128) }
            }
        }
        val source = LibrarySource(library.id, library.name)
        sources[library.id] = source
        GetSource.registerSource(source.id to source)
    }

    /** At startup: offer every library as a source, and start the schedule and folder watching. */
    fun start() {
        // Sources and the extension registered before 0.32.1 said "all".
        transaction {
            SourceTable.update({ (SourceTable.id greaterEq SOURCE_ID_BASE) and (SourceTable.lang eq "all") }) { it[lang] = SOURCE_LANG }
            ExtensionTable.update({ (ExtensionTable.pkgName eq EXTENSION_PKG) and (ExtensionTable.lang eq "all") }) { it[lang] = SOURCE_LANG }
            // Library chapters stored before 0.32.4 had the release group as their scanlator.
            val libraryManga =
                MangaTable
                    .select(MangaTable.id)
                    .where { (MangaTable.sourceReference greater SOURCE_ID_BASE) and (MangaTable.sourceReference lessEq SOURCE_ID_BASE + Int.MAX_VALUE) }
            ChapterTable.update({ (ChapterTable.manga inSubQuery libraryManga) and ChapterTable.scanlator.isNotNull() }) { it[scanlator] = null }
        }
        list().forEach { library ->
            runCatching { register(library) }.onFailure { logger.error(it) { "Couldn't set up library ${library.name}" } }
        }
        scope.launch {
            delay(30.seconds)
            while (true) {
                val now = System.currentTimeMillis()
                list()
                    .filter { it.scanIntervalMinutes > 0 && now - it.lastScannedAt >= it.scanIntervalMinutes * 60_000L }
                    .forEach { scan(it.id) }
                delay(5.minutes)
            }
        }
        restartWatching()
    }

    // ---- Changes ----

    fun create(input: LibraryInput): LibrarySettings {
        val name = input.name?.trim()?.ifBlank { null } ?: throw IllegalArgumentException("Name the library")
        val type = input.type ?: LibraryType.MANGA
        require(list().none { it.name.equals(name, ignoreCase = true) }) { "There's already a library called $name" }
        val categoryId = categoryFor(name)
        val id =
            transaction {
                DochoLibraryTable
                    .insertAndGetId {
                        it[DochoLibraryTable.name] = name
                        it[DochoLibraryTable.type] = type.name
                        it[folders] = input.folders.orEmpty().joinToString("\n")
                        it[fileTypes] = (input.fileTypes?.toSet() ?: type.defaultFileTypes).joinToString(",") { t -> t.name }
                        it[excludePatterns] = input.excludePatterns.orEmpty().joinToString("\n")
                        input.includeInDashboard?.let { v -> it[includeInDashboard] = v }
                        input.includeInSearch?.let { v -> it[includeInSearch] = v }
                        input.useMetadata?.let { v -> it[useMetadata] = v }
                        input.manageCollections?.let { v -> it[manageCollections] = v }
                        input.manageGroups?.let { v -> it[manageGroups] = v }
                        it[folderCollections] = input.folderCollections ?: (type == LibraryType.BOOK)
                        input.folderWatching?.let { v -> it[folderWatching] = v }
                        input.scanIntervalMinutes?.let { v -> it[scanIntervalMinutes] = v }
                        it[sortOrder] = input.sortOrder ?: (list().maxOfOrNull { l -> l.sortOrder } ?: 0) + 1
                        it[DochoLibraryTable.categoryId] = categoryId
                    }.value
            }
        val library = get(id)!!
        register(library)
        restartWatching()
        if (library.folders.isNotEmpty()) scan(id)
        return library
    }

    fun update(
        id: Int,
        input: LibraryInput,
    ): LibrarySettings {
        val before = get(id) ?: throw IllegalArgumentException("No library $id")
        input.name?.let { name ->
            require(name.isNotBlank()) { "Name the library" }
            require(list().none { it.id != id && it.name.equals(name.trim(), ignoreCase = true) }) { "There's already a library called $name" }
        }
        transaction {
            DochoLibraryTable.update({ DochoLibraryTable.id eq id }) {
                input.name?.let { v -> it[name] = v.trim() }
                input.type?.let { v -> it[type] = v.name }
                input.folders?.let { v -> it[folders] = v.map(String::trim).filter(String::isNotEmpty).joinToString("\n") }
                input.fileTypes?.let { v -> it[fileTypes] = v.toSet().joinToString(",") { t -> t.name } }
                input.excludePatterns?.let { v -> it[excludePatterns] = v.map(String::trim).filter(String::isNotEmpty).joinToString("\n") }
                input.includeInDashboard?.let { v -> it[includeInDashboard] = v }
                input.includeInSearch?.let { v -> it[includeInSearch] = v }
                input.useMetadata?.let { v -> it[useMetadata] = v }
                input.manageCollections?.let { v -> it[manageCollections] = v }
                input.manageGroups?.let { v -> it[manageGroups] = v }
                input.folderCollections?.let { v -> it[folderCollections] = v }
                input.folderWatching?.let { v -> it[folderWatching] = v }
                input.scanIntervalMinutes?.let { v -> it[scanIntervalMinutes] = v.coerceAtLeast(0) }
                input.sortOrder?.let { v -> it[sortOrder] = v }
            }
        }
        val after = get(id)!!
        if (after.name != before.name) {
            after.categoryId?.let { categoryId ->
                transaction { CategoryTable.update({ CategoryTable.id eq categoryId }) { it[CategoryTable.name] = after.name } }
            }
        }
        register(after)
        restartWatching()
        val rescan =
            after.folders != before.folders ||
                after.type != before.type ||
                after.fileTypes != before.fileTypes ||
                after.excludePatterns != before.excludePatterns ||
                after.useMetadata != before.useMetadata
        if (rescan && after.folders.isNotEmpty()) scan(id)
        return after
    }

    /** Removes the library and its series from the server; the files stay where they are. */
    fun delete(id: Int) {
        val library = get(id) ?: return
        transaction {
            MangaTable.deleteWhere { MangaTable.sourceReference eq library.sourceId }
            SourceTable.deleteWhere { SourceTable.id eq library.sourceId }
            DochoLibraryTable.deleteWhere { DochoLibraryTable.id eq id }
        }
        library.categoryId?.let { Category.removeCategory(it) }
        sources.remove(id)
        GetSource.unregisterSource(library.sourceId)
        restartWatching()
    }

    private fun categoryFor(name: String): Int =
        transaction {
            CategoryTable.selectAll().where { CategoryTable.name eq name }.firstOrNull()?.get(CategoryTable.id)?.value
        } ?: Category.createCategory(name)

    // ---- Scanning ----

    private val scanLocks = ConcurrentHashMap<Int, Mutex>()
    private val _status = MutableStateFlow<Map<Int, ScanStatus>>(emptyMap())
    val status: StateFlow<Map<Int, ScanStatus>> = _status.asStateFlow()

    fun scanAll() = list().forEach { scan(it.id) }

    /** Scans in the background; a scan already running for the library is left to finish. */
    fun scan(id: Int): Job? {
        val lock = scanLocks.getOrPut(id) { Mutex() }
        if (lock.isLocked) return null
        return scope.launch {
            lock.withLock {
                val library = get(id) ?: return@withLock
                setStatus(ScanStatus(id, true, "Scanning ${library.name}…"))
                val message =
                    try {
                        val result = LibraryScanner(library).scan()
                        logger.info { "Scanned ${library.name}: $result" }
                        result.toString()
                    } catch (e: Exception) {
                        logger.warn(e) { "Scanning ${library.name} failed" }
                        "Failed: ${e.message}"
                    }
                transaction {
                    DochoLibraryTable.update({ DochoLibraryTable.id eq id }) {
                        it[lastScannedAt] = System.currentTimeMillis()
                        it[lastScanResult] = message.take(1024)
                    }
                }
                setStatus(ScanStatus(id, false, message))
            }
        }
    }

    suspend fun scanNow(id: Int) {
        scan(id)?.join() ?: scanLocks[id]?.withLock { }
    }

    private fun setStatus(status: ScanStatus) = _status.update { it + (status.libraryId to status) }

    // ---- Folder watching ----

    private var watcher: Watcher? = null

    @Synchronized
    private fun restartWatching() {
        watcher?.close()
        val watched = list().filter { it.folderWatching && it.folders.isNotEmpty() }
        watcher = if (watched.isEmpty()) null else Watcher(watched).also { it.start() }
    }

    /** Rescans a library a little after its files stop changing. */
    private class Watcher(
        private val libraries: List<LibrarySettings>,
    ) {
        private val service: WatchService = FileSystems.getDefault().newWatchService()
        private val keys = ConcurrentHashMap<WatchKey, Pair<Int, Path>>()
        private val pending = ConcurrentHashMap<Int, Job>()

        fun start() {
            thread(name = "docho-library-watcher", isDaemon = true) {
                libraries.forEach { library ->
                    library.folders.map(::File).filter(File::isDirectory).forEach { root -> registerTree(library.id, root) }
                }
                try {
                    while (true) {
                        val key = service.take()
                        val (libraryId, dir) = keys[key] ?: continue
                        for (event in key.pollEvents()) {
                            val child = dir.resolve(event.context() as? Path ?: continue).toFile()
                            if (event.kind() == StandardWatchEventKinds.ENTRY_CREATE && child.isDirectory) registerTree(libraryId, child)
                        }
                        key.reset()
                        debounce(libraryId)
                    }
                } catch (_: ClosedWatchServiceException) {
                } catch (_: InterruptedException) {
                }
            }
        }

        private fun registerTree(
            libraryId: Int,
            dir: File,
            depth: Int = 0,
        ) {
            if (depth > 4 || dir.name.startsWith('.')) return
            runCatching {
                val key =
                    dir.toPath().register(
                        service,
                        StandardWatchEventKinds.ENTRY_CREATE,
                        StandardWatchEventKinds.ENTRY_DELETE,
                        StandardWatchEventKinds.ENTRY_MODIFY,
                    )
                keys[key] = libraryId to dir.toPath()
            }
            dir.listFiles().orEmpty().filter(File::isDirectory).forEach { registerTree(libraryId, it, depth + 1) }
        }

        private fun debounce(libraryId: Int) {
            pending.remove(libraryId)?.cancel()
            pending[libraryId] =
                scope.launch {
                    // Copies to a slow drive take a while; wait for them to finish.
                    delay(60.seconds)
                    pending.remove(libraryId)
                    scan(libraryId)
                }
        }

        fun close() {
            pending.values.forEach { it.cancel() }
            runCatching { service.close() }
        }
    }
}
