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
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.statements.UpdateStatement
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import suwayomi.tachidesk.docho.DochoSeriesInfoTable
import suwayomi.tachidesk.docho.sync.SyncBridge
import suwayomi.tachidesk.manga.model.table.MangaTable

/**
 * Series details edited on the server, as in Kavita: an edited field is locked, so scans keep it
 * over what the files say, until it's reset. Edits reach the apps through Dōchō Sync
 * ([SyncBridge] sends them as "details" records) and when the apps next fetch the series.
 */
object SeriesMetadata {
    private val logger = KotlinLogging.logger {}
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The fields that can be edited, by the names the WebUI and the overrides use. */
    enum class Field {
        TITLE,
        LOCALIZED_NAME,
        SORT_NAME,
        SUMMARY,
        WRITERS,
        ARTISTS,
        GENRES,
        STATUS,
        PUBLISHER,
        RELEASE_YEAR,
        AGE_RATING,
        LANGUAGE,
        ;

        val key: String get() = name.lowercase()
    }

    /** The edited fields of one series. Lists are kept as lists, numbers as numbers. */
    class Overrides(
        val values: Map<Field, JsonElement>,
    ) {
        operator fun contains(field: Field) = field in values

        fun string(field: Field): String? = (values[field] as? JsonPrimitive)?.contentOrNull

        fun int(field: Field): Int? = (values[field] as? JsonPrimitive)?.intOrNull

        fun list(field: Field): List<String>? = (values[field] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }

        fun toJson(): String = JsonObject(values.mapKeys { it.key.key }).toString()

        companion object {
            val NONE = Overrides(emptyMap())

            fun parse(text: String?): Overrides {
                if (text.isNullOrBlank()) return NONE
                val obj = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return NONE
                return Overrides(
                    obj.entries
                        .mapNotNull { (key, value) -> Field.entries.firstOrNull { it.key == key }?.let { it to value } }
                        .toMap(),
                )
            }
        }
    }

    /** One edit: the fields to set, and the fields to reset to what the files say. */
    class Edit(
        val set: Map<Field, JsonElement>,
        val reset: Set<Field>,
    )

    fun overridesOf(mangaId: Int): Overrides =
        transaction {
            DochoSeriesInfoTable
                .selectAll()
                .where { DochoSeriesInfoTable.manga eq mangaId }
                .firstOrNull()
                ?.get(DochoSeriesInfoTable.overrides)
        }.let(Overrides::parse)

    /** Saves [edit] on a library series and applies it straight away. */
    fun edit(
        mangaId: Int,
        edit: Edit,
    ) {
        val info =
            transaction { DochoSeriesInfoTable.selectAll().where { DochoSeriesInfoTable.manga eq mangaId }.firstOrNull() }
                ?: throw IllegalArgumentException("Only series from a library can be edited")
        val libraryId = info[DochoSeriesInfoTable.library].value
        val current = Overrides.parse(info[DochoSeriesInfoTable.overrides])
        val values = current.values.toMutableMap()
        edit.reset.forEach { values.remove(it) }
        edit.set.forEach { (field, value) -> values[field] = clean(field, value) }
        val overrides = Overrides(values)
        transaction {
            DochoSeriesInfoTable.update({ DochoSeriesInfoTable.manga eq mangaId }) {
                it[DochoSeriesInfoTable.overrides] = overrides.toJson()
                it[editedAt] = System.currentTimeMillis()
            }
            apply(mangaId, overrides)
        }
        // A reset field comes back from the files, which takes a scan.
        if (edit.reset.isNotEmpty()) {
            scope.launch {
                runCatching { Libraries.scanNow(libraryId) }.onFailure { logger.warn(it) { "Rescan after reset failed" } }
                SyncBridge.publishDetails(mangaId)
            }
        }
        SyncBridge.publishDetails(mangaId)
    }

    private fun clean(
        field: Field,
        value: JsonElement,
    ): JsonElement =
        when (field) {
            Field.WRITERS, Field.ARTISTS, Field.GENRES ->
                JsonArray(
                    (value as? JsonArray)
                        ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.trim()?.ifEmpty { null } }
                        ?.distinct()
                        ?.map(::JsonPrimitive)
                        .orEmpty(),
                )
            Field.STATUS, Field.RELEASE_YEAR ->
                (value as? JsonPrimitive)?.intOrNull?.let(::JsonPrimitive) ?: throw IllegalArgumentException("${field.key} must be a number")
            else -> JsonPrimitive((value as? JsonPrimitive)?.contentOrNull?.trim().orEmpty())
        }

    /** Writes [overrides] over a series' details; scans call this after writing the files' details. */
    fun apply(
        mangaId: Int,
        overrides: Overrides,
    ) {
        if (overrides.values.isEmpty()) return
        // Collected first: an UPDATE with nothing to set is an error.
        val manga = mutableListOf<(UpdateStatement) -> Unit>()
        overrides.string(Field.TITLE)?.ifBlank { null }?.let { v -> manga += { it[MangaTable.title] = v.take(512) } }
        overrides.string(Field.SUMMARY)?.let { v -> manga += { it[MangaTable.description] = v.ifBlank { null } } }
        overrides.list(Field.WRITERS)?.let { v -> manga += { it[MangaTable.author] = v.joinToString(", ").ifBlank { null } } }
        overrides.list(Field.ARTISTS)?.let { v -> manga += { it[MangaTable.artist] = v.joinToString(", ").ifBlank { null } } }
        overrides.list(Field.GENRES)?.let { v -> manga += { it[MangaTable.genre] = v.joinToString(", ").ifBlank { null } } }
        overrides.int(Field.STATUS)?.let { v -> manga += { it[MangaTable.status] = v } }

        val info = mutableListOf<(UpdateStatement) -> Unit>()
        overrides.string(Field.LOCALIZED_NAME)?.let { v -> info += { it[DochoSeriesInfoTable.localizedName] = v.ifBlank { null }?.take(512) } }
        val sort =
            overrides.string(Field.SORT_NAME)?.ifBlank { null }
                ?: overrides.string(Field.TITLE)?.ifBlank { null }?.let(FileNameParser::sortName)
        sort?.let { v -> info += { it[DochoSeriesInfoTable.sortName] = v.take(512) } }
        overrides.string(Field.PUBLISHER)?.let { v -> info += { it[DochoSeriesInfoTable.publisher] = v.ifBlank { null }?.take(256) } }
        if (Field.RELEASE_YEAR in overrides) {
            val year = overrides.int(Field.RELEASE_YEAR)?.takeIf { it > 0 }
            info += { it[DochoSeriesInfoTable.releaseYear] = year }
        }
        overrides.string(Field.AGE_RATING)?.let { v -> info += { it[DochoSeriesInfoTable.ageRating] = v.ifBlank { null }?.take(64) } }
        overrides.string(Field.LANGUAGE)?.let { v -> info += { it[DochoSeriesInfoTable.language] = v.ifBlank { null }?.take(32) } }

        transaction {
            if (manga.isNotEmpty()) MangaTable.update({ MangaTable.id eq mangaId }) { row -> manga.forEach { it(row) } }
            if (info.isNotEmpty()) DochoSeriesInfoTable.update({ DochoSeriesInfoTable.manga eq mangaId }) { row -> info.forEach { it(row) } }
        }
    }
}
