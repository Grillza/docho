package suwayomi.tachidesk.docho

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import suwayomi.tachidesk.docho.groups.SeriesGroups
import suwayomi.tachidesk.docho.library.FileNameParser

class FileNameParserTest {
    @Test
    fun `volume in a series folder, with year and release group`() {
        val parsed = FileNameParser.parse("One-Punch Man v23 (2021) (Digital) (1r0n) (f)", "One-Punch Man")
        assertEquals("One-Punch Man", parsed.series)
        assertEquals(23f, parsed.volume)
        assertNull(parsed.chapter)
        assertEquals("1r0n", parsed.releaseGroup)
        assertEquals(2021, parsed.year)
        assertFalse(parsed.isSpecial)
    }

    @Test
    fun `a number in the title is not a chapter`() {
        val parsed = FileNameParser.parse("Kaiju No. 8 v01 (2021) (Digital) (1r0n)", "Kaiju No. 8 (Digital) (1r0n)")
        assertEquals("Kaiju No. 8", parsed.series)
        assertEquals(1f, parsed.volume)
        assertNull(parsed.chapter)
    }

    @Test
    fun `volumes and chapters in one folder`() {
        assertEquals(75f, FileNameParser.parse("JoJo's Bizarre Adventure v075", "JoJo's Bizarre Adventure").volume)
        val chapter = FileNameParser.parse("JoJo's Bizarre Adventure c033", "JoJo's Bizarre Adventure")
        assertNull(chapter.volume)
        assertEquals(33f, chapter.chapter)
    }

    @Test
    fun `loose file names its series`() {
        val parsed = FileNameParser.parse("[Group] Dandadan Vol. 3 Ch. 21.5")
        assertEquals("Dandadan", parsed.series)
        assertEquals(3f, parsed.volume)
        assertEquals(21.5f, parsed.chapter)
        assertEquals("Group", parsed.releaseGroup)
    }

    @Test
    fun `bare trailing number is a chapter`() {
        val parsed = FileNameParser.parse("Dorohedoro 012", "Dorohedoro")
        assertEquals(12f, parsed.chapter)
    }

    @Test
    fun `japanese volume marker`() {
        assertEquals(5f, FileNameParser.parse("チェンソーマン 第5巻", "チェンソーマン").volume)
    }

    @Test
    fun `volume folders and specials`() {
        assertEquals(4f, FileNameParser.parse("Chapter 30", "Bleach", listOf("Volume 4")).volume)
        assertTrue(FileNameParser.parse("Omake", "Bleach", listOf("Specials")).isSpecial)
        assertTrue(FileNameParser.parse("Black Clover SP01", "Black Clover").isSpecial)
    }

    @Test
    fun `a word ending in v is not a volume`() {
        val parsed = FileNameParser.parse("Kyiv 3", "Kyiv")
        assertNull(parsed.volume)
        assertEquals(3f, parsed.chapter)
    }

    @Test
    fun `normalized names match like Kavita`() {
        assertEquals(FileNameParser.normalize("Frieren - Beyond Journey's End"), FileNameParser.normalize("frieren beyond journeys end"))
        assertEquals(FileNameParser.normalize("Pokémon"), FileNameParser.normalize("Pokemon"))
    }

    @Test
    fun `group labels from member titles`() {
        val labels =
            SeriesGroups.suggestLabels(
                "JoJo's Bizarre Adventure",
                listOf(
                    "JoJo's Bizarre Adventure Part 1 - Phantom Blood",
                    "JoJo's Bizarre Adventure Part 3: Stardust Crusaders",
                    "JoJo's Bizarre Adventure: Part 7 Steel Ball Run",
                    "Stone Ocean",
                ),
            )
        assertEquals(listOf("Part 1: Phantom Blood", "Part 3: Stardust Crusaders", "Part 7: Steel Ball Run", "Stone Ocean"), labels)
        assertEquals(3f, SeriesGroups.partNumber("Part III: Stardust Crusaders"))
        assertEquals(2f, SeriesGroups.partNumber("Season 2"))
    }
}
