package doki.komga

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class KomgaSourceTest {

    @Test
    fun `ids come back out of the urls`() {
        assertEquals("0A1B2C", KomgaSource.bookId(KomgaSource.chapterUrl("0A1B2C")))
        assertEquals("09XY", KomgaSource.seriesId(KomgaSource.seriesUrl("09XY")))
        assertNull(KomgaSource.bookIdOrNull("/chapter/5"))
    }

    @Test
    fun `server addresses are normalised to the api`() {
        assertEquals("http://komga.lan:25600/api", KomgaApi.normalizeApiUrl("komga.lan:25600/"))
        assertEquals(
            "https://example.com/komga/api",
            KomgaApi.normalizeApiUrl("https://example.com/komga/api/v1/series"),
        )
        assertNull(KomgaApi.normalizeApiUrl("  "))
    }

    @Test
    fun `chapter names put the number first unless the title is only the number`() {
        assertEquals("#3 - Stardust Crusaders", KomgaSource.chapterName("Stardust Crusaders", "3"))
        assertEquals("#3", KomgaSource.chapterName("3", "3"))
        assertEquals("Oneshot", KomgaSource.chapterName("Oneshot", ""))
        assertEquals("Untitled", KomgaSource.chapterName("", ""))
    }

    @Test
    fun `only books Komga serves as page images are chapters`() {
        fun book(profile: String, status: String = "READY", pages: Int = 10, divina: Boolean = false) =
            KomgaBookDto(id = "b", media = KomgaMediaDto(status, pages, profile, divina))
        assertTrue(book("DIVINA").hasPages)
        assertTrue(book("PDF").hasPages)
        assertFalse(book("EPUB").hasPages)
        assertTrue(book("EPUB", divina = true).hasPages)
        assertFalse(book("DIVINA", status = "UNKNOWN").hasPages)
        assertFalse(book("DIVINA", pages = 0).hasPages)
    }

    @Test
    fun `file names drop the folder`() {
        val book = KomgaBookDto(id = "b", name = "v01", url = "/data/manga/JoJo/JoJo - P01 - v01.cbz")
        assertEquals("JoJo - P01 - v01.cbz", book.fileName)
        assertEquals("v01", KomgaBookDto(id = "b", name = "v01").fileName)
    }

    @Test
    fun `searches leave out deleted series and can ask for unread ones`() {
        val search = KomgaApi.seriesSearch(query = " jojo ", libraryId = "L1", unreadOnly = true)
        assertEquals("jojo", search["fullTextSearch"]!!.jsonPrimitive.content)
        val conditions = search["condition"]!!.jsonObject["allOf"]!!.jsonArray.map { it.jsonObject }
        assertEquals("isFalse", conditions[0]["deleted"]!!.jsonObject["operator"]!!.jsonPrimitive.content)
        assertEquals("L1", conditions[1]["libraryId"]!!.jsonObject["value"]!!.jsonPrimitive.content)
        val readStatuses = (conditions[2]["anyOf"] as JsonArray)
            .map { (it as JsonObject)["readStatus"]!!.jsonObject["value"]!!.jsonPrimitive.content }
        assertEquals(listOf("UNREAD", "IN_PROGRESS"), readStatuses)

        val plain = KomgaApi.seriesSearch(query = null, libraryId = null, unreadOnly = false)
        assertNull(plain["fullTextSearch"])
        assertEquals(1, plain["condition"]!!.jsonObject["allOf"]!!.jsonArray.size)
    }
}
