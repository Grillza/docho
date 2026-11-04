package suwayomi.tachidesk.docho

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.junit.jupiter.api.Test
import suwayomi.tachidesk.docho.library.SeriesMetadata.Field
import suwayomi.tachidesk.docho.library.TrackerFill
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TrackerFillTest {
    private val match =
        TrackerFill.TrackerMatch(
            trackerId = 2,
            remoteId = 1,
            trackerName = "AniList",
            title = "T",
            writers = listOf("Writer One"),
            artists = listOf("Artist One"),
            summary = "About it",
            publishingStatus = "RELEASING",
            status = 1,
            linked = false,
        )
    private val other = match.copy(trackerId = 1, trackerName = "MyAnimeList")
    private val empty = TrackerFill.Current("", "", "", 0)
    private val full = TrackerFill.Current("Writer One", "Artist One", "Mine", 1)

    private fun List<TrackerFill.TrackerFillChange>.of(field: Field) = first { it.field == field }

    @Test
    fun `each tracker's wording becomes a status`() {
        mapOf(
            "RELEASING" to 1,
            "currently publishing" to 1,
            "Publishing" to 1,
            "FINISHED" to 2,
            "released" to 2,
            "Complete" to 2,
            "discontinued" to 5,
            "paused" to 6,
            "NOT_YET_RELEASED" to 0,
            "" to 0,
        ).forEach { (publishing, status) -> assertEquals(status, TrackerFill.status(publishing), publishing) }
    }

    @Test
    fun `names compare whatever their order and case`() {
        assertEquals(TrackerFill.namesKey("MIURA Kentaro"), TrackerFill.namesKey("Kentaro Miura"))
        assertEquals(TrackerFill.namesKey("A One, B Two"), TrackerFill.namesKey("two b, one a"))
        assertFalse(TrackerFill.namesKey("Kentaro Miura") == TrackerFill.namesKey("Kentaro Miura, Kouji Mori"))
    }

    @Test
    fun `empty fields are ready to fill with no decision to make`() {
        val changes = TrackerFill.review(empty, listOf(match), null)
        assertEquals(listOf(Field.WRITERS, Field.ARTISTS, Field.SUMMARY, Field.STATUS), changes.map { it.field })
        assertTrue(changes.none { it.conflict })
    }

    @Test
    fun `a source's Unknown counts as an empty name`() {
        val changes = TrackerFill.review(empty.copy(writers = "Unknown"), listOf(match), null)
        assertFalse(changes.of(Field.WRITERS).conflict)
    }

    @Test
    fun `nothing to say about a series that agrees`() {
        assertTrue(TrackerFill.review(full, listOf(match.copy(writers = listOf("ONE Writer"))), null).isEmpty())
    }

    @Test
    fun `a name that differs is a conflict`() {
        val changes = TrackerFill.review(full.copy(writers = "Someone Else"), listOf(match), null)
        val change = changes.single()
        assertEquals(Field.WRITERS, change.field)
        assertTrue(change.conflict)
        assertEquals("Someone Else", change.current)
        assertEquals("Writer One", change.options.single().value)
    }

    @Test
    fun `trackers that disagree on an empty field are a conflict`() {
        val change = TrackerFill.review(empty, listOf(match, other.copy(writers = listOf("Somebody"))), null).of(Field.WRITERS)
        assertTrue(change.conflict)
        assertEquals(listOf("AniList", "MyAnimeList"), change.options.map { it.trackerName })
    }

    @Test
    fun `trackers that agree are one option`() {
        val change = TrackerFill.review(empty, listOf(match, other), null).of(Field.STATUS)
        assertFalse(change.conflict)
        assertEquals(1, change.options.size)
    }

    @Test
    fun `summaries are never compared`() {
        assertTrue(TrackerFill.review(full, listOf(match.copy(summary = "Worded differently")), null).isEmpty())
    }

    @Test
    fun `a status differing from the user's is a conflict`() {
        assertTrue(TrackerFill.review(full.copy(status = 6), listOf(match), null).single().conflict)
    }

    @Test
    fun `a status the last fill gave is only out of date`() {
        assertFalse(TrackerFill.review(full.copy(status = 2), listOf(match), filledStatus = 2).single().conflict)
    }

    @Test
    fun `a status the user changed since the last fill is a conflict`() {
        assertTrue(TrackerFill.review(full.copy(status = 6), listOf(match), filledStatus = 2).single().conflict)
    }

    @Test
    fun `statuses a tracker can't tell apart aren't a conflict`() {
        val completed = match.copy(status = 2)
        assertTrue(TrackerFill.review(full.copy(status = 4), listOf(completed), null).isEmpty())
        assertTrue(TrackerFill.review(full.copy(status = 3), listOf(completed), null).isEmpty())
    }

    @Test
    fun `what was decided against isn't asked about again`() {
        val ignored =
            mapOf(
                Field.WRITERS.key to listOf(TrackerFill.namesKey("Writer One")),
                Field.STATUS.key to listOf("1"),
            )
        val current = full.copy(writers = "Someone Else", status = 6)
        assertTrue(TrackerFill.review(current, listOf(match), null, ignored).isEmpty())
    }

    @Test
    fun `a summary kept empty isn't offered again`() {
        val current = full.copy(summary = "")
        assertEquals(Field.SUMMARY, TrackerFill.review(current, listOf(match), null).single().field)
        assertTrue(TrackerFill.review(current, listOf(match), null, mapOf(Field.SUMMARY.key to listOf("kept"))).isEmpty())
    }

    private val item
        get() =
            TrackerFill.TrackerFillItem(
                1,
                "T",
                TrackerFill.TrackerFillProblem.DIFFERENT,
                TrackerFill.review(full.copy(writers = "Someone Else", status = 6), listOf(match), null),
            )

    @Test
    fun `an item drops what another device settled`() {
        val current = full.copy(writers = "Writer One", status = 6)
        val left = TrackerFill.prune(item, current, null, emptyMap())!!
        assertEquals(listOf(Field.STATUS), left.changes.map { it.field })
    }

    @Test
    fun `an item with everything settled is gone`() {
        assertEquals(null, TrackerFill.prune(item, full, null, emptyMap()))
    }

    @Test
    fun `an item drops what was decided against elsewhere`() {
        val ignored = mapOf(Field.WRITERS.key to listOf(TrackerFill.namesKey("Writer One")), Field.STATUS.key to listOf("1"))
        assertEquals(null, TrackerFill.prune(item, full.copy(writers = "Someone Else", status = 6), null, ignored))
    }

    @Test
    fun `a series skipped elsewhere is gone`() {
        val noMatch = TrackerFill.TrackerFillItem(1, "T", TrackerFill.TrackerFillProblem.NO_MATCH)
        assertEquals(noMatch, TrackerFill.prune(noMatch, empty, null, emptyMap()))
        assertEquals(null, TrackerFill.prune(noMatch, empty, null, mapOf("*" to listOf("kept"))))
    }

    @Test
    fun `a new value after a decision is asked about`() {
        val ignored = mapOf(Field.STATUS.key to listOf("1"))
        val change = TrackerFill.review(full.copy(status = 6), listOf(match.copy(status = 2)), null, ignored).single()
        assertEquals("2", change.options.single().value)
    }
}
