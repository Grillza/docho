package eu.kanade.presentation.more.settings.screen.appearance

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import dev.icerock.moko.resources.StringResource
import eu.kanade.domain.ui.model.AppTheme
import eu.kanade.domain.ui.model.CustomTheme
import eu.kanade.presentation.components.AppBar
import eu.kanade.presentation.more.settings.widget.AppThemePreviewItem
import eu.kanade.presentation.more.settings.widget.PreferenceGroupHeader
import eu.kanade.presentation.more.settings.widget.TextPreferenceWidget
import eu.kanade.presentation.theme.CustomTachiyomiTheme
import eu.kanade.presentation.theme.colorscheme.CustomColorScheme
import eu.kanade.presentation.theme.getThemeColorScheme
import eu.kanade.presentation.util.Screen
import eu.kanade.tachiyomi.util.system.DeviceUtil
import eu.kanade.tachiyomi.util.system.isDynamicColorAvailable
import kotlinx.serialization.json.Json
import mihon.app.di.appGraph
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.rounded.Warning
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.Scaffold
import tachiyomi.presentation.core.i18n.stringResource
import androidx.compose.foundation.isSystemInDarkTheme as isSystemDark

/**
 * Makes or changes one of the user's themes: each colour from standard colours or a colour
 * wheel, how strongly the colours worked out from them stand apart, and a full-screen preview.
 * [index] is the theme being changed, or null for a new one.
 */
class CustomThemeEditorScreen(private val index: Int?) : Screen() {

    @Composable
    override fun Content() {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow
        val uiPreferences = remember { context.appGraph.uiPreferences }
        val isDark = isSystemDark()

        val themes = remember { uiPreferences.customThemes.get() }
        val defaultName = stringResource(MR.strings.custom_theme_default_name, themes.size + 1)
        val currentColors = MaterialTheme.colorScheme
        val original = remember {
            index?.let(themes::getOrNull) ?: CustomColorScheme.from(currentColors, defaultName)
        }
        var theme by rememberSaveable(stateSaver = CustomThemeSaver) { mutableStateOf(original) }
        var editing by remember { mutableStateOf<ColorRole?>(null) }
        var previewing by rememberSaveable { mutableStateOf(false) }
        var choosingStart by rememberSaveable { mutableStateOf(false) }
        var confirmDiscard by rememberSaveable { mutableStateOf(false) }

        val changed = theme != original
        fun leave() {
            if (changed) confirmDiscard = true else navigator.pop()
        }
        BackHandler(enabled = changed) { confirmDiscard = true }

        fun save() {
            val named = theme.copy(name = theme.name.trim().ifEmpty { defaultName })
            val list = uiPreferences.customThemes.get().toMutableList()
            val saved = if (index != null && index in list.indices) {
                list[index] = named
                index
            } else {
                list += named
                list.lastIndex
            }
            uiPreferences.customThemes.set(list.take(CustomTheme.MAX))
            uiPreferences.customThemeIndex.set(saved)
            uiPreferences.appTheme.set(AppTheme.CUSTOM)
            navigator.pop()
            (context as? Activity)?.let { ActivityCompat.recreate(it) }
        }

        Scaffold(
            topBar = { scrollBehavior ->
                AppBar(
                    title = stringResource(
                        if (index == null) MR.strings.custom_theme_new else MR.strings.custom_theme_edit,
                    ),
                    navigateUp = ::leave,
                    scrollBehavior = scrollBehavior,
                )
            },
            bottomBar = {
                Surface(tonalElevation = 3.dp) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        OutlinedButton(onClick = { previewing = true }, modifier = Modifier.weight(1f)) {
                            Text(text = stringResource(MR.strings.custom_theme_preview))
                        }
                        Button(onClick = ::save, modifier = Modifier.weight(1f)) {
                            Text(text = stringResource(MR.strings.action_save))
                        }
                    }
                }
            },
        ) { contentPadding ->
            LazyColumn(contentPadding = contentPadding) {
                item {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // A small look at the theme, which opens the full preview.
                        Box(modifier = Modifier.width(88.dp)) {
                            CustomTachiyomiTheme(customTheme = theme) {
                                AppThemePreviewItem(selected = true, onClick = { previewing = true })
                            }
                        }
                        OutlinedTextField(
                            value = theme.name,
                            onValueChange = { theme = theme.copy(name = it.take(MAX_NAME_LENGTH)) },
                            label = { Text(text = stringResource(MR.strings.custom_theme_name)) },
                            placeholder = { Text(text = defaultName) },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                item {
                    TextPreferenceWidget(
                        title = stringResource(MR.strings.custom_theme_start_from),
                        subtitle = stringResource(MR.strings.custom_theme_start_from_summary),
                        onPreferenceClick = { choosingStart = true },
                    )
                }
                item { PreferenceGroupHeader(title = stringResource(MR.strings.custom_theme_colors)) }
                items(ColorRole.entries) { role ->
                    val color = Color(role.get(theme))
                    TextPreferenceWidget(
                        title = stringResource(role.title),
                        subtitle = stringResource(role.description),
                        widget = { ColorSwatch(color) },
                        onPreferenceClick = { editing = role },
                    )
                }
                item { ReadabilityWarning(theme) }
                item { PreferenceGroupHeader(title = stringResource(MR.strings.custom_theme_contrast)) }
                item {
                    Column(modifier = Modifier.padding(horizontal = 16.dp)) {
                        Text(
                            text = stringResource(MR.strings.custom_theme_contrast_summary),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Slider(
                                value = theme.contrast,
                                onValueChange = { theme = theme.copy(contrast = it) },
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                text = "${(theme.contrast * 100).toInt()}%",
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.padding(start = 12.dp),
                            )
                        }
                    }
                }
                item {
                    Text(
                        text = stringResource(MR.strings.custom_theme_light_dark_note),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }

        editing?.let { role ->
            ColorPickerDialog(
                title = stringResource(role.title),
                initial = Color(role.get(theme)),
                against = role.against?.let { Color(it.get(theme)) },
                onDismissRequest = { editing = null },
                onConfirm = {
                    theme = role.set(theme, it.toArgb())
                    editing = null
                },
            )
        }
        if (previewing) {
            CustomThemePreviewDialog(
                theme = theme.copy(name = theme.name.trim().ifEmpty { defaultName }),
                onDismissRequest = { previewing = false },
            )
        }
        if (choosingStart) {
            StartFromDialog(
                onDismissRequest = { choosingStart = false },
                onPick = { appTheme ->
                    val scheme = getThemeColorScheme(context, appTheme, isDark = isDark, isAmoled = false)
                    theme = CustomColorScheme.from(scheme, theme.name).copy(contrast = theme.contrast)
                    choosingStart = false
                },
            )
        }
        if (confirmDiscard) {
            AlertDialog(
                onDismissRequest = { confirmDiscard = false },
                title = { Text(text = stringResource(MR.strings.custom_theme_discard_title)) },
                text = { Text(text = stringResource(MR.strings.custom_theme_discard_text)) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            confirmDiscard = false
                            navigator.pop()
                        },
                    ) {
                        Text(text = stringResource(MR.strings.custom_theme_discard))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { confirmDiscard = false }) {
                        Text(text = stringResource(MR.strings.custom_theme_keep_editing))
                    }
                },
            )
        }
    }
}

/** A colour the user picks, what it colours, and what it's read against, if anything. */
private enum class ColorRole(
    val title: StringResource,
    val description: StringResource,
    val get: (CustomTheme) -> Int,
    val set: (CustomTheme, Int) -> CustomTheme,
) {
    PRIMARY(
        MR.strings.custom_theme_primary,
        MR.strings.custom_theme_primary_summary,
        { it.primary },
        { t, c -> t.copy(primary = c) },
    ),
    SECONDARY(
        MR.strings.custom_theme_secondary,
        MR.strings.custom_theme_secondary_summary,
        { it.secondary },
        { t, c -> t.copy(secondary = c) },
    ),
    TERTIARY(
        MR.strings.custom_theme_tertiary,
        MR.strings.custom_theme_tertiary_summary,
        { it.tertiary },
        { t, c -> t.copy(tertiary = c) },
    ),
    BACKGROUND(
        MR.strings.custom_theme_background,
        MR.strings.custom_theme_background_summary,
        { it.background },
        { t, c -> t.copy(background = c) },
    ),
    SURFACE(
        MR.strings.custom_theme_surface,
        MR.strings.custom_theme_surface_summary,
        { it.surface },
        { t, c -> t.copy(surface = c) },
    ),
    TEXT(
        MR.strings.custom_theme_text,
        MR.strings.custom_theme_text_summary,
        { it.text },
        { t, c -> t.copy(text = c) },
    ),
    ;

    val against: ColorRole?
        get() = when (this) {
            TEXT, PRIMARY, SECONDARY, TERTIARY -> BACKGROUND
            BACKGROUND, SURFACE -> TEXT
        }
}

@Composable
private fun ColorSwatch(color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = color.toHex(),
            style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Box(
            modifier = Modifier
                .size(32.dp)
                .colorDot(color, behind = MaterialTheme.colorScheme.background),
        )
    }
}

/**
 * Names the colours that would be hard to see: text needs 4.5:1 against the background and
 * bars, as accessibility guidelines ask for text; accent and secondary need 3:1 against the
 * background, as for other things on screen. Highlight isn't checked, as it only colours
 * badges on covers, with text of its own.
 */
@Composable
private fun ReadabilityWarning(theme: CustomTheme) {
    val background = Color(theme.background)
    fun clear(role: ColorRole, against: Color, needed: Float) =
        CustomColorScheme.contrastRatio(Color(role.get(theme)), against) >= needed
    val unclear = buildList {
        if (!clear(ColorRole.TEXT, background, 4.5f) || !clear(ColorRole.TEXT, Color(theme.surface), 4.5f)) {
            add(ColorRole.TEXT)
        }
        listOf(ColorRole.PRIMARY, ColorRole.SECONDARY)
            .filterNot { clear(it, background, 3f) }
            .forEach(::add)
    }
    if (unclear.isEmpty()) return
    val names = unclear.map { stringResource(it.title) }.joinToString()
    Row(
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.errorContainer, MaterialTheme.shapes.medium)
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = MaterialSymbols.Rounded.Warning,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onErrorContainer,
        )
        Text(
            text = stringResource(MR.strings.custom_theme_hard_to_read, names),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onErrorContainer,
        )
    }
}

/** Lists the built-in themes, to copy one's colours as a starting point. */
@Composable
private fun StartFromDialog(onDismissRequest: () -> Unit, onPick: (AppTheme) -> Unit) {
    val builtIn = remember {
        AppTheme.entries.filter {
            it.titleRes != null && it != AppTheme.CUSTOM &&
                (it != AppTheme.MONET || DeviceUtil.isDynamicColorAvailable)
        }
    }
    AlertDialog(
        onDismissRequest = onDismissRequest,
        title = { Text(text = stringResource(MR.strings.custom_theme_start_from)) },
        text = {
            LazyColumn {
                items(builtIn) { appTheme ->
                    Text(
                        text = stringResource(appTheme.titleRes!!),
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onPick(appTheme) }
                            .padding(vertical = 12.dp),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismissRequest) {
                Text(text = stringResource(MR.strings.action_cancel))
            }
        },
    )
}

internal const val MAX_NAME_LENGTH = 30

private val CustomThemeSaver = Saver<CustomTheme, String>(
    save = { Json.encodeToString(it) },
    restore = { Json.decodeFromString<CustomTheme>(it) },
)
