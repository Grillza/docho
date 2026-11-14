package suwayomi.tachidesk.docho.sync

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals

class DochoSyncMergeTest {
    private fun chapter(
        page: Long,
        read: Boolean = false,
        bookmark: Boolean = false,
    ) = """{"bookmark":$bookmark,"manga":"/series/1","page":$page,"read":$read}"""

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
    fun `history keeps the latest read`() {
        val earlier = """{"manga":"/series/1","readAt":100}"""
        val later = """{"manga":"/series/1","readAt":200}"""
        assertEquals(later, DochoSync.mergeProgress("history", later, earlier))
        assertEquals(later, DochoSync.mergeProgress("history", earlier, later))
    }
}
