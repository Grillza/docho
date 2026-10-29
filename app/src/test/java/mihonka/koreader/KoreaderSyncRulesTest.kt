package mihonka.koreader

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class KoreaderSyncRulesTest {

    private fun queued(page: Int, markedByUser: Boolean = false) =
        KoreaderPendingProgress(document = "abc", mangaId = 1, page = page, pages = 20, markedByUser = markedByUser)

    private fun server(progress: String?, percentage: Double?) =
        KoreaderProgressDto(document = "abc", progress = progress, percentage = percentage)

    @Test
    fun `the server's page is read as KOReader reports it`() {
        assertEquals(7, KoreaderSync.position(server("7", 0.35), pages = 20))
    }

    @Test
    fun `a finished chapter reads as its last page`() {
        assertEquals(20, KoreaderSync.position(server("20", 1.0), pages = 20))
        assertEquals(20, KoreaderSync.position(server(null, 1.0), pages = 20))
    }

    @Test
    fun `a position without a page falls back to the percentage`() {
        assertEquals(10, KoreaderSync.position(server(null, 0.5), pages = 20))
        assertEquals(10, KoreaderSync.position(server("/body/DocFragment[3]", 0.5), pages = 20))
    }

    @Test
    fun `no position on the server means not started`() {
        assertEquals(0, KoreaderSync.position(null, pages = 20))
    }

    @Test
    fun `pages beyond the chapter are clamped`() {
        assertEquals(20, KoreaderSync.position(server("25", 0.9), pages = 20))
    }

    @Test
    fun `only a further page is sent, unless marked by hand`() {
        assertTrue(KoreaderSync.shouldSend(queued(page = 10), serverPosition = 4))
        assertFalse(KoreaderSync.shouldSend(queued(page = 10), serverPosition = 10))
        assertFalse(KoreaderSync.shouldSend(queued(page = 10), serverPosition = 20))
        assertTrue(KoreaderSync.shouldSend(queued(page = 0, markedByUser = true), serverPosition = 20))
    }

    @Test
    fun `a hand mark keeps priority while pages are read after it`() {
        val merged = KoreaderSync.mergePending(
            queued(page = 0, markedByUser = true),
            queued(page = 3),
            markedByUser = false,
        )
        assertTrue(merged.markedByUser)
        assertEquals(3, merged.page)
    }

    @Test
    fun `positions are sent in KOReader's form for paged documents`() {
        val dto = queued(page = 5).toDto("DEVICE")
        assertEquals("5", dto.progress)
        assertEquals(0.25, dto.percentage)
        assertEquals("Doki", dto.device)

        val unread = queued(page = 0).toDto("DEVICE")
        assertEquals("1", unread.progress)
        assertEquals(0.0, unread.percentage)

        assertEquals(1.0, queued(page = 20).toDto("DEVICE").percentage)
    }
}
