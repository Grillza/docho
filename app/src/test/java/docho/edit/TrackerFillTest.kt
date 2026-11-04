package docho.edit

import eu.kanade.tachiyomi.source.model.SManga
import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.Test

class TrackerFillTest {

    private val match = TrackerFill.Match(
        trackerName = "AniList",
        title = "T",
        author = "Writer",
        artist = "Artist",
        description = "About it",
        publishingStatus = "RELEASING",
        status = SManga.ONGOING.toLong(),
    )
    private val empty = TrackerFill.Form("", "", "", SManga.UNKNOWN.toLong())

    @Test
    fun `each tracker's wording becomes a status`() {
        mapOf(
            "RELEASING" to SManga.ONGOING, // AniList
            "currently publishing" to SManga.ONGOING, // MyAnimeList
            "Currently_Publishing" to SManga.ONGOING,
            "Current" to SManga.ONGOING, // Kitsu
            "FINISHED" to SManga.COMPLETED,
            "Released" to SManga.COMPLETED, // Shikimori
            "Complete" to SManga.COMPLETED, // MangaUpdates
            "Discontinued" to SManga.CANCELLED,
            "Paused" to SManga.ON_HIATUS,
            "on hiatus" to SManga.ON_HIATUS,
            "NOT_YET_RELEASED" to SManga.UNKNOWN,
            "TBA" to SManga.UNKNOWN,
            "" to SManga.UNKNOWN,
        ).forEach { (publishing, status) -> TrackerFill.status(publishing) shouldBe status.toLong() }
    }

    @Test
    fun `empty fields are filled`() {
        TrackerFill.fill(empty, match, statusEdited = false) shouldBe
            TrackerFill.Form("Writer", "Artist", "About it", SManga.ONGOING.toLong())
    }

    @Test
    fun `what's already there stays`() {
        val form = TrackerFill.Form("Mine", "Also mine", "My words", SManga.COMPLETED.toLong())
        TrackerFill.fill(form, match, statusEdited = false) shouldBe form
    }

    @Test
    fun `a source's Unknown counts as an empty name`() {
        TrackerFill.fill(empty.copy(author = "Unknown", artist = "unknown "), match, statusEdited = false).let {
            it.author shouldBe "Writer"
            it.artist shouldBe "Artist"
        }
    }

    @Test
    fun `an edited status can be brought up to date`() {
        val form = empty.copy(status = SManga.COMPLETED.toLong())
        TrackerFill.fill(form, match, statusEdited = true).status shouldBe SManga.ONGOING.toLong()
    }

    @Test
    fun `a tracker with nothing to say changes nothing`() {
        val blank = match.copy(author = "", artist = "", description = "", status = SManga.UNKNOWN.toLong())
        val form = empty.copy(author = "Unknown", status = SManga.COMPLETED.toLong())
        TrackerFill.fill(form, blank, statusEdited = true) shouldBe form
    }

    @Test
    fun `a second tracker fills only what the first didn't`() {
        val first = TrackerFill.fill(empty, match.copy(artist = "", status = SManga.UNKNOWN.toLong()), statusEdited = false)
        val second = match.copy(author = "Other", artist = "Second", status = SManga.COMPLETED.toLong())
        TrackerFill.fill(first, second, statusEdited = false) shouldBe
            TrackerFill.Form("Writer", "Second", "About it", SManga.COMPLETED.toLong())
    }
}

class TrackerFillRulesTest {
    private val match = TrackerFill.Match(
        trackerName = "AniList",
        title = "T",
        author = "Writer One",
        artist = "Artist One",
        description = "About it",
        publishingStatus = "RELEASING",
        status = 1,
    )
    private val full = FillCurrent("Writer One", "Artist One", "Mine", 1)
    private val empty = FillCurrent("", "", "", 0)

    @Test
    fun `names compare whatever their order, as on the server and iOS`() {
        TrackerFillRules.namesKey("MIURA Kentaro, MORI Kouji") shouldBe "kentaro miura,kouji mori"
        TrackerFillRules.namesKey("Kouji Mori, Kentaro Miura") shouldBe "kentaro miura,kouji mori"
    }

    @Test
    fun `empty fields need no decision`() {
        TrackerFillRules.problemOf(TrackerFillRules.review(empty, listOf(match), null)) shouldBe FillProblem.READY
    }

    @Test
    fun `a differing name is a conflict`() {
        val change = TrackerFillRules.review(full.copy(author = "Someone Else"), listOf(match), null).single()
        change.field shouldBe TrackerFillRules.AUTHOR
        change.conflict shouldBe true
    }

    @Test
    fun `a status the last fill gave is only out of date, one the user changed is a conflict`() {
        TrackerFillRules.review(full.copy(status = 2), listOf(match), 2).single().conflict shouldBe false
        TrackerFillRules.review(full.copy(status = 6), listOf(match), 2).single().conflict shouldBe true
    }

    @Test
    fun `summaries are never compared, and one kept empty stays so`() {
        TrackerFillRules.review(full, listOf(match.copy(description = "Other")), null) shouldBe emptyList()
        val kept = mapOf(TrackerFillRules.DESCRIPTION to listOf(TrackerFillRules.KEPT))
        TrackerFillRules.review(full.copy(description = ""), listOf(match), null, kept) shouldBe emptyList()
    }

    @Test
    fun `what was decided against isn't asked again, until a tracker says something new`() {
        val ignored = mapOf(TrackerFillRules.STATUS to listOf("1"))
        TrackerFillRules.review(full.copy(status = 6), listOf(match), null, ignored) shouldBe emptyList()
        TrackerFillRules.review(full.copy(status = 6), listOf(match.copy(status = 2)), null, ignored).size shouldBe 1
    }

    @Test
    fun `an item drops what another device settled`() {
        val changes = TrackerFillRules.review(full.copy(author = "Someone Else", status = 6), listOf(match), null)
        val item = FillItem(1, "u", "T", FillProblem.DIFFERENT, changes)
        TrackerFillRules.prune(item, full.copy(status = 6), null, emptyMap())!!.changes.map { it.field } shouldBe
            listOf(TrackerFillRules.STATUS)
        TrackerFillRules.prune(item, full, null, emptyMap()) shouldBe null
    }

    @Test
    fun `a series skipped elsewhere is gone`() {
        val item = FillItem(1, "u", "T", FillProblem.NO_MATCH)
        TrackerFillRules.prune(item, empty, null, emptyMap()) shouldBe item
        TrackerFillRules.prune(item, empty, null, mapOf(TrackerFillRules.SKIPPED to listOf("kept"))) shouldBe null
    }

    @Test
    fun `a fill record reads back the same`() {
        val memory = TrackerFillMemory.Memory(status = 2, ignored = mapOf("author" to listOf("b", "a")))
        val json = TrackerFillMemory.toJson(memory)
        docho.dochosync.SyncValues.canonical(json) shouldBe """{"ignored":{"author":["a","b"]},"status":2}"""
        TrackerFillMemory.fromJson(json) shouldBe memory.copy(ignored = mapOf("author" to listOf("a", "b")))
    }
}
