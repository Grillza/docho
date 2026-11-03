package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import org.w3c.dom.Element
import java.io.InputStream
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Metadata read from a ComicInfo.xml or an EPUB's package document, as ComicInfo field names
 * (Series, Number, Volume, Writer, SeriesGroup, ...).
 */
@JvmInline
value class BookMetadata(
    val fields: Map<String, String>,
) {
    operator fun get(field: String): String? = fields[field]?.trim()?.ifBlank { null }

    val series get() = this["Series"]
    val title get() = this["Title"]
    val number get() = this["Number"]?.toFloatOrNull()
    val volume get() = this["Volume"]?.toFloatOrNull()
    val summary get() = this["Summary"]
    val year get() = this["Year"]?.toIntOrNull()?.takeIf { it > 0 }
    val localizedSeries get() = this["LocalizedSeries"]
    val seriesSort get() = this["SeriesSort"]
    val ageRating get() = this["AgeRating"]
    val language get() = this["LanguageISO"]
    val publisher get() = this["Publisher"]

    /** Kavita makes collections from these. */
    val seriesGroups get() = list("SeriesGroup")
    val storyArcs get() = list("StoryArc")

    val writers get() = list("Writer")
    val artists get() = (list("Penciller") + list("Inker") + list("CoverArtist")).distinct()
    val genres get() = (list("Genre") + list("Tags")).distinct()

    /** Mihon's status, from Tachiyomi's ComicInfo extension. */
    val status: Int?
        get() =
            when (this["PublishingStatusTachiyomi"]?.lowercase()) {
                "ongoing" -> 1
                "completed" -> 2
                "licensed" -> 3
                "publishing finished" -> 4
                "cancelled" -> 5
                "on hiatus" -> 6
                else -> null
            }

    fun isEmpty() = fields.isEmpty()

    fun toJson(): String = Json.encodeToString(JsonObject.serializer(), JsonObject(fields.mapValues { JsonPrimitive(it.value) }))

    private fun list(field: String): List<String> =
        this[field]
            ?.split(',', ';')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            .orEmpty()

    companion object {
        val EMPTY = BookMetadata(emptyMap())

        fun fromJson(json: String?): BookMetadata {
            if (json.isNullOrBlank()) return EMPTY
            return runCatching {
                val obj = Json.decodeFromString(JsonObject.serializer(), json)
                BookMetadata(obj.mapValues { it.value.jsonPrimitive.contentOrNull.orEmpty() })
            }.getOrDefault(EMPTY)
        }

        private fun documentBuilder() =
            DocumentBuilderFactory
                .newInstance()
                .apply {
                    isNamespaceAware = true
                    // Files come from the library; don't fetch anything they point at.
                    setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
                    setFeature("http://xml.org/sax/features/external-general-entities", false)
                    setFeature("http://xml.org/sax/features/external-parameter-entities", false)
                    isXIncludeAware = false
                    isExpandEntityReferences = false
                }.newDocumentBuilder()

        /** Reads a ComicInfo.xml; each child of the root element is a field. */
        fun fromComicInfo(stream: InputStream): BookMetadata =
            runCatching {
                val root = documentBuilder().parse(stream).documentElement
                val fields = mutableMapOf<String, String>()
                val children = root.childNodes
                for (i in 0 until children.length) {
                    val node = children.item(i) as? Element ?: continue
                    val text = node.textContent?.trim().orEmpty()
                    if (text.isNotEmpty()) fields[node.localName ?: node.tagName] = text
                }
                BookMetadata(fields)
            }.getOrDefault(EMPTY)

        /** Reads an EPUB's OPF package document into ComicInfo field names. */
        fun fromOpf(stream: InputStream): BookMetadata =
            runCatching {
                val doc = documentBuilder().parse(stream)
                val fields = mutableMapOf<String, String>()

                fun dc(name: String): List<String> {
                    val nodes = doc.getElementsByTagNameNS("http://purl.org/dc/elements/1.1/", name)
                    return (0 until nodes.length).mapNotNull { nodes.item(it).textContent?.trim()?.ifBlank { null } }
                }

                dc("title").firstOrNull()?.let { fields["Title"] = it }
                dc("creator").takeIf { it.isNotEmpty() }?.let { fields["Writer"] = it.joinToString(", ") }
                dc("description").firstOrNull()?.let { fields["Summary"] = it.replace(Regex("<[^>]+>"), "").trim() }
                dc("subject").takeIf { it.isNotEmpty() }?.let { fields["Genre"] = it.joinToString(", ") }
                dc("language").firstOrNull()?.let { fields["LanguageISO"] = it }
                dc("publisher").firstOrNull()?.let { fields["Publisher"] = it }
                dc("date").firstOrNull()?.take(4)?.toIntOrNull()?.let { fields["Year"] = it.toString() }

                val metas = doc.getElementsByTagName("meta")
                for (i in 0 until metas.length) {
                    val meta = metas.item(i) as Element
                    val name = meta.getAttribute("name")
                    val property = meta.getAttribute("property")
                    val content = meta.getAttribute("content").ifBlank { meta.textContent.orEmpty() }.trim()
                    if (content.isEmpty()) continue
                    when {
                        name == "calibre:series" -> fields["Series"] = content
                        name == "calibre:series_index" -> fields["Number"] = content
                        property == "belongs-to-collection" -> fields.putIfAbsent("Series", content)
                        property == "group-position" -> fields.putIfAbsent("Number", content)
                    }
                }
                BookMetadata(fields)
            }.getOrDefault(EMPTY)
    }
}
