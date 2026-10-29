package eu.kanade.presentation.more.settings.screen

import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import eu.kanade.presentation.more.settings.Preference
import mihon.app.di.appGraph
import mihonka.sync.ProgressSyncMode
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.padding
import tachiyomi.presentation.core.i18n.stringResource

/** The servers Mihonka reads from and syncs with, and where reading progress is synced. */
object SettingsSyncScreen : SearchableSettings {

    @ReadOnlyComposable
    @Composable
    override fun getTitleRes() = MR.strings.pref_category_sync

    @Composable
    override fun getPreferences(): List<Preference> {
        return listOf(
            getModeGroup(),
            KavitaSettingsGroup.getGroup(),
            BookOrbitSettingsGroup.getGroup(),
            KomgaSettingsGroup.getGroup(),
            KoreaderSettingsGroup.getGroup(),
        )
    }

    @Composable
    private fun getModeGroup(): Preference.PreferenceGroup {
        val context = LocalContext.current
        val graph = remember { context.appGraph }
        val preferences = remember { graph.progressSyncPreferences }
        val komgaPreferences = remember { graph.komgaPreferences }
        val koreaderSummary = stringResource(MR.strings.pref_progress_sync_mode_koreader_summary)
        var showKomgaNotice by remember { mutableStateOf(false) }

        if (showKomgaNotice) {
            KomgaKoreaderNotice(
                onAnswer = { allow, hideNotice ->
                    komgaPreferences.koreaderDownloads.set(allow)
                    if (hideNotice) komgaPreferences.koreaderNoticeHidden.set(true)
                    showKomgaNotice = false
                },
                onDismissRequest = { showKomgaNotice = false },
            )
        }

        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_progress_sync),
            preferenceItems = listOf(
                Preference.PreferenceItem.ListPreference(
                    preference = preferences.mode,
                    entries = mapOf(
                        ProgressSyncMode.SOURCE to stringResource(MR.strings.pref_progress_sync_mode_source),
                        ProgressSyncMode.KOREADER to stringResource(MR.strings.pref_progress_sync_mode_koreader),
                    ),
                    title = stringResource(MR.strings.pref_progress_sync_mode),
                    subtitleProvider = { value, entries ->
                        if (value == ProgressSyncMode.KOREADER) koreaderSummary else entries[value]
                    },
                    onValueChanged = { mode ->
                        // Komga books can only be matched with KOReader by downloading them, so ask first.
                        if (mode == ProgressSyncMode.KOREADER &&
                            preferences.mode.get() != ProgressSyncMode.KOREADER &&
                            komgaPreferences.isConfigured() &&
                            !komgaPreferences.koreaderNoticeHidden.get()
                        ) {
                            showKomgaNotice = true
                        }
                        true
                    },
                ),
            ),
        )
    }

    /**
     * Explains that matching Komga books with KOReader means downloading them, and asks whether
     * to. [onAnswer] gets the choice and whether to stop asking.
     */
    @Composable
    private fun KomgaKoreaderNotice(
        onAnswer: (allow: Boolean, hideNotice: Boolean) -> Unit,
        onDismissRequest: () -> Unit,
    ) {
        var hideNotice by remember { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = onDismissRequest,
            title = { Text(text = stringResource(MR.strings.komga_koreader_notice_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(MaterialTheme.padding.small)) {
                    Text(text = stringResource(MR.strings.komga_koreader_notice_text))
                    // The whole row ticks the box, not only the box itself.
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .toggleable(value = hideNotice, role = Role.Checkbox, onValueChange = { hideNotice = it }),
                    ) {
                        Checkbox(checked = hideNotice, onCheckedChange = null)
                        Text(text = stringResource(MR.strings.komga_koreader_notice_hide))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { onAnswer(true, hideNotice) }) {
                    Text(text = stringResource(MR.strings.komga_koreader_notice_allow))
                }
            },
            dismissButton = {
                TextButton(onClick = { onAnswer(false, hideNotice) }) {
                    Text(text = stringResource(MR.strings.komga_koreader_notice_deny))
                }
            },
        )
    }
}

/**
 * A server's section of [SettingsSyncScreen], folded to its [logo], [title] and connection status
 * (the item titled "Connection") until opened. It ends with Delete, which asks before calling
 * [onDelete] to erase the section's settings.
 */
@Composable
internal fun serverGroup(
    title: String,
    @DrawableRes logo: Int,
    items: List<Preference.PreferenceItem<out Any, out Any>>,
    onDelete: () -> Unit,
): Preference.PreferenceGroup {
    val connectionTitle = stringResource(MR.strings.pref_kavita_connection)
    val connection = items.firstOrNull { it.title == connectionTitle } as? Preference.PreferenceItem.TextPreference
    var confirmDelete by remember { mutableStateOf(false) }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(text = stringResource(MR.strings.pref_server_delete_title, title)) },
            text = { Text(text = stringResource(MR.strings.pref_server_delete_text, title)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDelete()
                        confirmDelete = false
                    },
                ) {
                    Text(text = stringResource(MR.strings.action_delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) {
                    Text(text = stringResource(MR.strings.action_cancel))
                }
            },
        )
    }

    return Preference.PreferenceGroup(
        title = title,
        preferenceItems = items + Preference.PreferenceItem.TextPreference(
            title = stringResource(MR.strings.action_delete),
            subtitle = stringResource(MR.strings.pref_server_delete_summary, title),
            onClick = { confirmDelete = true },
        ),
        collapsible = true,
        icon = painterResource(logo),
        summary = connection?.subtitle,
        summaryWidget = connection?.widget,
    )
}
