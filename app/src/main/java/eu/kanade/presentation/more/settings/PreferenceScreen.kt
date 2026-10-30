package eu.kanade.presentation.more.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.fastForEachIndexed
import eu.kanade.presentation.more.settings.screen.SearchableSettings
import eu.kanade.presentation.more.settings.widget.CollapsiblePreferenceGroupHeader
import eu.kanade.presentation.more.settings.widget.PreferenceGroupHeader
import kotlinx.coroutines.delay
import tachiyomi.presentation.core.components.ScrollbarLazyColumn
import kotlin.time.Duration.Companion.seconds

/**
 * Preference Screen composable which contains a list of [Preference] items
 * @param items [Preference] items which should be displayed on the preference screen. An item can be a single [PreferenceItem] or a group ([Preference.PreferenceGroup])
 * @param modifier [Modifier] to be applied to the preferenceScreen layout
 */
@Composable
fun PreferenceScreen(
    items: List<Preference>,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(0.dp),
) {
    val state = rememberLazyListState()
    val highlightKey = SearchableSettings.highlightKey
    // Titles of the collapsible groups that are unfolded.
    val expandedGroups = rememberSaveable(
        saver = listSaver(save = { it.toList() }, restore = { it.toMutableStateList() }),
    ) { mutableStateListOf<String>() }
    if (highlightKey != null) {
        LaunchedEffect(Unit) {
            // A search result inside a folded group unfolds it.
            items.firstOrNull { group ->
                group is Preference.PreferenceGroup &&
                    group.collapsible &&
                    group.preferenceItems.any { it.title == highlightKey }
            }?.let { if (it.title !in expandedGroups) expandedGroups.add(it.title) }
            val i = items.findHighlightedIndex(highlightKey, expandedGroups)
            if (i >= 0) {
                delay(0.5.seconds)
                state.animateScrollToItem(i)
            }
            SearchableSettings.highlightKey = null
        }
    }

    ScrollbarLazyColumn(
        modifier = modifier,
        state = state,
        contentPadding = contentPadding,
    ) {
        items.fastForEachIndexed { i, preference ->
            when (preference) {
                // Create Preference Group
                is Preference.PreferenceGroup -> {
                    if (!preference.visible) return@fastForEachIndexed

                    val expanded = !preference.collapsible || preference.title in expandedGroups
                    item {
                        Column {
                            if (preference.collapsible) {
                                CollapsiblePreferenceGroupHeader(
                                    title = preference.title,
                                    expanded = expanded,
                                    onToggle = {
                                        if (expanded) {
                                            expandedGroups.remove(preference.title)
                                        } else {
                                            expandedGroups.add(preference.title)
                                        }
                                    },
                                    icon = preference.icon,
                                    summary = preference.summary,
                                    summaryWidget = preference.summaryWidget,
                                )
                            } else {
                                PreferenceGroupHeader(
                                    title = preference.title,
                                    highlighted = preference.title == highlightKey,
                                )
                            }
                        }
                    }
                    if (expanded) {
                        items(preference.preferenceItems) { item ->
                            PreferenceItem(
                                item = item,
                                highlightKey = highlightKey,
                            )
                        }
                    }
                    item {
                        // Folded groups sit together like a list.
                        if (expanded && i < items.lastIndex) {
                            Spacer(modifier = Modifier.height(12.dp))
                        }
                    }
                }

                // Create Preference Item
                is Preference.PreferenceItem<*, *> -> item {
                    PreferenceItem(
                        item = preference,
                        highlightKey = highlightKey,
                    )
                }
            }
        }
    }
}

private fun List<Preference>.findHighlightedIndex(highlightKey: String, expandedGroups: List<String>): Int {
    return flatMap {
        if (it is Preference.PreferenceGroup) {
            if (!it.visible) return@flatMap emptyList()
            buildList<String?> {
                add(it.title) // Header
                if (!it.collapsible || it.title in expandedGroups) {
                    addAll(it.preferenceItems.map { groupItem -> groupItem.title })
                }
                add(null) // Spacer
            }
        } else {
            listOf(it.title)
        }
    }.indexOfFirst { it == highlightKey }
}
