package eu.kanade.domain.ui

import android.text.format.DateFormat
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.domain.ui.model.AppTheme
import eu.kanade.domain.ui.model.CustomTheme
import eu.kanade.domain.ui.model.NavBarAlignment
import eu.kanade.domain.ui.model.TabletUiMode
import eu.kanade.domain.ui.model.ThemeMode
import eu.kanade.domain.ui.model.TimeFormat
import eu.kanade.tachiyomi.util.system.DeviceUtil
import eu.kanade.tachiyomi.util.system.isDynamicColorAvailable
import kotlinx.serialization.json.Json
import logcat.LogPriority
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import tachiyomi.core.common.preference.getEnum
import tachiyomi.core.common.util.system.logcat
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.FormatStyle
import java.util.Locale

@Inject
@SingleIn(AppScope::class)
class UiPreferences(
    preferenceStore: PreferenceStore,
) {

    val themeMode: Preference<ThemeMode> = preferenceStore.getEnum("pref_theme_mode_key", ThemeMode.SYSTEM)

    val appTheme: Preference<AppTheme> = preferenceStore.getEnum(
        "pref_app_theme",
        if (DeviceUtil.isDynamicColorAvailable) {
            AppTheme.MONET
        } else {
            AppTheme.DEFAULT
        },
    )

    val themeDarkAmoled: Preference<Boolean> = preferenceStore.getBoolean("pref_theme_dark_amoled_key", false)

    /** The user's own themes, at most [CustomTheme.MAX]. */
    val customThemes: Preference<List<CustomTheme>> = preferenceStore.getObjectFromString(
        key = "custom_themes",
        defaultValue = emptyList(),
        serializer = { Json.encodeToString(it) },
        deserializer = { runCatching { Json.decodeFromString<List<CustomTheme>>(it) }.getOrDefault(emptyList()) },
    )

    /** Which of [customThemes] is used when the app theme is [AppTheme.CUSTOM]. */
    val customThemeIndex: Preference<Int> = preferenceStore.getInt("custom_theme_index", 0)

    /** The custom theme in use, if there is one. */
    fun selectedCustomTheme(): CustomTheme? {
        val themes = customThemes.get()
        return themes.getOrNull(customThemeIndex.get()) ?: themes.firstOrNull()
    }

    val relativeTime: Preference<Boolean> = preferenceStore.getBoolean("relative_time_v2", true)

    val dateFormat: Preference<String> = preferenceStore.getString("app_date_format", "")

    val timeFormat: Preference<TimeFormat> = preferenceStore.getEnum("app_time_format", TimeFormat.FOLLOW_LANGUAGE)

    val tabletUiMode: Preference<TabletUiMode> = preferenceStore.getEnum("tablet_ui_mode", TabletUiMode.AUTOMATIC)

    val imagesInDescription: Preference<Boolean> = preferenceStore.getBoolean("pref_render_images_description", true)

    // Library and More can't be hidden, so the app can always be navigated.
    val showUpdatesTab: Preference<Boolean> = preferenceStore.getBoolean("nav_show_updates", true)

    val showHistoryTab: Preference<Boolean> = preferenceStore.getBoolean("nav_show_history", true)

    val showBrowseTab: Preference<Boolean> = preferenceStore.getBoolean("nav_show_browse", true)

    /** The tabs' order as their keys, comma-separated; tabs missing from it follow in the usual order. */
    val navBarOrder: Preference<String> = preferenceStore.getString("nav_bar_order", "")

    val navBarAlignment: Preference<NavBarAlignment> = preferenceStore.getEnum(
        "nav_bar_alignment",
        NavBarAlignment.CENTER,
    )

    companion object {
        fun dateFormat(format: String, locale: Locale): DateTimeFormatter = when (format) {
            "" -> DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT).withLocale(locale)
            else -> DateTimeFormatter.ofPattern(format, locale)
        }

        fun timeFormat(timeFormat: TimeFormat, locale: Locale, is24HourSystem: Boolean): DateTimeFormatter {
            val use24Hours = when (timeFormat) {
                TimeFormat.FOLLOW_LANGUAGE -> {
                    return DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale)
                }

                TimeFormat.FOLLOW_SYSTEM -> is24HourSystem
                TimeFormat.HOURS_24 -> true
                TimeFormat.HOURS_12 -> false
            }

            val skeleton = if (use24Hours) "Hm" else "hm"
            val pattern = DateFormat.getBestDateTimePattern(locale, skeleton)
            return try {
                DateTimeFormatter.ofPattern(pattern, locale)
            } catch (e: IllegalArgumentException) {
                val fallbackPattern = if (use24Hours) "HH:mm" else "h:mm a"
                logcat(LogPriority.ERROR, e) {
                    "Failed to apply best pattern ('$pattern'), falling back to '$fallbackPattern'"
                }
                DateTimeFormatter.ofPattern(fallbackPattern, locale)
            }
        }

        fun dateTimeFormat(
            dateFormat: String,
            timeFormat: TimeFormat,
            locale: Locale,
            is24HourSystem: Boolean,
        ): DateTimeFormatter {
            return DateTimeFormatterBuilder()
                .append(dateFormat(dateFormat, locale))
                .appendLiteral(' ')
                .append(timeFormat(timeFormat, locale, is24HourSystem))
                .toFormatter(locale)
        }
    }
}
