package docho.kavita

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tachiyomi.domain.chapter.service.calculateChapterGap

class KavitaChapterNumbersTest {

    private val volumes = listOf(1f, 1.5f, 2f, 3f, 120f).map(KavitaSource::volumeChapterNumber)
    private val specials = (0..2).map(KavitaSource::specialChapterNumber)

    @Test
    fun `volumes and specials are never recognized chapter numbers`() {
        // Mihon treats negative numbers as unrecognized, apart from -1 and -2 which it parses or reserves.
        (volumes + specials).forEach { assertTrue(it < -2f, "$it") }
    }

    @Test
    fun `every volume and special gets its own number, in Kavita's order`() {
        assertEquals(volumes.sorted(), volumes)
        assertEquals(specials.sorted(), specials)
        assertEquals(volumes.size + specials.size, (volumes + specials).toSet().size)
        assertTrue(specials.max() < volumes.min())
    }

    @Test
    fun `a volume next to a loose chapter reports no missing chapters`() {
        assertEquals(0, calculateChapterGap(20.0, volumes.last().toDouble()))
    }
}
