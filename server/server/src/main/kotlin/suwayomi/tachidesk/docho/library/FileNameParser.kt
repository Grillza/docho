package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import java.text.Normalizer

/** What a file's name says about it, the way Kavita reads names. */
data class ParsedName(
    val series: String,
    val volume: Float?,
    val chapter: Float?,
    val isSpecial: Boolean,
    val releaseGroup: String?,
    val year: Int?,
)

object FileNameParser {
    private const val NUMBER = """(\d+(?:\.\d+)?)"""

    private val volumePatterns =
        listOf(
            // "v01", "Vol. 3", "Volume 12", "Tome 4"; not "v" ending a word such as "Dev 5"
            Regex("""(?<![\p{L}\d])(?:volume|vol|tome|v)\.?\s*$NUMBER(?:\s*-\s*$NUMBER)?(?![\p{L}])""", RegexOption.IGNORE_CASE),
            Regex("""第?\s*$NUMBER\s*[巻卷권]"""),
        )

    private val chapterPatterns =
        listOf(
            Regex("""(?<![\p{L}\d])(?:chapter|chap|ch|c|episode|ep|#)\.?\s*$NUMBER(?:\s*-\s*$NUMBER)?(?![\p{L}])""", RegexOption.IGNORE_CASE),
            Regex("""第\s*$NUMBER\s*[話话화]"""),
        )

    private val specialPattern =
        Regex(
            """(?<![\p{L}])(?:SP\d+|specials?|omake|extras?|side ?stor(?:y|ies)|art ?book|one[- ]?shot|bonus|ova|annual)(?![\p{L}])""",
            RegexOption.IGNORE_CASE,
        )

    private val specialFolders = setOf("specials", "special", "extras", "extra", "omake", "sp")

    private val bracketed = Regex("""\[[^\]]*]|\([^)]*\)|\{[^}]*}""")
    private val leadingGroup = Regex("""^\s*\[([^\]]+)]""")
    private val parenthesised = Regex("""\(([^)]*)\)""")
    private val year = Regex("""\((\d{4})\)""")
    private val trailingNumber = Regex("""^(.*?)[\s_\-.]+$NUMBER\s*$""")
    private val separators = Regex("""[\s_]+""")

    /** Words in parentheses that describe the release, not who made it. */
    private val releaseWords =
        setOf("digital", "f", "f2", "c2c", "hq", "lq", "color", "colour", "webrip", "web", "scan", "official", "fixed", "omnibus")

    /**
     * @param fileName the name without its extension.
     * @param seriesFolder the series folder's name when the file is in one, used to tell a number
     *   that is part of the title (Kaiju No. 8) from a chapter number.
     * @param parentFolders folders between the series folder and the file, nearest last.
     */
    fun parse(
        fileName: String,
        seriesFolder: String? = null,
        parentFolders: List<String> = emptyList(),
    ): ParsedName {
        val group = releaseGroup(fileName)
        val releaseYear = year.find(fileName)?.groupValues?.get(1)?.toIntOrNull()
        val cleaned = clean(fileName)

        val folderTitle = seriesFolder?.let { clean(it) }
        // Match volume and chapter markers after the title, so numbers in the title stay put.
        val tail =
            if (folderTitle != null && cleaned.startsWith(folderTitle, ignoreCase = true)) {
                cleaned.substring(folderTitle.length)
            } else {
                cleaned
            }

        val volumeMatch = volumePatterns.firstNotNullOfOrNull { it.find(tail) }
        val chapterMatch =
            chapterPatterns.firstNotNullOfOrNull { pattern ->
                pattern.findAll(tail).firstOrNull { match -> volumeMatch == null || match.range.first != volumeMatch.range.first }
            }
        var volume = volumeMatch?.groupValues?.get(1)?.toFloatOrNull()
        var chapter = chapterMatch?.groupValues?.get(1)?.toFloatOrNull()

        // Volume folders: "Series/Volume 3/Chapter 12.cbz"
        if (volume == null) {
            volume =
                parentFolders.asReversed().firstNotNullOfOrNull { folder ->
                    volumePatterns.firstNotNullOfOrNull { it.find(folder) }?.groupValues?.get(1)?.toFloatOrNull()
                }
        }

        val special =
            specialPattern.containsMatchIn(tail) ||
                parentFolders.any { it.trim().lowercase() in specialFolders }

        if (volume == null && chapter == null && !special) {
            // "Series 012" or "Series - 12"
            trailingNumber.find(tail.ifBlank { cleaned })?.let { match ->
                val title = match.groupValues[1]
                if (folderTitle != null || title.isNotBlank()) {
                    chapter = match.groupValues[2].toFloatOrNull()
                }
            }
        }

        val markerStart =
            listOfNotNull(volumeMatch, chapterMatch)
                .minOfOrNull { it.range.first }
                ?.let { it + (cleaned.length - tail.length) }
        val series =
            when {
                folderTitle != null && folderTitle.isNotBlank() -> folderTitle
                markerStart != null -> tidy(cleaned.substring(0, markerStart))
                chapter != null -> tidy(trailingNumber.find(cleaned)?.groupValues?.get(1) ?: cleaned)
                else -> tidy(specialPattern.split(cleaned).first())
            }.ifBlank { tidy(cleaned) }

        return ParsedName(
            series = series,
            volume = volume,
            chapter = chapter,
            isSpecial = special && volume == null && chapter == null,
            releaseGroup = group,
            year = releaseYear,
        )
    }

    /** "[Group] Title v01" → Group; "Title v01 (2020) (Digital) (1r0n)" → 1r0n */
    fun releaseGroup(name: String): String? {
        leadingGroup.find(name)?.let { return it.groupValues[1].trim().ifBlank { null } }
        return parenthesised
            .findAll(name)
            .map { it.groupValues[1].trim() }
            .lastOrNull { it.isNotBlank() && !it.all(Char::isDigit) && it.lowercase() !in releaseWords }
    }

    /** The name without bracketed notes or underscores. */
    fun clean(name: String): String = tidy(bracketed.replace(name, " ").replace(separators, " "))

    /** A title without trailing separators and doubled spaces. */
    fun tidy(name: String): String = name.replace(separators, " ").trim().trim('-', '_', '.', ',', ':', ' ').trim()

    /** How Kavita matches series names: letters and digits only, ignoring case and accents. */
    fun normalize(name: String): String =
        Normalizer
            .normalize(name, Normalizer.Form.NFKD)
            .replace(Regex("""\p{M}+"""), "")
            .lowercase()
            .filter { it.isLetterOrDigit() }
            .ifEmpty { name.lowercase().trim() }

    /** A sort name: without a leading article, as Kavita sorts. */
    fun sortName(name: String): String {
        val trimmed = name.trim()
        val lower = trimmed.lowercase()
        for (article in listOf("the ", "a ", "an ")) {
            if (lower.startsWith(article) && trimmed.length > article.length) return trimmed.substring(article.length)
        }
        return trimmed
    }
}
