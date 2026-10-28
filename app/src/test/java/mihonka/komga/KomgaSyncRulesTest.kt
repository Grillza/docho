package mihonka.komga

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class KomgaSyncRulesTest {

    private fun queued(page: Int, pages: Int = 20, read: Boolean = false, markedByUser: Boolean = false) =
        KomgaPendingProgress("s", "b", page, pages, read, markedByUser)

    private fun onServer(page: Int?, completed: Boolean = false) = KomgaSync.serverPosition(
        KomgaBookDto(id = "b", readProgress = page?.let { KomgaReadProgressDto(it, completed) }),
    )

    @Test
    fun `only a further page is sent, unless marked by hand`() {
        assertTrue(KomgaSync.shouldSend(queued(page = 10), onServer(4)))
        assertTrue(KomgaSync.shouldSend(queued(page = 1), onServer(null)))
        assertFalse(KomgaSync.shouldSend(queued(page = 10), onServer(10)))
        assertFalse(KomgaSync.shouldSend(queued(page = 10), onServer(20)))
        assertFalse(KomgaSync.shouldSend(queued(page = 10), onServer(20, completed = true)))
        assertTrue(KomgaSync.shouldSend(queued(page = 0, markedByUser = true), onServer(20, completed = true)))
    }

    @Test
    fun `a finished book is further than any page`() {
        assertTrue(KomgaSync.shouldSend(queued(page = 0, pages = 0, read = true), onServer(19)))
        assertFalse(KomgaSync.shouldSend(queued(page = 0, pages = 0, read = true), onServer(20, completed = true)))
    }

    @Test
    fun `a hand mark keeps priority while pages are read after it`() {
        val merged = KomgaSync.mergePending(
            queued(page = 0, markedByUser = true),
            queued(page = 3),
            markedByUser = false,
        )
        assertTrue(merged.markedByUser)
        assertEquals(3, merged.page)
        assertFalse(KomgaSync.mergePending(null, queued(page = 3), markedByUser = false).markedByUser)
    }
}
