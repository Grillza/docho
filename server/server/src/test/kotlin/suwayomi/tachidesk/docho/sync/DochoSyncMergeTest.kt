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
    ) = DochoSync.mergeUnseen("chapter", current, incoming)

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
    fun `history keeps the latest read`() {
        val earlier = """{"manga":"/series/1","readAt":100}"""
        val later = """{"manga":"/series/1","readAt":200}"""
        assertEquals(later, DochoSync.mergeUnseen("history", later, earlier))
        assertEquals(later, DochoSync.mergeUnseen("history", earlier, later))
    }
}
