package mihonka.bookorbit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BookOrbitSourceTest {

    @Test
    fun `ids come back out of the urls`() {
        val url = BookOrbitSource.chapterUrl(bookId = 12, fileId = 340)
        assertEquals(12, BookOrbitSource.bookId(url))
        assertEquals(340, BookOrbitSource.fileId(url))
        assertEquals(7, BookOrbitSource.seriesId(BookOrbitSource.seriesUrl(7)))
        assertNull(BookOrbitSource.fileIdOrNull("/chapter/5"))
    }

    @Test
    fun `server addresses are normalised to the api`() {
        assertEquals("http://bookorbit.lan:3010/api/v1", BookOrbitApi.normalizeApiUrl("bookorbit.lan:3010/"))
        assertEquals(
            "https://books.example.com/api/v1",
            BookOrbitApi.normalizeApiUrl("https://books.example.com/api/v1/koreader"),
        )
        assertNull(BookOrbitApi.normalizeApiUrl("  "))
    }

    @Test
    fun `chapters are named from the volume and title`() {
        assertEquals("Vol. 3 - The Return", BookOrbitSource.chapterName("The Return", "3"))
        assertEquals("Vol. 3", BookOrbitSource.chapterName(" ", "3"))
        assertEquals("One-shot", BookOrbitSource.chapterName("One-shot", null))
    }

    @Test
    fun `only comic archives can be read`() {
        val book = BookOrbitBookDto(id = 1, files = listOf(BookOrbitFileDto(1, "epub"), BookOrbitFileDto(2, "CBZ")))
        assertEquals(2, book.comicFile?.id)
        assertNull(BookOrbitBookDto(id = 1, files = listOf(BookOrbitFileDto(1, "epub"))).comicFile)
    }

    @Test
    fun `a book reads as read from its status or a full percentage`() {
        assertTrue(BookOrbitBookDto(id = 1, readStatus = BookOrbitReadStatusDto("read")).isRead)
        assertTrue(BookOrbitBookDto(id = 1, readingProgress = 100.0).isRead)
        assertFalse(BookOrbitBookDto(id = 1, readingProgress = 99.0).isRead)
    }
}
