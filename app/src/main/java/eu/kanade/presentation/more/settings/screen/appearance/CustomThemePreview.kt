package eu.kanade.presentation.more.settings.screen.appearance

import androidx.compose.animation.graphics.res.animatedVectorResource
import androidx.compose.animation.graphics.res.rememberAnimatedVectorPainter
import androidx.compose.animation.graphics.vector.AnimatedImageVector
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import eu.kanade.domain.ui.model.CustomTheme
import eu.kanade.presentation.manga.components.MangaCover
import eu.kanade.presentation.more.settings.widget.PreferenceGroupHeader
import eu.kanade.presentation.more.settings.widget.SwitchPreferenceWidget
import eu.kanade.presentation.more.settings.widget.TextPreferenceWidget
import eu.kanade.presentation.theme.CustomTachiyomiTheme
import eu.kanade.tachiyomi.ui.home.NavBarTabs
import eu.kanade.tachiyomi.ui.home.navBarTabLooks
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.automirroredrounded.ArrowBack
import mihon.icons.materialsymbols.automirroredrounded.ChromeReaderMode
import mihon.icons.materialsymbols.rounded.Close
import mihon.icons.materialsymbols.rounded.CollectionsBookmark
import mihon.icons.materialsymbols.rounded.FilterList
import mihon.icons.materialsymbols.rounded.Palette
import mihon.icons.materialsymbols.rounded.Search
import mihon.icons.materialsymbols.rounded.Sync
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.Badge
import tachiyomi.presentation.core.components.BadgeGroup
import tachiyomi.presentation.core.i18n.stringResource

/** The main menu and the settings page in [theme]'s colours, full screen. */
@Composable
fun CustomThemePreviewDialog(
    theme: CustomTheme,
    onDismissRequest: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        CustomTachiyomiTheme(customTheme = theme) {
            val window = (LocalView.current.parent as? DialogWindowProvider)?.window
            val lightBars = MaterialTheme.colorScheme.background.luminance() > 0.5f
            LaunchedEffect(window, lightBars) {
                window ?: return@LaunchedEffect
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = lightBars
                    isAppearanceLightNavigationBars = lightBars
                }
            }
            var page by rememberSaveable { mutableIntStateOf(0) }
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Column(modifier = Modifier.systemBarsPadding()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(onClick = onDismissRequest) {
                            Icon(
                                imageVector = MaterialSymbols.Rounded.Close,
                                contentDescription = stringResource(MR.strings.action_close),
                            )
                        }
                        Text(
                            text = stringResource(MR.strings.custom_theme_preview_of, theme.name),
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    PrimaryTabRow(selectedTabIndex = page) {
                        Tab(
                            selected = page == 0,
                            onClick = { page = 0 },
                            text = { Text(text = stringResource(MR.strings.custom_theme_preview_main_menu)) },
                        )
                        Tab(
                            selected = page == 1,
                            onClick = { page = 1 },
                            text = { Text(text = stringResource(MR.strings.label_settings)) },
                        )
                    }
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .padding(12.dp)
                            .clip(MaterialTheme.shapes.large)
                            .background(MaterialTheme.colorScheme.background),
                    ) {
                        if (page == 0) MainMenuPreview() else SettingsPreview()
                    }
                }
            }
        }
    }
}

/** The library with its categories, covers and badges, and the navigation bar. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainMenuPreview() {
    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(text = stringResource(MR.strings.label_library)) },
            actions = {
                IconButton(onClick = {}) { Icon(MaterialSymbols.Rounded.Search, contentDescription = null) }
                IconButton(onClick = {}) { Icon(MaterialSymbols.Rounded.FilterList, contentDescription = null) }
            },
        )
        var category by remember { mutableIntStateOf(0) }
        PrimaryTabRow(selectedTabIndex = category) {
            PreviewCategories.forEachIndexed { i, name ->
                Tab(selected = category == i, onClick = { category = i }, text = { Text(text = name) })
            }
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            PreviewTitles.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { (title, unread, downloaded) ->
                        PreviewCover(title, unread, downloaded, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        NavigationBar {
            NavBarTabs.forEachIndexed { i, tab ->
                val (iconRes, titleRes) = navBarTabLooks.getValue(tab)
                val icon = AnimatedImageVector.animatedVectorResource(iconRes)
                NavigationBarItem(
                    selected = i == 0,
                    onClick = {},
                    icon = { Icon(rememberAnimatedVectorPainter(icon, atEnd = i == 0), contentDescription = null) },
                    label = { Text(text = stringResource(titleRes), maxLines = 1) },
                )
            }
        }
    }
}

@Composable
private fun PreviewCover(title: String, unread: Int, downloaded: Int, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(MangaCover.Book.ratio)
                .clip(MaterialTheme.shapes.small)
                .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        ) {
            BadgeGroup(modifier = Modifier.padding(4.dp)) {
                if (downloaded > 0) {
                    Badge(
                        text = "$downloaded",
                        color = MaterialTheme.colorScheme.tertiary,
                        textColor = MaterialTheme.colorScheme.onTertiary,
                    )
                }
                if (unread > 0) Badge(text = "$unread")
            }
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(4.dp),
        )
    }
}

/** The settings page, with the kinds of controls settings use. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsPreview() {
    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(text = stringResource(MR.strings.label_settings)) },
            navigationIcon = {
                IconButton(onClick = {
                }) { Icon(MaterialSymbols.AutoMirroredRounded.ArrowBack, contentDescription = null) }
            },
        )
        Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
            TextPreferenceWidget(
                title = stringResource(MR.strings.pref_category_appearance),
                subtitle = stringResource(MR.strings.pref_appearance_summary),
                icon = MaterialSymbols.Rounded.Palette,
                onPreferenceClick = {},
            )
            TextPreferenceWidget(
                title = stringResource(MR.strings.pref_category_library),
                subtitle = stringResource(MR.strings.pref_library_summary),
                icon = MaterialSymbols.Rounded.CollectionsBookmark,
                onPreferenceClick = {},
            )
            TextPreferenceWidget(
                title = stringResource(MR.strings.pref_category_reader),
                subtitle = stringResource(MR.strings.pref_reader_summary),
                icon = MaterialSymbols.AutoMirroredRounded.ChromeReaderMode,
                onPreferenceClick = {},
            )
            TextPreferenceWidget(
                title = stringResource(MR.strings.pref_category_sync),
                icon = MaterialSymbols.Rounded.Sync,
                onPreferenceClick = {},
            )
            PreferenceGroupHeader(title = stringResource(MR.strings.pref_category_display))
            var first by remember { mutableStateOf(true) }
            var second by remember { mutableStateOf(false) }
            SwitchPreferenceWidget(
                title = stringResource(MR.strings.pref_relative_format),
                checked = first,
                onCheckedChanged = { first = it },
            )
            SwitchPreferenceWidget(
                title = stringResource(MR.strings.pref_display_images_description),
                checked = second,
                onCheckedChanged = { second = it },
            )
            var slider by remember { mutableFloatStateOf(0.6f) }
            Row(
                modifier = Modifier.padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(MR.strings.color_picker_brightness),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Slider(value = slider, onValueChange = { slider = it }, modifier = Modifier.padding(start = 16.dp))
            }
            var checked by remember { mutableStateOf(true) }
            Row(
                modifier = Modifier.padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(checked = checked, onCheckedChange = { checked = it })
                Text(text = stringResource(MR.strings.custom_theme_preview_checkbox))
            }
            Row(
                modifier = Modifier.padding(16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(onClick = {}) { Text(text = stringResource(MR.strings.action_save)) }
                OutlinedButton(onClick = {}) { Text(text = stringResource(MR.strings.action_cancel)) }
            }
        }
    }
}

private val PreviewCategories = listOf("Reading", "Plan to read", "Finished")

/** Title, unread chapters and downloaded chapters of each sample cover. */
private val PreviewTitles = listOf(
    Triple("The Quiet Harbour", 3, 2),
    Triple("Paper Lanterns", 12, 0),
    Triple("Northbound", 0, 5),
    Triple("A Year of Rain", 1, 1),
    Triple("Clockwork Garden", 0, 0),
    Triple("Second Summer", 7, 0),
)
