package eu.kanade.presentation.more.settings.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import docho.dochosync.DochoSync
import docho.dochosync.DochoSyncConnection
import docho.dochosync.DochoSyncWorker
import docho.koreader.KoreaderApi
import eu.kanade.presentation.more.settings.Preference
import eu.kanade.presentation.util.relativeTimeSpanString
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import mihon.app.di.appGraph
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/**
 * Dōchō Sync, inside the Dōchō Server section of [SettingsSyncScreen] ([SuwayomiSettingsGroup]):
 * syncs the library and categories, edited details, chapter renames and types, read progress and
 * history with Dōchō Server, using its address and login.
 */
object DochoSyncSettingsGroup {

    @Composable
    fun getItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        val preferences = remember { graph.dochoSyncPreferences }
        val api = remember { graph.dochoSyncApi }
        val server = remember { graph.suwayomiPreferences }
        val enabled by preferences.enabled.collectAsState()
        val serverUrl by server.serverUrl.collectAsState()
        val username by server.username.collectAsState()
        val password by server.password.collectAsState()
        val connection by api.connection.collectAsState()
        val status by graph.dochoSync.status.collectAsState()
        val lastSyncAt by preferences.lastSyncAt.collectAsState()
        val lastError by preferences.lastError.collectAsState()

        // Check on opening and after the server or its login changes, then sync if it's new
        LaunchedEffect(serverUrl, username, password, enabled) {
            delay(300)
            withContext(Dispatchers.IO) {
                val result = api.checkConnection()
                DochoSyncWorker.schedulePeriodic(context)
                if (result is DochoSyncConnection.Connected && preferences.since.get() == 0L) DochoSyncWorker.syncNow(context)
            }
        }

        val summary = when {
            connection is DochoSyncConnection.Failed -> (connection as DochoSyncConnection.Failed).reason
            else -> when (val current = status) {
                DochoSync.Status.Syncing -> stringResource(MR.strings.docho_sync_running)
                is DochoSync.Status.Done -> stringResource(MR.strings.docho_sync_done, current.sent, current.received)
                else -> when {
                    lastError.isNotBlank() -> stringResource(MR.strings.docho_sync_failed, lastError)
                    lastSyncAt > 0 -> stringResource(MR.strings.docho_sync_last, relativeTimeSpanString(lastSyncAt))
                    else -> stringResource(MR.strings.docho_sync_never)
                }
            }
        }

        return buildList {
            add(Preference.PreferenceItem.InfoPreference(title = stringResource(MR.strings.pref_docho_sync_info)))
            add(
                Preference.PreferenceItem.SwitchPreference(
                    preference = preferences.enabled,
                    title = stringResource(MR.strings.pref_docho_sync_enabled),
                    onValueChanged = {
                        preferences.enabled.set(it)
                        DochoSyncWorker.schedulePeriodic(context)
                        true
                    },
                ),
            )
            if (enabled) {
                add(
                    Preference.PreferenceItem.TextPreference(
                        title = stringResource(MR.strings.pref_docho_sync_now),
                        subtitle = summary,
                        widget = { ConnectionLight(connection) },
                        onClick = {
                            if (!preferences.isConfigured()) {
                                context.toast(MR.strings.docho_sync_not_configured)
                            } else if (status != DochoSync.Status.Syncing) {
                                DochoSyncWorker.syncNow(context, always = true)
                            }
                        },
                    ),
                )
                add(
                    Preference.PreferenceItem.SwitchPreference(
                        preference = preferences.automatic,
                        title = stringResource(MR.strings.pref_docho_sync_automatic),
                        subtitle = stringResource(MR.strings.pref_docho_sync_automatic_summary),
                        onValueChanged = {
                            preferences.automatic.set(it)
                            DochoSyncWorker.schedulePeriodic(context)
                            true
                        },
                    ),
                )
            }
        }
    }

    @Composable
    private fun ConnectionLight(connection: DochoSyncConnection) {
        val color = when (connection) {
            is DochoSyncConnection.Connected -> Color(0xFF2E7D32)
            is DochoSyncConnection.Failed -> MaterialTheme.colorScheme.error
            DochoSyncConnection.Checking, DochoSyncConnection.Unknown -> MaterialTheme.colorScheme.outline
        }
        Box(
            modifier = Modifier
                .padding(start = 16.dp)
                .size(14.dp)
                .clip(CircleShape)
                .background(color),
        )
    }
}
