package suwayomi.tachidesk.docho.sync

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DochoSyncMergeTest {
    private fun chapter(
        page: Long,
        read: Boolean = false,
        bookmark: Boolean = false,
    ) = """{"bookmark":$bookmark,"manga":"/series/1","page":$page,"read":$read}"""

    private fun timed(
        page: Long,
        at: Long,
        read: Boolean = false,
    ) = DochoSync.canonical(Json.parseToJsonElement(chapter(page, read).dropLast(1) + ",\"at\":$at}"))

    private fun merge(
        current: String,
        incoming: String,
    ) = DochoSync.mergeProgress("chapter", current, incoming)

    @Test
    fun `a stale page doesn't undo a later one`() {
        assertEquals(chapter(110), merge(chapter(110), chapter(4)))
    }

    @Test
    fun `the further page wins from either side`() {
        assertEquals(chapter(200), merge(chapter(10), chapter(200)))
    }

    @Test
    fun `read on either device is read, with the page cleared as the apps write it`() {
        assertEquals(chapter(0, read = true), merge(chapter(0, read = true), chapter(30)))
        assertEquals(chapter(0, read = true), merge(chapter(30), chapter(0, read = true)))
    }

    @Test
    fun `a bookmark on the stale device joins the further page`() {
        assertEquals(chapter(40, bookmark = true), merge(chapter(40), chapter(5, bookmark = true)))
    }

    @Test
    fun `an app that's behind after an update doesn't undo progress it had seen`() {
        // The app had seen page 110 and sends its older page 4: the server keeps 110.
        assertEquals(chapter(110), DochoSync.mergeProgress("chapter", chapter(110), chapter(4), deviceDecidesBookmark = true))
        assertEquals(chapter(0, read = true), DochoSync.mergeProgress("chapter", chapter(0, read = true), chapter(0), deviceDecidesBookmark = true))
    }

    @Test
    fun `a bookmark removed on a device that had seen it stays removed`() {
        assertEquals(chapter(40), DochoSync.mergeProgress("chapter", chapter(40, bookmark = true), chapter(40), deviceDecidesBookmark = true))
        assertEquals(chapter(40, bookmark = true), DochoSync.mergeProgress("chapter", chapter(40, bookmark = true), chapter(40)))
    }

    @Test
    fun `nothing further on the server keeps its text`() {
        val current = chapter(110)
        assertEquals(current, DochoSync.mergeProgress("chapter", current, chapter(110)))
    }

    @Test
    fun `going back on purpose later wins`() {
        assertEquals(timed(4, at = 300), DochoSync.mergeProgress("chapter", timed(110, at = 200), timed(4, at = 300)))
        assertEquals(timed(0, at = 300), DochoSync.mergeProgress("chapter", timed(0, at = 200, read = true), timed(0, at = 300)))
    }

    @Test
    fun `an older page read earlier doesn't win`() {
        assertEquals(timed(110, at = 200), DochoSync.mergeProgress("chapter", timed(110, at = 200), timed(4, at = 100)))
    }

    @Test
    fun `a change with a time beats one without only if it came after that was stored`() {
        // Stored at 250 by an app that puts no time on it; read at 300, so it's later.
        assertEquals(timed(4, at = 300), DochoSync.mergeProgress("chapter", chapter(110), timed(4, at = 300), currentStored = 250))
        // Stored at 350: it may have been read after 300, so the furthest point is kept, with the known time.
        assertEquals(timed(110, at = 300), DochoSync.mergeProgress("chapter", chapter(110), timed(4, at = 300), currentStored = 350))
        // Without times at all, the furthest point.
        assertEquals(chapter(110), DochoSync.mergeProgress("chapter", chapter(110), chapter(4), currentStored = 1, incomingStored = 2))
    }

    @Test
    fun `progress compares without its time, and behind means unread or an earlier page`() {
        assertTrue(DochoSync.sameProgress(timed(4, at = 1), chapter(4)))
        assertFalse(DochoSync.sameProgress(timed(4, at = 1), chapter(5)))
        assertTrue(DochoSync.isBehind(chapter(4), chapter(110)))
        assertTrue(DochoSync.isBehind(chapter(4), chapter(0, read = true)))
        assertFalse(DochoSync.isBehind(chapter(0, read = true), chapter(110)))
        assertFalse(DochoSync.isBehind(chapter(110), chapter(4)))
    }

    @Test
    fun `history keeps the latest read`() {
        val earlier = """{"manga":"/series/1","readAt":100}"""
        val later = """{"manga":"/series/1","readAt":200}"""
        assertEquals(later, DochoSync.mergeProgress("history", later, earlier))
        assertEquals(later, DochoSync.mergeProgress("history", earlier, later))
    }
}
