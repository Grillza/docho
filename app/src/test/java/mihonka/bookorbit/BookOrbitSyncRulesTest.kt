package mihonka.bookorbit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BookOrbitSyncRulesTest {

    private fun queued(page: Int, pages: Int = 20, read: Boolean = false, markedByUser: Boolean = false) =
        BookOrbitPendingProgress(1, 2, 3, page, pages, read, markedByUser)

    @Test
    fun `positions use the percentage BookOrbit's comic reader writes`() {
        // Page 5 of 20 is 25%, the same as the web reader reports it.
        assertEquals(25.0, queued(page = 5).percentage)
        assertEquals(100.0, queued(page = 20).percentage)
        assertEquals(0.0, queued(page = 0).percentage)
        // Marked read before the page count was known.
        assertEquals(100.0, queued(page = 0, pages = 0, read = true).percentage)
    }

    @Test
    fun `only a further page is sent, unless marked by hand`() {
        assertTrue(BookOrbitSync.shouldSend(queued(page = 10), serverPercentage = 25.0))
        assertFalse(BookOrbitSync.shouldSend(queued(page = 10), serverPercentage = 50.0))
        assertFalse(BookOrbitSync.shouldSend(queued(page = 10), serverPercentage = 100.0))
        assertTrue(BookOrbitSync.shouldSend(queued(page = 0, markedByUser = true), serverPercentage = 100.0))
    }

    @Test
    fun `a hand mark keeps priority while pages are read after it`() {
        val merged = BookOrbitSync.mergePending(
            queued(page = 0, markedByUser = true),
            queued(page = 3),
            markedByUser = false,
        )
        assertTrue(merged.markedByUser)
        assertEquals(3, merged.page)
    }
}
