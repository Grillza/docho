package eu.kanade.presentation.more.settings.screen

import android.app.Activity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLocale
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import eu.kanade.domain.ui.UiPreferences
import eu.kanade.domain.ui.model.NavBarAlignment
import eu.kanade.domain.ui.model.TabletUiMode
import eu.kanade.domain.ui.model.ThemeMode
import eu.kanade.domain.ui.model.TimeFormat
import eu.kanade.domain.ui.model.setAppCompatDelegateThemeMode
import eu.kanade.presentation.more.settings.Preference
import eu.kanade.presentation.more.settings.screen.appearance.AppLanguageScreen
import eu.kanade.presentation.more.settings.screen.appearance.CustomThemeEditorScreen
import eu.kanade.presentation.more.settings.screen.appearance.CustomThemesScreen
import eu.kanade.presentation.more.settings.widget.AppThemeModePreferenceWidget
import eu.kanade.presentation.more.settings.widget.AppThemePreferenceWidget
import eu.kanade.presentation.util.rememberIs24HourSystem
import eu.kanade.tachiyomi.ui.home.NavBarPreview
import eu.kanade.tachiyomi.ui.home.NavBarTabsEditor
import eu.kanade.tachiyomi.ui.home.navBarTabLooks
import eu.kanade.tachiyomi.ui.home.navBarTabShown
import eu.kanade.tachiyomi.ui.home.orderedNavBarTabs
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toJavaLocalDateTime
import kotlinx.datetime.toLocalDateTime
import mihon.app.di.appGraph
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState
import kotlin.time.Clock

object SettingsAppearanceScreen : SearchableSettings {

    @ReadOnlyComposable
    @Composable
    override fun getTitleRes() = MR.strings.pref_category_appearance

    @Composable
    override fun getPreferences(): List<Preference> {
        val context = LocalContext.current
        val uiPreferences = remember { context.appGraph.uiPreferences }

        return listOf(
            getThemeGroup(uiPreferences = uiPreferences),
            getDisplayGroup(uiPreferences = uiPreferences),
            getNavigationBarGroup(uiPreferences = uiPreferences),
        )
    }

    @Composable
    private fun getNavigationBarGroup(
        uiPreferences: UiPreferences,
    ): Preference.PreferenceGroup {
        val showUpdates by uiPreferences.showUpdatesTab.collectAsState()
        val showHistory by uiPreferences.showHistoryTab.collectAsState()
        val showBrowse by uiPreferences.showBrowseTab.collectAsState()
        val alignment by uiPreferences.navBarAlignment.collectAsState()
        val order by uiPreferences.navBarOrder.collectAsState()
        val allShown = showUpdates && showHistory && showBrowse
        val shownTabs = orderedNavBarTabs(order)
            .filter { tab -> uiPreferences.navBarTabShown(tab)?.let { it.get() } ?: true }
            .map { stringResource(navBarTabLooks.getValue(it).second) }
            .joinToString()
        val alignmentName = stringResource(alignment.titleRes)

        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_category_nav_bar),
            collapsible = true,
            summary = if (allShown) shownTabs else "$shownTabs · $alignmentName",
            preferenceItems = listOf(
                Preference.PreferenceItem.InfoPreference(
                    title = stringResource(MR.strings.pref_nav_bar_info),
                ),
                Preference.PreferenceItem.CustomPreference(
                    title = stringResource(MR.strings.pref_nav_bar_preview),
                ) {
                    NavBarPreview(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                },
                Preference.PreferenceItem.CustomPreference(
                    title = stringResource(MR.strings.pref_nav_bar_tabs),
                ) {
                    NavBarTabsEditor(modifier = Modifier.fillMaxWidth())
                },
                Preference.PreferenceItem.ListPreference(
                    preference = uiPreferences.navBarAlignment,
                    entries = NavBarAlignment.entries.associateWith { stringResource(it.titleRes) },
                    title = stringResource(MR.strings.pref_nav_bar_alignment),
                    visible = !allShown,
                ),
            ),
        )
    }

    @Composable
    private fun getThemeGroup(
        uiPreferences: UiPreferences,
    ): Preference.PreferenceGroup {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow

        val themeModePref = uiPreferences.themeMode
        val themeMode by themeModePref.collectAsState()

        val appThemePref = uiPreferences.appTheme
        val appTheme by appThemePref.collectAsState()

        val amoledPref = uiPreferences.themeDarkAmoled
        val amoled by amoledPref.collectAsState()

        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_category_theme),
            preferenceItems = listOf(
                Preference.PreferenceItem.CustomPreference(
                    title = stringResource(MR.strings.pref_app_theme),
                ) {
                    Column {
                        AppThemeModePreferenceWidget(
                            value = themeMode,
                            onItemClick = {
                                themeModePref.set(it)
                                setAppCompatDelegateThemeMode(it)
                            },
                        )

                        AppThemePreferenceWidget(
                            value = appTheme,
                            amoled = amoled,
                            onItemClick = { appThemePref.set(it) },
                            onCustomClick = {
                                // With none made yet, go straight to making one.
                                if (uiPreferences.customThemes.get().isEmpty()) {
                                    navigator.push(CustomThemeEditorScreen(index = null))
                                } else {
                                    navigator.push(CustomThemesScreen())
                                }
                            },
                        )
                    }
                },
                Preference.PreferenceItem.SwitchPreference(
                    preference = amoledPref,
                    title = stringResource(MR.strings.pref_dark_theme_pure_black),
                    visible = themeMode != ThemeMode.LIGHT,
                    onValueChanged = {
                        (context as? Activity)?.let { ActivityCompat.recreate(it) }
                        true
                    },
                ),
            ),
        )
    }

    @Composable
    private fun getDisplayGroup(
        uiPreferences: UiPreferences,
    ): Preference.PreferenceGroup {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow
        val locale = LocalLocale.current
        val is24HourSystem = rememberIs24HourSystem()

        val now = remember { Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault()).toJavaLocalDateTime() }

        val dateFormat by uiPreferences.dateFormat.collectAsState()
        val formattedDateNow = remember(dateFormat) {
            UiPreferences.dateFormat(dateFormat, locale.platformLocale).format(now)
        }

        return Preference.PreferenceGroup(
            title = stringResource(MR.strings.pref_category_display),
            preferenceItems = listOf(
                Preference.PreferenceItem.TextPreference(
                    title = stringResource(MR.strings.pref_app_language),
                    onClick = { navigator.push(AppLanguageScreen()) },
                ),
                Preference.PreferenceItem.ListPreference(
                    preference = uiPreferences.tabletUiMode,
                    entries = TabletUiMode.entries
                        .associateWith { stringResource(it.titleRes) },
                    title = stringResource(MR.strings.pref_tablet_ui_mode),
                    onValueChanged = {
                        context.toast(MR.strings.requires_app_restart)
                        true
                    },
                ),
                Preference.PreferenceItem.ListPreference(
                    preference = uiPreferences.dateFormat,
                    entries = DateFormats
                        .associateWith {
                            val formattedDate = UiPreferences.dateFormat(it, locale.platformLocale).format(now)
                            "${it.ifEmpty { stringResource(MR.strings.label_default) }} ($formattedDate)"
                        },
                    title = stringResource(MR.strings.pref_date_format),
                ),
                Preference.PreferenceItem.ListPreference(
                    preference = uiPreferences.timeFormat,
                    entries = TimeFormat.entries
                        .associateWith {
                            val formattedTime = UiPreferences.timeFormat(
                                it,
                                locale.platformLocale,
                                is24HourSystem,
                            ).format(now)
                            "${stringResource(it.titleRes)} ($formattedTime)"
                        },
                    title = stringResource(MR.strings.pref_time_format),
                ),
                Preference.PreferenceItem.SwitchPreference(
                    preference = uiPreferences.relativeTime,
                    title = stringResource(MR.strings.pref_relative_format),
                    subtitle = stringResource(
                        MR.strings.pref_relative_format_summary,
                        stringResource(MR.strings.relative_time_today),
                        formattedDateNow,
                    ),
                ),
                Preference.PreferenceItem.SwitchPreference(
                    preference = uiPreferences.imagesInDescription,
                    title = stringResource(MR.strings.pref_display_images_description),
                ),
            ),
        )
    }
}

private val DateFormats = listOf(
    "", // Default
    "MM/dd/yy",
    "dd/MM/yy",
    "yyyy-MM-dd",
    "dd MMM yyyy",
    "MMM dd, yyyy",
)
