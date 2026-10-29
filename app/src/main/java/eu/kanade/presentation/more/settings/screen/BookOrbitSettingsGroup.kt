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
import mihonka.bookorbit.BookOrbitApi
import mihonka.bookorbit.BookOrbitConnection
import mihonka.bookorbit.BookOrbitSource
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.core.common.util.lang.withIOContext
import tachiyomi.domain.source.interactor.GetRemoteManga
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/** The BookOrbit section of [SettingsSyncScreen]: the server, browsing and progress sync. */
object BookOrbitSettingsGroup {

    @Composable
    fun getGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        return serverGroup(
            title = stringResource(MR.strings.pref_category_bookorbit),
            logo = R.drawable.brand_bookorbit,
            items = getServerItems() + getSyncItems(),
            onDelete = {
                graph.bookOrbitApi.signOut()
                graph.bookOrbitPreferences.reset()
            },
        )
    }

    @Composable
    private fun getServerItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.bookOrbitPreferences }
        val api = remember { graph.bookOrbitApi }

        val serverUrl by preferences.serverUrl.collectAsState()
        val username by preferences.username.collectAsState()
        val password by preferences.password.collectAsState()
        val configured = serverUrl.isNotBlank() && username.isNotBlank() && password.isNotBlank()
        val connection by api.connection.collectAsState()

        suspend fun checkConnection() {
            val result = withIOContext { api.checkConnection() }
            if (result is BookOrbitConnection.Connected) graph.bookOrbitSource.refreshLibraries()
        }

        // Check on opening, and again shortly after the settings are edited.
        LaunchedEffect(serverUrl, username, password) {
            if (configured) delay(300)
            checkConnection()
        }

        // A new server or account needs a new session.
        val signOutOnChange: suspend (String) -> Boolean = {
            api.signOut()
            true
        }

        return listOf(
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.serverUrl,
                title = stringResource(MR.strings.pref_kavita_server_url),
                subtitle = serverUrl.ifBlank { stringResource(MR.strings.pref_bookorbit_server_url_hint) },
                onValueChanged = { value ->
                    val valid = value.isBlank() || BookOrbitApi.normalizeApiUrl(value) != null
                    if (valid) api.signOut()
                    valid
                },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.username,
                title = stringResource(MR.strings.pref_koreader_username),
                subtitle = username.ifBlank { stringResource(MR.strings.pref_bookorbit_credentials_summary) },
                onValueChanged = { value ->
                    if (value != value.trim()) {
                        preferences.username.set(value.trim())
                        api.signOut()
                        false
                    } else {
                        signOutOnChange(value)
                    }
                },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.password,
                title = stringResource(MR.strings.pref_koreader_password),
                subtitle = if (password.isBlank()) {
                    stringResource(MR.strings.pref_bookorbit_credentials_summary)
                } else {
                    stringResource(MR.strings.pref_kavita_api_key_set)
                },
                onValueChanged = signOutOnChange,
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_connection),
                subtitle = when (val status = connection) {
                    BookOrbitConnection.Unknown -> stringResource(
                        if (configured) MR.strings.kavita_connection_tap else MR.strings.bookorbit_not_configured,
                    )
                    BookOrbitConnection.Checking -> stringResource(MR.strings.kavita_test_running)
                    is BookOrbitConnection.Connected -> stringResource(
                        MR.strings.koreader_test_success,
                        status.username,
                    )
                    is BookOrbitConnection.Failed -> stringResource(MR.strings.kavita_test_failed, status.reason)
                },
                widget = { ConnectionLight(connection) },
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.bookorbit_not_configured)
                    } else if (connection != BookOrbitConnection.Checking) {
                        scope.launch { checkConnection() }
                    }
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_bookorbit_browse),
                subtitle = stringResource(MR.strings.pref_bookorbit_browse_summary),
                onClick = {
                    if (configured) {
                        navigator.push(BrowseSourceScreen(BookOrbitSource.ID, GetRemoteManga.QUERY_POPULAR))
                    } else {
                        context.toast(MR.strings.bookorbit_not_configured)
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
        val preferences = remember { graph.bookOrbitPreferences }
        val sync = remember { graph.bookOrbitSync }
        val syncEnabled by preferences.syncProgress.collectAsState()
        var syncing by remember { mutableStateOf(false) }

        return listOf(
            Preference.PreferenceItem.SwitchPreference(
                preference = preferences.syncProgress,
                title = stringResource(MR.strings.pref_kavita_sync_progress),
                subtitle = stringResource(MR.strings.pref_bookorbit_sync_progress_summary),
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_sync_now),
                subtitle = if (syncing) {
                    stringResource(MR.strings.bookorbit_sync_running)
                } else {
                    stringResource(MR.strings.pref_bookorbit_sync_now_summary)
                },
                visible = syncEnabled,
                onClick = {
                    if (!preferences.isConfigured()) {
                        context.toast(MR.strings.bookorbit_not_configured)
                        return@TextPreference
                    }
                    if (syncing) return@TextPreference
                    syncing = true
                    scope.launch {
                        val count = withIOContext { sync.syncLibrary() }
                        syncing = false
                        context.toast(context.stringResource(MR.strings.bookorbit_sync_done, count))
                    }
                },
            ),
        )
    }

    @Composable
    private fun ConnectionLight(connection: BookOrbitConnection) {
        val color = when (connection) {
            is BookOrbitConnection.Connected -> Color(0xFF2E7D32)
            is BookOrbitConnection.Failed -> MaterialTheme.colorScheme.error
            BookOrbitConnection.Checking, BookOrbitConnection.Unknown -> MaterialTheme.colorScheme.outline
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
