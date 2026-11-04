package docho.library

import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.Test
import tachiyomi.domain.chapter.model.Chapter

class CurrentlyReadingTest {
    private fun chapter(id: Long, read: Boolean) = Chapter.create().copy(id = id, sourceOrder = -id, read = read)

    @Test
    fun `an unfinished last chapter is resumed`() {
        CurrentlyReading.resumeChapter(listOf(chapter(1, true), chapter(2, false), chapter(3, false)), 2)?.id shouldBe 2
    }

    @Test
    fun `a finished last chapter goes on to the next unread one`() {
        CurrentlyReading.resumeChapter(listOf(chapter(1, false), chapter(2, true), chapter(3, false)), 2)?.id shouldBe 3
    }

    @Test
    fun `at the end, an earlier unread chapter is next`() {
        CurrentlyReading.resumeChapter(listOf(chapter(1, false), chapter(2, true)), 2)?.id shouldBe 1
    }

    @Test
    fun `a finished series has nothing to resume`() {
        CurrentlyReading.resumeChapter(listOf(chapter(1, true), chapter(2, true)), 2) shouldBe null
    }
}
