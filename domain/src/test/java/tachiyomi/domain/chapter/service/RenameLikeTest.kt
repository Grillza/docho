package tachiyomi.domain.chapter.service

import io.kotest.matchers.shouldBe
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.parallel.Execution
import org.junit.jupiter.api.parallel.ExecutionMode
import tachiyomi.domain.chapter.model.Chapter

@Execution(ExecutionMode.CONCURRENT)
class RenameLikeTest {

    private fun like(original: String?, renamed: String, title: String, volume: Boolean, vararg names: String) =
        RenameLike.learn(original, renamed, title, volume)!!.let { style ->
            names.map { RenameLike.apply(style, it, title)?.let { r -> "${r.name}|${r.number}" } }
        }

    @Test
    fun `a volume keeps its number and drops the chapter range`() {
        like(
            "Chainsaw v10 ch 10-15",
            "Vol. 10 - Chainsaw",
            "Chainsaw Man",
            true,
            "Chainsaw v11 ch 16-20",
            "Chainsaw v2 ch 3-5",
        ) shouldBe listOf("Vol. 11 - Chainsaw|11.0", "Vol. 2 - Chainsaw|2.0")
    }

    @Test
    fun `a chapter keeps its number`() {
        like("Chainsaw v10 ch 12", "Chapter 12", "Chainsaw Man", false, "Chainsaw v10 ch 13", "Chainsaw v3 ch 14.5")
            .shouldBe(listOf("Chapter 13|13.0", "Chapter 14.5|14.5"))
    }

    @Test
    fun `ranges, padding and titles are kept`() {
        like(
            "Chainsaw Man Ch. 5 - Gun Devil",
            "Ch. 005: Gun Devil",
            "Chainsaw Man",
            false,
            "Chainsaw Man Ch. 6 - Hello",
            "Chainsaw Man Ch. 7",
            "Chainsaw Man ch 8-9 - Two",
        ) shouldBe listOf("Ch. 006: Hello|6.0", "Ch. 007|7.0", "Ch. 008: Two|8.0")
        like("Series v1 c1-4", "Volume 1 (Chapters 1-4)", "Series", true, "Series v2 c5-9")
            .shouldBe(listOf("Volume 2 (Chapters 5-9)|2.0"))
    }

    @Test
    fun `the example's own name works when it wasn't renamed`() {
        like(null, "Vol. 3 - Chainsaw", "Chainsaw Man", true, "Chainsaw v04", "Chainsaw Man 5")
            .shouldBe(listOf("Vol. 4 - Chainsaw|4.0", "Vol. 5 - Chainsaw|5.0"))
        like(null, "Vol. 2 Ch. 010", "X", false, "x v3 c11").shouldBe(listOf("Vol. 3 Ch. 011|11.0"))
    }

    @Test
    fun `numbers in the series title aren't read as chapters`() {
        like("Kaiju No. 8 Vol. 2", "Volume 2", "Kaiju No. 8", true, "Kaiju No. 8 Vol. 3", "Kaiju No. 8 v4")
            .shouldBe(listOf("Volume 3|3.0", "Volume 4|4.0"))
    }

    @Test
    fun `names that don't say the number are left`() {
        like("S ch 12", "Chapter 12", "S", false, "Extra", "Vol. 2").shouldBe(listOf(null, null))
        like("S v1 ch 1", "Vol. 1 Ch. 1", "S", false, "S ch 4").shouldBe(listOf(null))
        RenameLike.learn("Something", "Bonus", "S", false) shouldBe null
    }

    private fun chapter(id: Long, number: Double, volume: Boolean) = Chapter.create().copy(
        id = id,
        chapterNumber = number,
        memo = JsonObject(
            mapOf(Chapter.MEMO_KIND to JsonPrimitive(if (volume) Chapter.KIND_VOLUME else Chapter.KIND_CHAPTER)),
        ),
    )

    @Test
    fun `gaps count volumes and chapters apart`() {
        val chapters = listOf(
            chapter(1, 1.0, true),
            chapter(2, 4.0, true),
            chapter(3, 20.0, false),
            chapter(4, 23.0, false),
            chapter(5, 5.0, true),
        )
        findChapterGaps(chapters) shouldBe listOf(
            ChapterGap(1, 2, 2, true),
            ChapterGap(3, 4, 2, false),
        )
        findChapterGaps(listOf(chapter(1, 3.0, false))) shouldBe listOf(ChapterGap(null, 1, 2, false))
    }
}
