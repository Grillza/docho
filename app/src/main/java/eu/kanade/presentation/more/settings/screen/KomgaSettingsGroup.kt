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
import eu.kanade.presentation.more.settings.Preference
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.ui.browse.source.browse.BrowseSourceScreen
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import mihon.app.di.appGraph
import mihonka.komga.KomgaApi
import mihonka.komga.KomgaConnection
import mihonka.komga.KomgaSource
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.core.common.util.lang.withIOContext
import tachiyomi.domain.source.interactor.GetRemoteManga
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/** The Komga section of [SettingsSyncScreen]: the server, browsing and progress sync. */
object KomgaSettingsGroup {

    @Composable
    fun getGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        return serverGroup(
            title = stringResource(MR.strings.pref_category_komga),
            logo = R.drawable.brand_komga,
            items = getServerItems() + getSyncItems(),
            onDelete = {
                graph.komgaPreferences.reset()
            },
        )
    }

    @Composable
    private fun getServerItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.komgaPreferences }
        val api = remember { graph.komgaApi }

        val serverUrl by preferences.serverUrl.collectAsState()
        val apiKey by preferences.apiKey.collectAsState()
        val configured = serverUrl.isNotBlank() && apiKey.isNotBlank()
        val connection by api.connection.collectAsState()

        suspend fun checkConnection() {
            val result = withIOContext { api.checkConnection() }
            if (result is KomgaConnection.Connected) graph.komgaSource.refreshLibraries()
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
                subtitle = serverUrl.ifBlank { stringResource(MR.strings.pref_komga_server_url_hint) },
                onValueChanged = { it.isBlank() || KomgaApi.normalizeApiUrl(it) != null },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.apiKey,
                title = stringResource(MR.strings.pref_kavita_api_key),
                subtitle = if (apiKey.isBlank()) {
                    stringResource(MR.strings.pref_komga_api_key_summary)
                } else {
                    stringResource(MR.strings.pref_kavita_api_key_set)
                },
                onValueChanged = { value ->
                    // Komga keys are pasted, often with surrounding whitespace.
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
                    KomgaConnection.Unknown -> stringResource(
                        if (configured) MR.strings.kavita_connection_tap else MR.strings.komga_not_configured,
                    )
                    KomgaConnection.Checking -> stringResource(MR.strings.kavita_test_running)
                    is KomgaConnection.Connected -> stringResource(
                        MR.strings.komga_test_success,
                        status.username,
                    )
                    is KomgaConnection.Failed -> stringResource(MR.strings.kavita_test_failed, status.reason)
                },
                widget = { ConnectionLight(connection) },
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.komga_not_configured)
                    } else if (connection != KomgaConnection.Checking) {
                        scope.launch { checkConnection() }
                    }
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_komga_browse),
                subtitle = stringResource(MR.strings.pref_komga_browse_summary),
                onClick = {
                    if (configured) {
                        navigator.push(BrowseSourceScreen(KomgaSource.ID, GetRemoteManga.QUERY_POPULAR))
                    } else {
                        context.toast(MR.strings.komga_not_configured)
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
        val preferences = remember { graph.komgaPreferences }
        val sync = remember { graph.komgaSync }
        val syncEnabled by preferences.syncProgress.collectAsState()
        var syncing by remember { mutableStateOf(false) }

        return listOf(
            Preference.PreferenceItem.SwitchPreference(
                preference = preferences.syncProgress,
                title = stringResource(MR.strings.pref_kavita_sync_progress),
                subtitle = stringResource(MR.strings.pref_komga_sync_progress_summary),
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_sync_now),
                subtitle = if (syncing) {
                    stringResource(MR.strings.komga_sync_running)
                } else {
                    stringResource(MR.strings.pref_komga_sync_now_summary)
                },
                visible = syncEnabled,
                onClick = {
                    if (!preferences.isConfigured()) {
                        context.toast(MR.strings.komga_not_configured)
                        return@TextPreference
                    }
                    if (syncing) return@TextPreference
                    syncing = true
                    scope.launch {
                        val count = withIOContext { sync.syncLibrary() }
                        syncing = false
                        context.toast(context.stringResource(MR.strings.komga_sync_done, count))
                    }
                },
            ),
        )
    }

    @Composable
    private fun ConnectionLight(connection: KomgaConnection) {
        val color = when (connection) {
            is KomgaConnection.Connected -> Color(0xFF2E7D32)
            is KomgaConnection.Failed -> MaterialTheme.colorScheme.error
            KomgaConnection.Checking, KomgaConnection.Unknown -> MaterialTheme.colorScheme.outline
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
