package tachiyomi.domain.chapter.service

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.manga.model.Manga

class ChapterSortTest {

    private fun chapter(fileName: String?, name: String = "Vol. 1") = Chapter.create().copy(
        name = name,
        memo = buildJsonObject { fileName?.let { put(Chapter.MEMO_FILE_NAME, it) } },
    )

    private fun sortByFileName(chapters: List<Chapter>, descending: Boolean): List<String> {
        val manga = Manga.create().copy(chapterFlags = Manga.CHAPTER_SORTING_FILE_NAME)
        return chapters.sortedWith(getChapterSort(manga, descending)).map { it.fileName }
    }

    @Test
    fun `file name sort keeps parts together when volume numbers restart`() {
        val ordered = listOf(
            "JoJo's Bizarre Adventure - P01 - Phantom Blood - v01.cbz",
            "JoJo's Bizarre Adventure - P01 - Phantom Blood - v02.cbz",
            "JoJo's Bizarre Adventure - P03 - Stardust Crusaders - v01.cbz",
            "JoJo's Bizarre Adventure - P08 - JoJolion - v02.cbz",
            "JoJo's Bizarre Adventure - P08 - JoJolion - v10.cbz",
            "The_JOJOLands_036_[HWMN].cbz",
            "The_JOJOLands_040_[HWMN].cbz",
        )
        val chapters = ordered.shuffled(kotlin.random.Random(1)).map { chapter(it) }

        assertEquals(ordered, sortByFileName(chapters, descending = false))
        assertEquals(ordered.reversed(), sortByFileName(chapters, descending = true))
    }

    @Test
    fun `numbers in file names sort by value`() {
        val chapters = listOf("Vol 10.cbz", "Vol 2.cbz", "Vol 1.cbz").map { chapter(it) }

        assertEquals(listOf("Vol 1.cbz", "Vol 2.cbz", "Vol 10.cbz"), sortByFileName(chapters, descending = false))
    }

    @Test
    fun `chapters without a file name fall back to their name`() {
        val chapters = listOf(chapter(null, name = "B"), chapter("A.cbz"), chapter(null, name = "C"))

        assertEquals(listOf("A.cbz", "B", "C"), sortByFileName(chapters, descending = false))
    }
}
