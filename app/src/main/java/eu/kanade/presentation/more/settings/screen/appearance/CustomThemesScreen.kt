package eu.kanade.presentation.more.settings.screen.appearance

import android.app.Activity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import eu.kanade.domain.ui.model.AppTheme
import eu.kanade.domain.ui.model.CustomTheme
import eu.kanade.presentation.components.AppBar
import eu.kanade.presentation.components.DropdownMenu
import eu.kanade.presentation.util.Screen
import mihon.app.di.appGraph
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.rounded.Add
import mihon.icons.materialsymbols.rounded.MoreVert
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.Scaffold
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/**
 * The user's own themes, up to [CustomTheme.MAX]. Tapping one uses it; each can be edited,
 * renamed or deleted, and new ones made while there's room.
 */
class CustomThemesScreen : Screen() {

    @Composable
    override fun Content() {
        val context = LocalContext.current
        val navigator = LocalNavigator.currentOrThrow
        val uiPreferences = remember { context.appGraph.uiPreferences }
        val themes by uiPreferences.customThemes.collectAsState()
        val appTheme by uiPreferences.appTheme.collectAsState()
        val selected by uiPreferences.customThemeIndex.collectAsState()
        var renaming by rememberSaveable { mutableStateOf<Int?>(null) }
        var deleting by rememberSaveable { mutableStateOf<Int?>(null) }

        fun recreate() = (context as? Activity)?.let { ActivityCompat.recreate(it) }

        fun use(index: Int) {
            if (appTheme == AppTheme.CUSTOM && selected == index) return
            uiPreferences.customThemeIndex.set(index)
            uiPreferences.appTheme.set(AppTheme.CUSTOM)
            recreate()
        }

        Scaffold(
            topBar = { scrollBehavior ->
                AppBar(
                    title = stringResource(MR.strings.custom_themes),
                    navigateUp = navigator::pop,
                    scrollBehavior = scrollBehavior,
                )
            },
            floatingActionButton = {
                if (themes.size < CustomTheme.MAX) {
                    ExtendedFloatingActionButton(
                        text = { Text(text = stringResource(MR.strings.custom_theme_new)) },
                        icon = { Icon(imageVector = MaterialSymbols.Rounded.Add, contentDescription = null) },
                        onClick = { navigator.push(CustomThemeEditorScreen(index = null)) },
                    )
                }
            },
        ) { contentPadding ->
            LazyColumn(contentPadding = contentPadding) {
                item {
                    Text(
                        text = when {
                            themes.isEmpty() -> stringResource(MR.strings.custom_themes_empty, CustomTheme.MAX)
                            themes.size >= CustomTheme.MAX -> stringResource(
                                MR.strings.custom_themes_full,
                                CustomTheme.MAX,
                            )
                            else -> stringResource(MR.strings.custom_themes_info, CustomTheme.MAX)
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
                itemsIndexed(themes) { index, theme ->
                    val inUse = appTheme == AppTheme.CUSTOM && selected == index
                    ListItem(
                        modifier = Modifier.clickable { use(index) },
                        leadingContent = { RadioButton(selected = inUse, onClick = { use(index) }) },
                        headlineContent = { Text(text = theme.name) },
                        supportingContent = { ThemeSwatches(theme) },
                        trailingContent = {
                            ThemeMenu(
                                onEdit = { navigator.push(CustomThemeEditorScreen(index)) },
                                onRename = { renaming = index },
                                onDelete = { deleting = index },
                            )
                        },
                    )
                }
            }
        }

        renaming?.let { index ->
            val theme = themes.getOrNull(index) ?: return@let
            RenameDialog(
                name = theme.name,
                onDismissRequest = { renaming = null },
                onRename = { name ->
                    uiPreferences.customThemes.set(themes.toMutableList().also { it[index] = theme.copy(name = name) })
                    renaming = null
                },
            )
        }
        deleting?.let { index ->
            val theme = themes.getOrNull(index) ?: return@let
            AlertDialog(
                onDismissRequest = { deleting = null },
                title = { Text(text = stringResource(MR.strings.custom_theme_delete_title, theme.name)) },
                text = { Text(text = stringResource(MR.strings.custom_theme_delete_text)) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            deleting = null
                            val wasInUse = appTheme == AppTheme.CUSTOM && selected == index
                            val remaining = themes.toMutableList().also { it.removeAt(index) }
                            uiPreferences.customThemes.set(remaining)
                            // Keep pointing at the same theme as the ones after it move up.
                            if (selected > index) uiPreferences.customThemeIndex.set(selected - 1)
                            if (wasInUse) {
                                uiPreferences.customThemeIndex.set(0)
                                if (remaining.isEmpty()) uiPreferences.appTheme.set(AppTheme.DEFAULT)
                                recreate()
                            }
                        },
                    ) {
                        Text(text = stringResource(MR.strings.action_delete))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { deleting = null }) {
                        Text(text = stringResource(MR.strings.action_cancel))
                    }
                },
            )
        }
    }
}

/** A dot of each colour [theme] picks. */
@Composable
private fun ThemeSwatches(theme: CustomTheme) {
    Row(
        modifier = Modifier.padding(top = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        val behind = MaterialTheme.colorScheme.background
        listOf(theme.primary, theme.secondary, theme.tertiary, theme.background, theme.surface, theme.text)
            .forEach {
                Box(
                    modifier = Modifier
                        .size(20.dp)
                        .colorDot(Color(it), behind),
                )
            }
    }
}

@Composable
private fun ThemeMenu(onEdit: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(
                imageVector = MaterialSymbols.Rounded.MoreVert,
                contentDescription = stringResource(MR.strings.action_menu_overflow_description),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            listOf(
                MR.strings.action_edit to onEdit,
                MR.strings.action_rename to onRename,
                MR.strings.action_delete to onDelete,
            ).forEach { (label, action) ->
                DropdownMenuItem(
                    text = { Text(text = stringResource(label)) },
                    onClick = {
                        expanded = false
                        action()
                    },
                )
            }
        }
    }
}

@Composable
private fun RenameDialog(name: String, onDismissRequest: () -> Unit, onRename: (String) -> Unit) {
    // Opens with the old name selected, so typing replaces it.
    var text by remember { mutableStateOf(TextFieldValue(name, selection = TextRange(0, name.length))) }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }
    AlertDialog(
        onDismissRequest = onDismissRequest,
        title = { Text(text = stringResource(MR.strings.action_rename)) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it.copy(text = it.text.take(MAX_NAME_LENGTH)) },
                label = { Text(text = stringResource(MR.strings.custom_theme_name)) },
                singleLine = true,
                modifier = Modifier.focusRequester(focusRequester),
            )
        },
        confirmButton = {
            TextButton(onClick = { onRename(text.text.trim()) }, enabled = text.text.isNotBlank()) {
                Text(text = stringResource(MR.strings.action_ok))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissRequest) {
                Text(text = stringResource(MR.strings.action_cancel))
            }
        },
    )
}
