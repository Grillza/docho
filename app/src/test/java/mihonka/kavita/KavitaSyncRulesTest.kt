package mihonka.kavita

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class KavitaSyncRulesTest {

    private fun progress(page: Int) =
        KavitaProgressDto(volumeId = 1, chapterId = 5, pageNum = page, seriesId = 1, libraryId = 1)

    private fun queued(page: Int, markedByUser: Boolean = false) = KavitaPendingProgress(progress(page), markedByUser)

    @Test
    fun `a page read offline is sent when it is further than the server`() {
        assertTrue(KavitaSync.shouldSend(queued(page = 10), serverPagesRead = 4))
    }

    @Test
    fun `a page read offline never undoes progress made on another device`() {
        // Phone reached page 10 on the plane; the iPad got to page 20, or finished the 20-page chapter.
        assertFalse(KavitaSync.shouldSend(queued(page = 10), serverPagesRead = 20))
        assertFalse(KavitaSync.shouldSend(queued(page = 10), serverPagesRead = 10))
        // Finishing it on the phone too doesn't need sending again.
        assertFalse(KavitaSync.shouldSend(queued(page = 20), serverPagesRead = 20))
    }

    @Test
    fun `marking a chapter unread by hand goes through`() {
        assertTrue(KavitaSync.shouldSend(queued(page = 0, markedByUser = true), serverPagesRead = 20))
    }

    @Test
    fun `reading on after marking unread keeps the mark's priority until delivered`() {
        val mark = queued(page = 0, markedByUser = true)
        val merged = KavitaSync.mergePending(mark, progress(3), markedByUser = false)
        assertTrue(merged.markedByUser)
        assertTrue(KavitaSync.shouldSend(merged, serverPagesRead = 20))

        assertFalse(KavitaSync.mergePending(null, progress(3), markedByUser = false).markedByUser)
    }
}
