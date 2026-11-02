package tachiyomi.domain.chapter.service

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
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

    private fun numbered(name: String, number: Double, kind: String? = null) = Chapter.create().copy(
        name = name,
        chapterNumber = number,
        memo = buildJsonObject { kind?.let { put(Chapter.MEMO_KIND, it) } },
    )

    private val mixed = listOf(
        numbered("Ch. 82", 82.0),
        numbered("Vol. 2", 2.0),
        numbered("Ch. 81", 81.0),
        numbered("Vol. 1", 1.0),
        // Said to be a volume although its name doesn't say so
        numbered("Collected edition 3", 3.0, Chapter.KIND_VOLUME),
    )

    private fun sortByNumber(order: Long, descending: Boolean, readingOrder: Boolean = false): List<String> {
        val manga = Manga.create().copy(chapterFlags = Manga.CHAPTER_SORTING_NUMBER or order)
        return mixed.sortedWith(getChapterSort(manga, descending, readingOrder)).map { it.name }
    }

    @Test
    fun `volumes or chapters come first whichever way the list runs`() {
        assertEquals(
            listOf("Vol. 1", "Vol. 2", "Collected edition 3", "Ch. 81", "Ch. 82"),
            sortByNumber(Manga.CHAPTER_VOLUMES_FIRST, descending = false),
        )
        assertEquals(
            listOf("Collected edition 3", "Vol. 2", "Vol. 1", "Ch. 82", "Ch. 81"),
            sortByNumber(Manga.CHAPTER_VOLUMES_FIRST, descending = true),
        )
        assertEquals(
            listOf("Ch. 82", "Ch. 81", "Collected edition 3", "Vol. 2", "Vol. 1"),
            sortByNumber(Manga.CHAPTER_CHAPTERS_FIRST, descending = true),
        )
    }

    @Test
    fun `reading order puts volumes before chapters`() {
        assertEquals(
            listOf("Vol. 1", "Vol. 2", "Collected edition 3", "Ch. 81", "Ch. 82"),
            sortByNumber(Manga.CHAPTER_CHAPTERS_FIRST, descending = false, readingOrder = true),
        )
    }

    @Test
    fun `volume names are told from chapters in volumes`() {
        assertTrue(Chapter.looksLikeVolume("Vol. 3"))
        assertTrue(Chapter.looksLikeVolume("Volume 12 - The End"))
        assertTrue(Chapter.looksLikeVolume("v03"))
        assertFalse(Chapter.looksLikeVolume("Vol. 3 Ch. 12"))
        assertFalse(Chapter.looksLikeVolume("Chapter 3"))
        assertFalse(Chapter.looksLikeVolume("Valkyrie 3"))
    }
}
