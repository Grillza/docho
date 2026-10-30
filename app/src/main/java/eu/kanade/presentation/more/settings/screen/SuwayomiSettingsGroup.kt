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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import docho.suwayomi.SuwayomiApi
import docho.suwayomi.SuwayomiConnection
import eu.kanade.presentation.more.settings.Preference
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
 * The Suwayomi section of [SettingsSyncScreen]: a server that runs extensions, whose sources
 * Browse lists beside the extensions installed on the device.
 */
object SuwayomiSettingsGroup {

    @Composable
    fun getGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        return serverGroup(
            title = stringResource(MR.strings.pref_category_suwayomi),
            logo = R.drawable.brand_suwayomi,
            items = getItems(),
            onDelete = {
                graph.suwayomiPreferences.reset()
                graph.suwayomiSources.clear()
            },
        )
    }

    @Composable
    private fun getItems(): List<Preference.PreferenceItem<out Any, out Any>> {
        val context = LocalContext.current
        val uriHandler = LocalUriHandler.current
        val scope = rememberCoroutineScope()
        val graph = remember { context.appGraph }
        val preferences = remember { graph.suwayomiPreferences }
        val api = remember { graph.suwayomiApi }
        val sources = remember { graph.suwayomiSources }

        val serverUrl by preferences.serverUrl.collectAsState()
        val username by preferences.username.collectAsState()
        val password by preferences.password.collectAsState()
        val configured = SuwayomiApi.normalizeBaseUrl(serverUrl) != null
        val connection by api.connection.collectAsState()

        suspend fun checkConnection() {
            val result = withContext(Dispatchers.IO) { api.checkConnection() }
            if (result is SuwayomiConnection.Connected) {
                val loaded = withContext(Dispatchers.IO) { sources.refresh() }
                if (!loaded) context.toast(MR.strings.suwayomi_sources_failed)
            }
        }

        // Check on opening, and again shortly after the address or sign-in is edited.
        LaunchedEffect(serverUrl, username, password) {
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
                subtitle = serverUrl.ifBlank { stringResource(MR.strings.pref_suwayomi_server_url_hint) },
                onValueChanged = { value ->
                    val valid = value.isBlank() || SuwayomiApi.normalizeBaseUrl(value) != null
                    // Another server has other sources.
                    if (valid && value != serverUrl) sources.clear()
                    valid
                },
            ),
            Preference.PreferenceItem.EditTextPreference(
                preference = preferences.username,
                title = stringResource(MR.strings.pref_koreader_username),
                subtitle = username.ifBlank { stringResource(MR.strings.pref_suwayomi_credentials_summary) },
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
                    stringResource(MR.strings.pref_suwayomi_credentials_summary)
                } else {
                    stringResource(MR.strings.pref_kavita_api_key_set)
                },
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_kavita_connection),
                subtitle = when (val status = connection) {
                    SuwayomiConnection.Unknown -> stringResource(
                        if (configured) MR.strings.kavita_connection_tap else MR.strings.suwayomi_not_configured,
                    )
                    SuwayomiConnection.Checking -> stringResource(MR.strings.kavita_test_running)
                    is SuwayomiConnection.Connected -> stringResource(MR.strings.suwayomi_test_success, status.server)
                    is SuwayomiConnection.Failed -> stringResource(MR.strings.kavita_test_failed, status.reason)
                },
                widget = { ConnectionLight(connection) },
                onClick = {
                    if (!configured) {
                        context.toast(MR.strings.suwayomi_not_configured)
                    } else if (connection != SuwayomiConnection.Checking) {
                        scope.launch { checkConnection() }
                    }
                },
            ),
            Preference.PreferenceItem.InfoPreference(
                title = stringResource(MR.strings.pref_suwayomi_sources_info),
            ),
            Preference.PreferenceItem.SwitchPreference(
                preference = preferences.showNsfw,
                title = stringResource(MR.strings.pref_suwayomi_show_nsfw),
                subtitle = stringResource(MR.strings.pref_suwayomi_show_nsfw_summary),
            ),
            Preference.PreferenceItem.TextPreference(
                title = stringResource(MR.strings.pref_suwayomi_open),
                subtitle = stringResource(MR.strings.pref_suwayomi_open_summary),
                onClick = {
                    val baseUrl = api.baseUrlOrNull()
                    if (baseUrl == null) {
                        context.toast(MR.strings.suwayomi_not_configured)
                    } else {
                        uriHandler.openUri(baseUrl)
                    }
                },
            ),
        )
    }

    @Composable
    private fun ConnectionLight(connection: SuwayomiConnection) {
        val color = when (connection) {
            is SuwayomiConnection.Connected -> Color(0xFF2E7D32)
            is SuwayomiConnection.Failed -> MaterialTheme.colorScheme.error
            SuwayomiConnection.Checking, SuwayomiConnection.Unknown -> MaterialTheme.colorScheme.outline
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
