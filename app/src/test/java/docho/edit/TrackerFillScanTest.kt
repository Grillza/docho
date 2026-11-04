package docho.edit

import android.content.Context
import eu.kanade.tachiyomi.data.track.Tracker
import eu.kanade.tachiyomi.data.track.model.TrackSearch
import eu.kanade.tachiyomi.source.model.SManga
import io.kotest.matchers.shouldBe
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tachiyomi.core.common.preference.InMemoryPreferenceStore
import tachiyomi.domain.manga.model.Manga
import tachiyomi.domain.manga.repository.MangaRepository
import tachiyomi.domain.track.interactor.GetTracks
import java.io.File

class TrackerFillScanTest {
    @TempDir
    lateinit var files: File

    private val repository = mockk<MangaRepository>()
    private val getTracks = mockk<GetTracks>()
    private val edits = mockk<SeriesEdits>(relaxed = true)
    private val tracker = mockk<Tracker>()
    private val fill = mockk<TrackerFill>()
    private lateinit var memory: TrackerFillMemory
    private lateinit var scan: TrackerFillScan

    private fun manga(id: Long, title: String, author: String? = null, status: Long = 0) = Manga.create().copy(
        id = id,
        source = 1,
        url = "/$id",
        title = title,
        author = author,
        artist = author,
        description = if (author == null) null else "Mine",
        status = status,
    )

    private fun result(id: Long, name: String) = TrackSearch.create(2).apply {
        remote_id = id
        title = name
        tracking_url = ""
    }

    private fun match(title: String, author: String = "Writer One", status: Long = SManga.ONGOING.toLong()) = TrackerFill.Match(
        trackerName = "AniList",
        title = title,
        author = author,
        artist = author,
        description = "About $title",
        publishingStatus = "RELEASING",
        status = status,
    )

    private fun library(vararg series: Manga) {
        coEvery { repository.getFavorites() } returns series.toList()
        series.forEach {
            coEvery { repository.getMangaByUrlAndSourceId(it.url, 1) } returns it
            coEvery { getTracks.await(it.id) } returns emptyList()
        }
    }

    @BeforeEach
    fun setUp() {
        val context = mockk<Context>()
        every { context.filesDir } returns files
        memory = TrackerFillMemory(InMemoryPreferenceStore())
        every { edits.get(any(), any()) } returns null
        every { fill.trackersInScanOrder() } returns listOf(tracker)
        every { tracker.name } returns "AniList"
        every { fill.withoutDetails(tracker, any()) } answers { match(secondArg<TrackSearch>().title) }
        coEvery { fill.withDetails(tracker, any()) } answers { match(secondArg<TrackSearch>().title) }
        scan = TrackerFillScan(context, fill, memory, edits, repository, getTracks)
    }

    @Test
    fun `a scan writes nothing and sorts what it finds`() = runTest {
        library(manga(1, "Ready"), manga(2, "Differs", "Someone Else", 1), manga(3, "Twice"), manga(4, "Nowhere"))
        coEvery { tracker.search("Ready") } returns listOf(result(1, "Ready"))
        coEvery { tracker.search("Differs") } returns listOf(result(2, "Differs"))
        coEvery { tracker.search("Twice") } returns listOf(result(3, "Twice"), result(4, "TWICE"))
        coEvery { tracker.search("Nowhere") } returns listOf(result(5, "Near Nowhere"))

        scan.run(compareAll = true, forgetChoices = false) {}

        scan.items.value!!.associate { it.title to it.problem } shouldBe mapOf(
            "Ready" to FillProblem.READY,
            "Differs" to FillProblem.DIFFERENT,
            "Twice" to FillProblem.SEVERAL_MATCHES,
            "Nowhere" to FillProblem.NO_MATCH,
        )
        scan.items.value!!.last().problem shouldBe FillProblem.READY
        scan.progress.value.done shouldBe 4
        coVerify(exactly = 0) { edits.edit(any(), any()) }
    }

    @Test
    fun `resolving saves an edit, and what was kept doesn't come back`() = runTest {
        library(manga(2, "Differs", "Someone Else", 1))
        coEvery { tracker.search("Differs") } returns listOf(result(2, "Differs"))
        scan.run(compareAll = true, forgetChoices = false) {}

        scan.resolve("1|/2", mapOf(TrackerFillRules.ARTIST to "Writer One"))

        scan.items.value shouldBe emptyList()
        coVerify { edits.edit(any(), SeriesEdits.Details(artist = "Writer One")) }

        // The edit took: the series now has that artist
        coEvery { repository.getFavorites() } returns listOf(manga(2, "Differs", "Someone Else", 1).copy(artist = "Writer One"))

        scan.run(compareAll = true, forgetChoices = false) {}
        scan.items.value shouldBe emptyList()

        scan.run(compareAll = true, forgetChoices = true) {}
        scan.items.value!!.single().changes.first().field shouldBe TrackerFillRules.AUTHOR
    }

    @Test
    fun `a pick then a skip leaves the series out of later scans`() = runTest {
        library(manga(3, "Twice"))
        coEvery { tracker.search("Twice") } returns listOf(result(3, "Twice"), result(4, "TWICE"))
        scan.run(compareAll = true, forgetChoices = false) {}

        scan.pick("1|/3", 1)
        scan.items.value!!.single().picked shouldBe true
        scan.skip("1|/3")

        scan.run(compareAll = true, forgetChoices = false) {}
        scan.items.value shouldBe emptyList()
    }

    @Test
    fun `a decision from another device clears the item`() = runTest {
        library(manga(4, "Nowhere"))
        coEvery { tracker.search("Nowhere") } returns emptyList()
        scan.run(compareAll = true, forgetChoices = false) {}
        scan.items.value!!.size shouldBe 1

        memory.put("1|/4", TrackerFillMemory.Memory(ignored = mapOf(TrackerFillRules.SKIPPED to listOf(TrackerFillRules.KEPT))))
        scan.load()

        scan.items.value shouldBe emptyList()
    }

    @Test
    fun `the list survives a restart`() = runTest {
        library(manga(1, "Ready"))
        coEvery { tracker.search("Ready") } returns listOf(result(1, "Ready"))
        scan.run(compareAll = true, forgetChoices = false) {}

        val context = mockk<Context>()
        every { context.filesDir } returns files
        val restarted = TrackerFillScan(context, fill, memory, edits, repository, getTracks)
        restarted.load()

        restarted.items.value!!.map { it.title } shouldBe listOf("Ready")
    }
}
