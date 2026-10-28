package eu.kanade.presentation.more.settings.screen

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import eu.kanade.presentation.more.settings.Preference
import mihon.app.di.appGraph
import mihonka.sync.ProgressSyncMode
import tachiyomi.i18n.MR
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
        val preferences = remember { context.appGraph.progressSyncPreferences }
        val koreaderSummary = stringResource(MR.strings.pref_progress_sync_mode_koreader_summary)

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
                ),
            ),
        )
    }
}
