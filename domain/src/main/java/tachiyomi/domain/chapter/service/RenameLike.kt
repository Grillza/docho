package tachiyomi.domain.chapter.service

import java.math.BigDecimal

/**
 * Renames chapters the way the user renamed another one. [learn] reads the style from that example, e.g. "Chainsaw v10
 * ch 10-15" renamed to "Vol. 10 - Chainsaw" gives "Vol. {volume} - Chainsaw", and [apply] fills it in from each
 * chapter's own name, so "Chainsaw v11 ch 16-20" becomes "Vol. 11 - Chainsaw". The style keeps the example's volume
 * number, chapter number (or range, like 10-15) and the title after them where it used them, and its zero padding.
 */
object RenameLike {

    /** A number in a name as written ("03", "10-15"), [value] being its first number, and where it is. */
    data class Number(val text: String, val value: Double, val range: IntRange)

    /** What a name says: its volume, its chapter, a number with no label, and the title after them. */
    data class Parts(val volume: Number?, val chapter: Number?, val bare: Number?, val title: String?)

    sealed interface Piece {
        data class Text(val text: String) : Piece
        data class Volume(val pad: Int) : Piece

        /** [range] is whether the example kept a range like 10-15 whole, rather than its first number. */
        data class Chapter(val pad: Int, val range: Boolean) : Piece
        data object Title : Piece
    }

    /** The pieces a new name is made of, and whether the example was a volume. */
    data class Style(val pieces: List<Piece>, val volume: Boolean) {
        val usesVolume: Boolean get() = pieces.any { it is Piece.Volume }
        val usesChapter: Boolean get() = pieces.any { it is Piece.Chapter }
    }

    data class Renamed(val name: String, val number: Double)

    private const val NUM = """\d+(?:\.\d+)?"""
    private const val RANGE = """$NUM(?:[-–~]$NUM)?"""
    private val VOLUME = Regex("""(?<![\p{L}\d])(?:volume|vol|v)\.?\s*($NUM)""", RegexOption.IGNORE_CASE)
    private val CHAPTER = Regex(
        """(?<![\p{L}\d])(?:chapter|chap|ch|c|episode|ep|#)\.?\s*($RANGE)""",
        RegexOption.IGNORE_CASE,
    )
    private val BARE = Regex("""(?<![\p{L}\d.])($RANGE)(?![\p{L}\d])""")
    private val NUMBER_IN_NAME = Regex("""(?<![\d.])$RANGE(?![\d])""")
    private val VOLUME_LABEL = Regex("""(?<!\p{L})(?:volume|vol|v)\.?\s*$""", RegexOption.IGNORE_CASE)
    private val CHAPTER_LABEL = Regex(
        """(?<!\p{L})(?:chapter|chap|ch|c|episode|ep|#)\.?\s*$""",
        RegexOption.IGNORE_CASE,
    )
    private val RANGE_SEPARATOR = Regex("""[-–~]""")

    /** Tags like "(2024)" or "[Digital]" after the numbers, which aren't part of a title. */
    private val TAGS = Regex("""\s*(?:\([^)]*\)|\[[^\]]*])""")
    private const val SEPARATORS = " \t-–—:·|_,;"

    fun parse(name: String, mangaTitle: String): Parts {
        val masked = titleRanges(name, mangaTitle)
        fun free(range: IntRange) = masked.none { it.overlaps(range) }

        val volumeMatch = VOLUME.findAll(name).firstOrNull { free(it.range) }
        val chapterMatch = CHAPTER.findAll(name).firstOrNull {
            free(it.range) && volumeMatch?.range?.overlaps(it.range) != true
        }
        val bareMatch = BARE.findAll(name).firstOrNull { match ->
            free(match.range) && listOfNotNull(volumeMatch, chapterMatch).none { it.range.overlaps(match.range) }
        }
        val volume = volumeMatch?.number()
        val chapter = chapterMatch?.number()
        val bare = bareMatch?.number()
        val end = listOfNotNull(volumeMatch, chapterMatch, bareMatch).maxOfOrNull { it.range.last + 1 }
        val title = end?.let { name.substring(it).replace(TAGS, "").trim { c -> c in SEPARATORS || c.isWhitespace() } }
            ?.trimEnd(')', ']')
            ?.trim { c -> c in SEPARATORS || c.isWhitespace() }
            ?.takeIf { it.isNotEmpty() && !it.equals(mangaTitle, ignoreCase = true) }
        return Parts(volume, chapter, bare, title)
    }

    /**
     * The style of [renamed], which the user renamed from [original] (or named so themselves, if that's null), as a
     * volume if [volume]. Null when it uses neither the volume nor the chapter number, so every chapter would get the
     * same name.
     */
    fun learn(original: String?, renamed: String, mangaTitle: String, volume: Boolean): Style? {
        val from = original?.takeIf { it != renamed }?.let { parse(it, mangaTitle) }
        val fromVolume = from?.volume ?: from?.bare?.takeIf { volume && from.chapter == null }
        val fromChapter = from?.chapter ?: from?.bare?.takeIf { it !== fromVolume }
        val masked = titleRanges(renamed, mangaTitle)
        val titleRange = from?.title?.takeIf { it.length >= 2 }?.let { title ->
            renamed.indexOf(title, ignoreCase = true).takeIf { it >= 0 }?.let { it until it + title.length }
        }

        val slots = mutableListOf<Pair<IntRange, Piece>>()
        titleRange?.let { slots += it to Piece.Title }
        var usedVolume = false
        var usedChapter = false
        for (match in NUMBER_IN_NAME.findAll(renamed)) {
            val range = match.range
            if (masked.any { it.overlaps(range) } || titleRange?.overlaps(range) == true) continue
            val parts = match.value.split(RANGE_SEPARATOR)
            val value = parts.first().toDoubleOrNull() ?: continue
            val isRange = parts.size > 1
            val before = renamed.substring(0, range.first)
            val label = when {
                VOLUME_LABEL.containsMatchIn(before) -> true
                CHAPTER_LABEL.containsMatchIn(before) -> false
                else -> null
            }
            val asVolume: Boolean? = if (from != null) {
                val isVolume = !isRange && fromVolume?.value == value
                val isChapter = fromChapter?.value == value
                when {
                    isVolume && isChapter -> label ?: (volume && !usedVolume)
                    isVolume -> true
                    isChapter -> false
                    else -> null
                }
            } else {
                label ?: when {
                    volume && !usedVolume -> true
                    !volume && !usedChapter -> false
                    else -> null
                }
            }
            val piece = when (asVolume) {
                true -> Piece.Volume(padOf(parts.first())).also { usedVolume = true }
                false -> Piece.Chapter(padOf(parts.first()), isRange).also { usedChapter = true }
                null -> continue
            }
            slots += range to piece
        }
        if (!usedVolume && !usedChapter) return null

        val pieces = mutableListOf<Piece>()
        var position = 0
        for ((range, piece) in slots.sortedBy { it.first.first }) {
            if (range.first < position) continue
            if (range.first > position) pieces += Piece.Text(renamed.substring(position, range.first))
            pieces += piece
            position = range.last + 1
        }
        if (position < renamed.length) pieces += Piece.Text(renamed.substring(position))
        return Style(pieces, volume)
    }

    /** [name] in [style], or null when it doesn't say the volume or chapter number the style needs. */
    fun apply(style: Style, name: String, mangaTitle: String): Renamed? {
        val parts = parse(name, mangaTitle)
        val volume = parts.volume ?: parts.bare?.takeIf { style.volume && parts.chapter == null }
        val chapter = parts.chapter ?: parts.bare?.takeIf { it !== volume }
        if (style.usesVolume && volume == null) return null
        if (style.usesChapter && chapter == null) return null

        val result = StringBuilder()
        var trimNext = false
        for (piece in style.pieces) {
            when (piece) {
                is Piece.Text -> result.append(if (trimNext) piece.text.trimStart { it in SEPARATORS } else piece.text)
                is Piece.Volume -> result.append(format(volume!!.text.split(RANGE_SEPARATOR).first(), piece.pad))
                is Piece.Chapter -> {
                    val numbers = chapter!!.text.split(RANGE_SEPARATOR)
                    val separator = RANGE_SEPARATOR.find(chapter.text)?.value ?: "-"
                    val shown = if (piece.range) numbers else numbers.take(1)
                    result.append(shown.joinToString(separator) { format(it, piece.pad) })
                }
                Piece.Title -> if (parts.title != null) {
                    result.append(parts.title)
                } else {
                    // No title: drop the separator that led up to it, and the one after if it began the name
                    val trimmed = result.trimEnd { it in SEPARATORS }
                    result.setLength(trimmed.length)
                    trimNext = result.isEmpty()
                    continue
                }
            }
            trimNext = false
        }
        val newName = result.toString().replace(Regex("""\s{2,}"""), " ").trim { it in SEPARATORS }
        if (newName.isEmpty()) return null
        val number = when {
            style.volume && volume != null -> volume.value
            chapter != null -> chapter.value
            volume != null -> volume.value
            else -> ChapterRecognition.parseChapterNumber(mangaTitle, newName)
        }
        return Renamed(newName, number)
    }

    /**
     * [name] as a volume ("Vol. 10", or "Vol. 10 - Title" when the name has a title after its numbers) or a chapter
     * ("Ch. 74-81 - Title"), from the volume or chapter number in it, else [fallbackNumber]. Null when there's no
     * number to use.
     */
    fun asKind(name: String, mangaTitle: String, volume: Boolean, fallbackNumber: Double): Renamed? {
        val parts = parse(name, mangaTitle)
        val found = if (volume) {
            parts.volume ?: parts.bare?.takeIf { parts.chapter == null }
        } else {
            parts.chapter ?: parts.bare
        }
        val written = found?.text?.split(RANGE_SEPARATOR)?.let { numbers ->
            val separator = RANGE_SEPARATOR.find(found.text)?.value ?: "-"
            (if (volume) numbers.take(1) else numbers).joinToString(separator) { format(it, 0) }
        } ?: fallbackNumber.takeIf { it >= 0 }?.let { BigDecimal.valueOf(it).stripTrailingZeros().toPlainString() }
            ?: return null
        val value = found?.value ?: fallbackNumber
        val label = if (volume) "Vol." else "Ch."
        val title = parts.title?.takeIf { found != null }
        return Renamed(if (title != null) "$label $written - $title" else "$label $written", value)
    }

    private fun MatchResult.number(): Number {
        val group = groups[1]!!
        val value = group.value.split(RANGE_SEPARATOR).first().toDouble()
        return Number(group.value, value, group.range)
    }

    /** Where [title] appears in [name], so a number in a series title like "Kaiju No. 8" isn't read as a chapter. */
    private fun titleRanges(name: String, title: String): List<IntRange> {
        if (title.isBlank() || !title.any { it.isDigit() }) return emptyList()
        return generateSequence(name.indexOf(title, ignoreCase = true).takeIf { it >= 0 }) { start ->
            name.indexOf(title, start + title.length, ignoreCase = true).takeIf { it >= 0 }
        }.map { it until it + title.length }.toList()
    }

    private fun padOf(number: String): Int {
        val digits = number.substringBefore('.')
        return if (digits.length > 1 && digits.startsWith('0')) digits.length else 0
    }

    private fun format(number: String, pad: Int): String {
        val whole = number.substringBefore('.').trimStart('0').ifEmpty { "0" }
        val fraction = number.substringAfter('.', "")
        return whole.padStart(pad, '0') + if (fraction.isNotEmpty()) ".$fraction" else ""
    }

    private fun IntRange.overlaps(other: IntRange) = first <= other.last && other.first <= last
}
