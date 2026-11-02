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
 * The Dōchō Sync section of [SettingsSyncScreen]: the server from `sync-server/`, its account,
 * and syncing the library, renames, read state and history between devices.
 */
object DochoSyncSettingsGroup {

    @Composable
    fun getGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        return serverGroup(
            title = stringResource(MR.strings.pref_category_docho_sync),
            logo = R.drawable.ic_launcher_monochrome,
            items = getServerItems() + getSyncItems(),
            onDelete = {
                graph.dochoSyncPreferences.reset()
                graph.dochoSync.resetState()
                DochoSyncWorker.schedulePeriodic(context)
            },
        )
    }

    @Composable
    private fun getServerItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.dochoSyncPreferences }
        val api = remember { graph.dochoSyncApi }

        val serverUrl by preferences.serverUrl.collectAsState()
        val username by preferences.username.collectAsState()
        val password by preferences.password.collectAsState()
        val configured = serverUrl.isNotBlank() && username.isNotBlank() && password.isNotBlank()
        val connection by api.connection.collectAsState()

        // Check on opening, and sign in again shortly after the settings are edited
        LaunchedEffect(serverUrl, username, password) {
            if (configured) delay(300)
            withContext(Dispatchers.IO) {
                val result = api.checkConnection()
                DochoSyncWorker.schedulePeriodic(context)
                if (result is DochoSyncConnection.Connected) DochoSyncWorker.syncNow(context)
            }
        }

        return listOf(
            Preference.PreferenceItem.InfoPreference(
                title = stringResource(MR.strings.pref_docho_sync_info),
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.serverUrl,
                title = stringResource(MR.strings.pref_kavita_server_url),
                subtitle = serverUrl.ifBlank { stringResource(MR.strings.pref_docho_sync_server_url_hint) },
                onValueChanged = { value ->
                    val valid = value.isBlank() || KoreaderApi.normalizeBaseUrl(value) != null
                    if (valid && value != preferences.serverUrl.get()) {
                        preferences.token.delete()
                        graph.dochoSync.resetState()
                    }
                    valid
                },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.username,
                title = stringResource(MR.strings.pref_koreader_username),
                subtitle = username.ifBlank { stringResource(MR.strings.pref_docho_sync_credentials_summary) },
                onValueChanged = { value ->
                    if (value != value.trim()) {
                        preferences.username.set(value.trim())
                        false
                    } else {
                        if (value != preferences.username.get()) {
                            preferences.token.delete()
                            graph.dochoSync.resetState()
                        }
                        true
                    }
                },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.password,
                title = stringResource(MR.strings.pref_koreader_password),
                subtitle = if (password.isBlank()) {
                    stringResource(MR.strings.pref_docho_sync_credentials_summary)
                } else {
                    stringResource(MR.strings.pref_kavita_api_key_set)
                },
                onValueChanged = {
                    preferences.token.delete()
                    true
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_connection),
                subtitle = when (val status = connection) {
                    DochoSyncConnection.Unknown -> stringResource(
                        if (configured) MR.strings.kavita_connection_tap else MR.strings.docho_sync_not_configured,
                    )
                    DochoSyncConnection.Checking -> stringResource(MR.strings.kavita_test_running)
                    is DochoSyncConnection.Connected -> stringResource(
                        MR.strings.koreader_test_success,
                        status.username,
                    )
                    is DochoSyncConnection.Failed -> stringResource(MR.strings.kavita_test_failed, status.reason)
                },
                widget = { ConnectionLight(connection) },
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.docho_sync_not_configured)
                    } else if (connection != DochoSyncConnection.Checking) {
                        scope.launch { withContext(Dispatchers.IO) { api.signIn() } }
                    }
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_docho_sync_register),
                subtitle = stringResource(MR.strings.pref_docho_sync_register_summary),
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.docho_sync_not_configured)
                        return@TextPreference
                    }
                    scope.launch {
                        val result = withContext(Dispatchers.IO) { api.signIn(register = true) }
                        if (result is DochoSyncConnection.Connected) DochoSyncWorker.syncNow(context, always = true)
                    }
                },
            ),
        )
    }

    @Composable
    private fun getSyncItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        val preferences = remember { graph.dochoSyncPreferences }
        val status by graph.dochoSync.status.collectAsState()
        val lastSyncAt by preferences.lastSyncAt.collectAsState()
        val lastError by preferences.lastError.collectAsState()
        val token by preferences.token.collectAsState()

        val summary = when (val current = status) {
            DochoSync.Status.Syncing -> stringResource(MR.strings.docho_sync_running)
            is DochoSync.Status.Done -> stringResource(MR.strings.docho_sync_done, current.sent, current.received)
            else -> when {
                lastError.isNotBlank() -> stringResource(MR.strings.docho_sync_failed, lastError)
                lastSyncAt > 0 -> stringResource(MR.strings.docho_sync_last, relativeTimeSpanString(lastSyncAt))
                else -> stringResource(MR.strings.docho_sync_never)
            }
        }
        return listOf(
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_docho_sync_now),
                subtitle = summary,
                onClick = {
                    if (token.isBlank()) {
                        context.toast(MR.strings.docho_sync_not_configured)
                    } else if (status != DochoSync.Status.Syncing) {
                        DochoSyncWorker.syncNow(context, always = true)
                    }
                },
            ),
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
