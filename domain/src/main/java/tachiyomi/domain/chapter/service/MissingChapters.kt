package tachiyomi.domain.chapter.service

import tachiyomi.domain.chapter.model.Chapter
import kotlin.math.floor

fun List<Double>.missingChaptersCount(): Int {
    if (this.isEmpty()) {
        return 0
    }

    val chapters = this
        // Ignore unknown chapter numbers
        .filterNot { it == -1.0 }
        // Convert to integers, as we cannot check if 16.5 is missing
        .map(Double::toInt)
        // Only keep unique chapters so that -1 or 16 are not counted multiple times
        .distinct()
        .sorted()

    if (chapters.isEmpty()) {
        return 0
    }

    var missingChaptersCount = 0
    var previousChapter = 0 // The actual chapter number, not the array index

    // We go from 0 to lastChapter - Make sure to use the current index instead of the value
    for (i in chapters.indices) {
        val currentChapter = chapters[i]
        if (currentChapter > previousChapter + 1) {
            // Add the amount of missing chapters
            missingChaptersCount += currentChapter - previousChapter - 1
        }
        previousChapter = currentChapter
    }

    return missingChaptersCount
}

fun calculateChapterGap(higherChapter: Chapter?, lowerChapter: Chapter?): Int {
    if (higherChapter == null || lowerChapter == null) return 0
    if (!higherChapter.isRecognizedNumber || !lowerChapter.isRecognizedNumber) return 0
    return calculateChapterGap(higherChapter.chapterNumber, lowerChapter.chapterNumber)
}

fun calculateChapterGap(higherChapterNumber: Double, lowerChapterNumber: Double): Int {
    if (higherChapterNumber < 0.0 || lowerChapterNumber < 0.0) return 0
    return floor(higherChapterNumber).toInt() - floor(lowerChapterNumber).toInt() - 1
}

/** [count] volumes, or chapters, missing between [previousId] (null at the start) and [chapterId]. */
data class ChapterGap(val previousId: Long?, val chapterId: Long, val count: Int, val volumes: Boolean)

/**
 * The gaps in numbering in [ascending], the chapters as listed but lowest first. Volumes are only counted against
 * volumes and chapters against chapters, so turning a chapter into a volume moves it out of the chapters' gaps and
 * into the volumes'. The first volume also counts the ones missing before it, as does the first chapter when there
 * are no volumes; a series' chapters usually carry on where its volumes end, so they don't start from 1 then.
 */
fun findChapterGaps(ascending: List<Chapter>): List<ChapterGap> {
    val hasVolumes = ascending.any { it.isVolume }
    var lastVolume: Chapter? = null
    var lastChapter: Chapter? = null
    val gaps = mutableListOf<ChapterGap>()
    for (chapter in ascending) {
        val volume = chapter.isVolume
        val previous = if (volume) lastVolume else lastChapter
        val count = when {
            previous != null -> calculateChapterGap(chapter, previous)
            !chapter.isRecognizedNumber -> 0
            volume || !hasVolumes -> floor(chapter.chapterNumber).toInt() - 1
            else -> 0
        }
        if (count > 0) gaps += ChapterGap(previous?.id, chapter.id, count, volume)
        if (chapter.isRecognizedNumber) {
            if (volume) lastVolume = chapter else lastChapter = chapter
        }
    }
    return gaps
}
