package docho.bookorbit

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

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

    private val start = Instant.parse("2026-11-15T10:00:00Z")

    private fun session(seconds: Long, from: Double = 25.0, to: Double = 50.0) =
        BookOrbitSync.readingSession("id", start, start + seconds.seconds, from, to)

    @Test
    fun `sessions shorter than BookOrbit keeps are not sent`() {
        assertNull(session(seconds = 9))
        assertEquals(10, session(seconds = 10)?.durationSeconds)
    }

    @Test
    fun `a session carries its times, length and progress`() {
        val sent = session(seconds = 125)!!
        assertEquals("2026-11-15T10:00:00Z", sent.startedAt)
        assertEquals("2026-11-15T10:02:05Z", sent.endedAt)
        assertEquals(125, sent.durationSeconds)
        assertEquals(50.0, sent.endProgress)
        assertEquals(25.0, sent.progressDelta)
        assertEquals("android", sent.source)
        // Paging back is a negative change.
        assertEquals(-25.0, session(seconds = 60, from = 50.0, to = 25.0)?.progressDelta)
    }

    @Test
    fun `session positions use the reader's 0-based page index`() {
        assertEquals(25.0, BookOrbitSync.percentage(pageIndex = 4, read = false, pageCount = 20))
        assertEquals(100.0, BookOrbitSync.percentage(pageIndex = 4, read = true, pageCount = 20))
        assertEquals(33.33, session(seconds = 60, from = 0.0, to = 100.0 / 3)?.endProgress)
    }

    @Test
    fun `only answers that won't change are dropped`() {
        assertTrue(BookOrbitSync.isRejected(400))
        assertTrue(BookOrbitSync.isRejected(404))
        assertFalse(BookOrbitSync.isRejected(401))
        assertFalse(BookOrbitSync.isRejected(429))
        assertFalse(BookOrbitSync.isRejected(500))
    }
}
