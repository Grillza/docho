package doki.kavita

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class KavitaUrlsTest {

    @Test
    fun `normalizes the server addresses people paste`() {
        assertEquals("https://kavita.example.com/api", KavitaApi.normalizeApiUrl("https://kavita.example.com"))
        assertEquals("https://kavita.example.com/api", KavitaApi.normalizeApiUrl(" https://kavita.example.com/ "))
        assertEquals("http://192.168.1.10:5000/api", KavitaApi.normalizeApiUrl("192.168.1.10:5000"))
        assertEquals("https://example.com/kavita/api", KavitaApi.normalizeApiUrl("https://example.com/kavita/"))
        assertEquals(
            "https://kavita.example.com/api",
            KavitaApi.normalizeApiUrl("https://kavita.example.com/api/opds/0f8c3b1e-aaaa-bbbb"),
        )
        assertNull(KavitaApi.normalizeApiUrl("   "))
    }

    @Test
    fun `reads ids back from manga and chapter urls`() {
        val mangaUrl = KavitaSource.seriesUrl(libraryId = 3, seriesId = 42)
        assertEquals("/library/3/series/42", mangaUrl)
        assertEquals(42, KavitaSource.seriesId(mangaUrl))
        assertEquals(3, KavitaSource.libraryId(mangaUrl))

        val chapterUrl = KavitaSource.chapterUrl(1234)
        assertEquals(1234, KavitaSource.chapterId(chapterUrl))
        assertEquals(1234, KavitaSource.chapterIdOrNull(chapterUrl))
        assertNull(KavitaSource.chapterIdOrNull("/some/other/url"))
    }
}
