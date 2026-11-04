package suwayomi.tachidesk.server.database.migration

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import de.neonew.exposed.migrations.helpers.SQLMigration
import suwayomi.tachidesk.graphql.types.DatabaseType
import suwayomi.tachidesk.server.serverConfig

/**
 * Dōchō Server: the tracker fill. `docho_series_fill` is what it remembers about a series, and
 * `docho_tracker_fill_item` is the review list a scan leaves, which can take days to go through.
 */
@Suppress("ClassName", "unused")
class M0068_DochoSeriesFill : SQLMigration() {
    private val text =
        when (serverConfig.databaseType.value) {
            DatabaseType.POSTGRESQL -> "TEXT"
            DatabaseType.H2 -> "VARCHAR(1000000000)"
        }

    override val sql =
        """
        CREATE TABLE IF NOT EXISTS docho_series_fill (
            manga INT PRIMARY KEY REFERENCES manga(id) ON DELETE CASCADE,
            status INT,
            ignored $text NOT NULL DEFAULT '{}'
        );
        CREATE TABLE IF NOT EXISTS docho_tracker_fill_item (
            manga INT PRIMARY KEY REFERENCES manga(id) ON DELETE CASCADE,
            problem VARCHAR(32) NOT NULL,
            data $text NOT NULL
        );
        """.trimIndent()
}
