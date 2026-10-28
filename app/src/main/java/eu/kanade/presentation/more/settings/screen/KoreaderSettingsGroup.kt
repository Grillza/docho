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
import eu.kanade.presentation.more.settings.Preference
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import mihon.app.di.appGraph
import mihonka.koreader.KoreaderApi
import mihonka.koreader.KoreaderConnection
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.core.common.util.lang.withIOContext
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/** The KOReader sync section of [SettingsSyncScreen]: the sync server and its account. */
object KoreaderSettingsGroup {

    @Composable
    fun getGroup(): Preference.PreferenceGroup {
        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_category_koreader),
            preferenceItems = getServerItems() + getSyncItems(),
        )
    }

    @Composable
    private fun getServerItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.koreaderPreferences }
        val api = remember { graph.koreaderApi }

        val serverUrl by preferences.serverUrl.collectAsState()
        val username by preferences.username.collectAsState()
        val password by preferences.password.collectAsState()
        val configured = serverUrl.isNotBlank() && username.isNotBlank() && password.isNotBlank()
        val connection by api.connection.collectAsState()

        // Check on opening, and again shortly after the settings are edited.
        LaunchedEffect(serverUrl, username, password) {
            if (configured) delay(300)
            withIOContext { api.checkConnection() }
        }

        return listOf(
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.serverUrl,
                title = stringResource(MR.strings.pref_kavita_server_url),
                subtitle = serverUrl.ifBlank { stringResource(MR.strings.pref_koreader_server_url_hint) },
                onValueChanged = { it.isBlank() || KoreaderApi.normalizeBaseUrl(it) != null },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.username,
                title = stringResource(MR.strings.pref_koreader_username),
                subtitle = username.ifBlank { stringResource(MR.strings.pref_koreader_credentials_summary) },
                onValueChanged = { value ->
                    if (value != value.trim()) {
                        preferences.username.set(value.trim())
                        false
                    } else {
                        true
                    }
                },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.password,
                title = stringResource(MR.strings.pref_koreader_password),
                subtitle = if (password.isBlank()) {
                    stringResource(MR.strings.pref_koreader_credentials_summary)
                } else {
                    stringResource(MR.strings.pref_kavita_api_key_set)
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_connection),
                subtitle = when (val status = connection) {
                    KoreaderConnection.Unknown -> stringResource(
                        if (configured) MR.strings.kavita_connection_tap else MR.strings.koreader_not_configured,
                    )
                    KoreaderConnection.Checking -> stringResource(MR.strings.kavita_test_running)
                    is KoreaderConnection.Connected -> stringResource(
                        MR.strings.koreader_test_success,
                        status.username,
                    )
                    is KoreaderConnection.Failed -> stringResource(MR.strings.kavita_test_failed, status.reason)
                },
                widget = { ConnectionLight(connection) },
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.koreader_not_configured)
                    } else if (connection != KoreaderConnection.Checking) {
                        scope.launch { withIOContext { api.checkConnection() } }
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
        val preferences = remember { graph.koreaderPreferences }
        val sync = remember { graph.koreaderSync }
        var syncing by remember { mutableStateOf(false) }

        return listOf(
            Preference.PreferenceItem.InfoPreference(
                title = stringResource(MR.strings.pref_koreader_matching_info),
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_sync_now),
                subtitle = if (syncing) {
                    stringResource(MR.strings.koreader_sync_running)
                } else {
                    stringResource(MR.strings.pref_koreader_sync_now_summary)
                },
                onClick = {
                    if (!preferences.isConfigured()) {
                        context.toast(MR.strings.koreader_not_configured)
                        return@TextPreference
                    }
                    if (syncing) return@TextPreference
                    syncing = true
                    scope.launch {
                        val count = withIOContext { sync.syncLibrary() }
                        syncing = false
                        context.toast(context.stringResource(MR.strings.koreader_sync_done, count))
                    }
                },
            ),
        )
    }

    @Composable
    private fun ConnectionLight(connection: KoreaderConnection) {
        val color = when (connection) {
            is KoreaderConnection.Connected -> Color(0xFF2E7D32)
            is KoreaderConnection.Failed -> MaterialTheme.colorScheme.error
            KoreaderConnection.Checking, KoreaderConnection.Unknown -> MaterialTheme.colorScheme.outline
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
