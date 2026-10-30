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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import doki.kavita.KavitaApi
import doki.kavita.KavitaConnection
import doki.kavita.KavitaSource
import eu.kanade.presentation.more.settings.Preference
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.ui.browse.source.browse.BrowseSourceScreen
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import mihon.app.di.appGraph
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.domain.source.interactor.GetRemoteManga
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/** The Kavita section of [SettingsSyncScreen]: the server, browsing and progress sync. */
object KavitaSettingsGroup {

    @Composable
    fun getGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        return serverGroup(
            title = stringResource(MR.strings.pref_category_kavita),
            logo = R.drawable.brand_kavita,
            items = getServerItems() + getSyncItems(),
            onDelete = {
                graph.kavitaPreferences.reset()
            },
        )
    }

    @Composable
    private fun getServerItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.kavitaPreferences }
        val api = remember { graph.kavitaApi }

        val serverUrl by preferences.serverUrl.collectAsState()
        val apiKey by preferences.apiKey.collectAsState()
        val configured = serverUrl.isNotBlank() && apiKey.isNotBlank()
        val connection by api.connection.collectAsState()

        suspend fun checkConnection() {
            val result = withContext(Dispatchers.IO) { api.checkConnection() }
            if (result is KavitaConnection.Connected) graph.kavitaSource.refreshLibraries()
        }

        // Check on opening, and again shortly after the address or key is edited.
        LaunchedEffect(serverUrl, apiKey) {
            if (configured) {
                delay(300)
                checkConnection()
            } else {
                api.checkConnection()
            }
        }

        return listOf(
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.serverUrl,
                title = stringResource(MR.strings.pref_kavita_server_url),
                subtitle = serverUrl.ifBlank { stringResource(MR.strings.pref_kavita_server_url_hint) },
                onValueChanged = { it.isBlank() || KavitaApi.normalizeApiUrl(it) != null },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.apiKey,
                title = stringResource(MR.strings.pref_kavita_api_key),
                subtitle = if (apiKey.isBlank()) {
                    stringResource(MR.strings.pref_kavita_api_key_summary)
                } else {
                    stringResource(MR.strings.pref_kavita_api_key_set)
                },
                onValueChanged = { value ->
                    // Kavita keys are pasted, often with surrounding whitespace.
                    if (value != value.trim()) {
                        preferences.apiKey.set(value.trim())
                        false
                    } else {
                        true
                    }
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_connection),
                subtitle = when (val status = connection) {
                    KavitaConnection.Unknown -> stringResource(
                        if (configured) MR.strings.kavita_connection_tap else MR.strings.kavita_not_configured,
                    )
                    KavitaConnection.Checking -> stringResource(MR.strings.kavita_test_running)
                    is KavitaConnection.Connected -> stringResource(
                        MR.strings.kavita_test_success,
                        status.version.orEmpty(),
                        status.username,
                    )
                    is KavitaConnection.Failed -> stringResource(MR.strings.kavita_test_failed, status.reason)
                },
                widget = { ConnectionLight(connection) },
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.kavita_not_configured)
                    } else if (connection != KavitaConnection.Checking) {
                        scope.launch { checkConnection() }
                    }
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_browse),
                subtitle = stringResource(MR.strings.pref_kavita_browse_summary),
                onClick = {
                    if (configured) {
                        navigator.push(BrowseSourceScreen(KavitaSource.ID, GetRemoteManga.QUERY_POPULAR))
                    } else {
                        context.toast(MR.strings.kavita_not_configured)
                    }
                },
            ),
        )
    }

    @Composable
    private fun getSyncItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.kavitaPreferences }
        val sync = remember { graph.kavitaSync }
        val syncEnabled by preferences.syncProgress.collectAsState()
        var syncing by remember { mutableStateOf(false) }

        return listOf(
            Preference.PreferenceItem.SwitchPreference(
                preference = preferences.syncProgress,
                title = stringResource(MR.strings.pref_kavita_sync_progress),
                subtitle = stringResource(MR.strings.pref_kavita_sync_progress_summary),
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_sync_now),
                subtitle = if (syncing) {
                    stringResource(MR.strings.kavita_sync_running)
                } else {
                    stringResource(MR.strings.pref_kavita_sync_now_summary)
                },
                visible = syncEnabled,
                onClick = {
                    if (!preferences.isConfigured()) {
                        context.toast(MR.strings.kavita_not_configured)
                        return@TextPreference
                    }
                    if (syncing) return@TextPreference
                    syncing = true
                    scope.launch {
                        val count = withContext(Dispatchers.IO) { sync.syncLibrary() }
                        syncing = false
                        context.toast(context.stringResource(MR.strings.kavita_sync_done, count))
                    }
                },
            ),
        )
    }

    @Composable
    private fun ConnectionLight(connection: KavitaConnection) {
        val color = when (connection) {
            is KavitaConnection.Connected -> Color(0xFF2E7D32)
            is KavitaConnection.Failed -> MaterialTheme.colorScheme.error
            KavitaConnection.Checking, KavitaConnection.Unknown -> MaterialTheme.colorScheme.outline
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
