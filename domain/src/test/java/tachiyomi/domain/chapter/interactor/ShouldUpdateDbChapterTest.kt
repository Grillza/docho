package tachiyomi.domain.chapter.interactor

import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.Test
import tachiyomi.domain.chapter.model.Chapter

class ShouldUpdateDbChapterTest {

    private val check = ShouldUpdateDbChapter()
    private val chapter = Chapter.create().copy(url = "/c/1", name = "Vol. 8")

    @Test
    fun `a scanlator the source stopped sending is a change`() {
        check.await(chapter.copy(scanlator = "1r0n"), chapter.copy(scanlator = null)) shouldBe true
    }

    @Test
    fun `a cleared (blank) scanlator is the same as none`() {
        check.await(chapter.copy(scanlator = ""), chapter.copy(scanlator = null)) shouldBe false
        check.await(chapter.copy(scanlator = null), chapter.copy(scanlator = "")) shouldBe false
    }
}
