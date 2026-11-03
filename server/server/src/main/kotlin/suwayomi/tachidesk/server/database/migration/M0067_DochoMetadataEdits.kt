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
 * Dōchō Server: series details edited on the server. `overrides` holds the edited fields as a
 * JSON object, which scans apply over what the files say (Kavita's locked fields); `edited_at`
 * is when they last changed, in milliseconds, for Dōchō Sync.
 */
@Suppress("ClassName", "unused")
class M0067_DochoMetadataEdits : SQLMigration() {
    override val sql =
        when (serverConfig.databaseType.value) {
            DatabaseType.POSTGRESQL ->
                """
                ALTER TABLE docho_series_info ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE docho_series_info ADD COLUMN edited_at BIGINT NOT NULL DEFAULT 0;
                """.trimIndent()
            DatabaseType.H2 ->
                """
                ALTER TABLE docho_series_info ADD COLUMN IF NOT EXISTS overrides VARCHAR(1000000000) NOT NULL DEFAULT '{}';
                ALTER TABLE docho_series_info ADD COLUMN IF NOT EXISTS edited_at BIGINT NOT NULL DEFAULT 0;
                """.trimIndent()
        }
}
