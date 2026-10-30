package eu.kanade.tachiyomi.ui.home

import androidx.compose.animation.graphics.res.animatedVectorResource
import androidx.compose.animation.graphics.res.rememberAnimatedVectorPainter
import androidx.compose.animation.graphics.vector.AnimatedImageVector
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.surfaceColorAtElevation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.fastForEach
import dev.icerock.moko.resources.StringResource
import eu.kanade.domain.ui.UiPreferences
import eu.kanade.domain.ui.model.NavBarAlignment
import eu.kanade.presentation.util.Tab
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.ui.browse.BrowseTab
import eu.kanade.tachiyomi.ui.history.HistoryTab
import eu.kanade.tachiyomi.ui.library.LibraryTab
import eu.kanade.tachiyomi.ui.more.MoreTab
import eu.kanade.tachiyomi.ui.updates.UpdatesTab
import mihon.app.di.appGraph
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.rounded.DragHandle
import mihon.icons.materialsymbols.rounded.Keep
import mihon.icons.materialsymbols.rounded.Visibility
import mihon.icons.materialsymbols.rounded.VisibilityOff
import sh.calvin.reorderable.ReorderableColumn
import tachiyomi.core.common.preference.Preference
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/** Every tab of the navigation bar, in the usual order. */
internal val NavBarTabs: List<Tab> = listOf(
    LibraryTab,
    UpdatesTab,
    HistoryTab,
    BrowseTab,
    MoreTab,
)

/** Each tab's key in [UiPreferences.navBarOrder], the same names the iOS app keeps. */
private val navBarTabKeys: Map<Tab, String> = mapOf(
    LibraryTab to "library",
    UpdatesTab to "updates",
    HistoryTab to "history",
    BrowseTab to "browse",
    MoreTab to "more",
)

/** Every tab in the order the user chose; tabs the saved order doesn't name follow in the usual order. */
internal fun orderedNavBarTabs(order: String): List<Tab> {
    val chosen = order.split(',').mapNotNull { key -> NavBarTabs.firstOrNull { navBarTabKeys[it] == key } }.distinct()
    return chosen + NavBarTabs.filterNot { it in chosen }
}

internal fun navBarOrderOf(tabs: List<Tab>): String = tabs.joinToString(",") { navBarTabKeys.getValue(it) }

/** The preference that shows or hides [tab], or `null` for Library and More, which always show. */
internal fun UiPreferences.navBarTabShown(tab: Tab): Preference<Boolean>? = when (tab) {
    UpdatesTab -> showUpdatesTab
    HistoryTab -> showHistoryTab
    BrowseTab -> showBrowseTab
    else -> null
}

/** The tabs the user hasn't hidden, in their chosen order. Library and More can't be hidden. */
@Composable
internal fun visibleNavBarTabs(): List<Tab> {
    val uiPreferences = LocalContext.current.appGraph.uiPreferences
    val order by uiPreferences.navBarOrder.collectAsState()
    val showUpdates by uiPreferences.showUpdatesTab.collectAsState()
    val showHistory by uiPreferences.showHistoryTab.collectAsState()
    val showBrowse by uiPreferences.showBrowseTab.collectAsState()
    return orderedNavBarTabs(order).filter {
        when (it) {
            UpdatesTab -> showUpdates
            HistoryTab -> showHistory
            BrowseTab -> showBrowse
            else -> true
        }
    }
}

/**
 * The tabs as a list to arrange the bar with: drag a tab by its handle to move it, and tap the
 * eye to show or hide it. Library and More show a pin instead, since they can't be hidden.
 */
@Composable
fun NavBarTabsEditor(modifier: Modifier = Modifier) {
    val uiPreferences = LocalContext.current.appGraph.uiPreferences
    val order by uiPreferences.navBarOrder.collectAsState()
    val showUpdates by uiPreferences.showUpdatesTab.collectAsState()
    val showHistory by uiPreferences.showHistoryTab.collectAsState()
    val showBrowse by uiPreferences.showBrowseTab.collectAsState()
    val tabs = orderedNavBarTabs(order)
    val haptic = LocalHapticFeedback.current

    ReorderableColumn(
        list = tabs,
        onSettle = { from, to ->
            val moved = tabs.toMutableList().apply { add(to, removeAt(from)) }
            uiPreferences.navBarOrder.set(navBarOrderOf(moved))
        },
        onMove = { haptic.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick) },
        modifier = modifier,
    ) { _, tab, _ ->
        key(tab) {
            ReorderableItem {
                val (iconRes, titleRes) = navBarTabLooks.getValue(tab)
                val title = stringResource(titleRes)
                val shownPreference = uiPreferences.navBarTabShown(tab)
                val shown = when (tab) {
                    UpdatesTab -> showUpdates
                    HistoryTab -> showHistory
                    BrowseTab -> showBrowse
                    else -> true
                }
                val contentAlpha = if (shown) 1f else 0.6f
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .padding(start = 16.dp, end = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = MaterialSymbols.Rounded.DragHandle,
                        contentDescription = stringResource(MR.strings.nav_bar_tab_reorder, title),
                        modifier = Modifier.draggableHandle(
                            onDragStarted = {
                                haptic.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
                            },
                            onDragStopped = { haptic.performHapticFeedback(HapticFeedbackType.GestureEnd) },
                        ),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Icon(
                        painter = rememberAnimatedVectorPainter(
                            AnimatedImageVector.animatedVectorResource(iconRes),
                            atEnd = false,
                        ),
                        contentDescription = null,
                        modifier = Modifier
                            .padding(start = 16.dp)
                            .alpha(contentAlpha),
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    Text(
                        text = title,
                        modifier = Modifier
                            .weight(1f)
                            .padding(horizontal = 16.dp)
                            .alpha(contentAlpha),
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (shownPreference != null) {
                        IconButton(onClick = { shownPreference.set(!shown) }) {
                            Icon(
                                imageVector = if (shown) {
                                    MaterialSymbols.Rounded.Visibility
                                } else {
                                    MaterialSymbols.Rounded.VisibilityOff
                                },
                                contentDescription = stringResource(
                                    if (shown) MR.strings.nav_bar_tab_hide else MR.strings.nav_bar_tab_show,
                                    title,
                                ),
                                tint = if (shown) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                            )
                        }
                    } else {
                        Box(modifier = Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = MaterialSymbols.Rounded.Keep,
                                contentDescription = stringResource(MR.strings.nav_bar_tab_always_shown),
                                modifier = Modifier.size(20.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Places the bar's tabs at the width they have when all are shown, left, centred or right as
 * [alignment] says. A plain Layout, since the navigation bar asks its children for intrinsic
 * sizes, which subcomposing layouts can't give.
 */
@Composable
internal fun NavBarTabsLayout(
    alignment: NavBarAlignment,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Layout(content = content, modifier = modifier.fillMaxWidth()) { measurables, constraints ->
        val tabWidth = if (constraints.hasBoundedWidth) {
            constraints.maxWidth / NavBarTabs.size
        } else {
            measurables.maxOfOrNull { it.maxIntrinsicWidth(constraints.maxHeight) } ?: 0
        }
        val placeables = measurables.map {
            it.measure(constraints.copy(minWidth = tabWidth, maxWidth = tabWidth, minHeight = 0))
        }
        val usedWidth = tabWidth * placeables.size
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else usedWidth
        val height = maxOf(constraints.minHeight, placeables.maxOfOrNull { it.height } ?: 0)
        val startX = when (alignment) {
            NavBarAlignment.START -> 0
            NavBarAlignment.CENTER -> (width - usedWidth) / 2
            NavBarAlignment.END -> width - usedWidth
        }
        layout(width, height) {
            // placeRelative mirrors this for right-to-left languages.
            placeables.forEachIndexed { i, placeable ->
                placeable.placeRelative(startX + i * tabWidth, (height - placeable.height) / 2)
            }
        }
    }
}

/** A small copy of the navigation bar as the current settings would show it. */
@Composable
fun NavBarPreview(modifier: Modifier = Modifier) {
    val alignment by LocalContext.current.appGraph.uiPreferences.navBarAlignment.collectAsState()
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceColorAtElevation(3.dp),
    ) {
        NavBarTabsLayout(alignment = alignment, modifier = Modifier.padding(vertical = 12.dp)) {
            visibleNavBarTabs().fastForEach { tab ->
                // Keyed, so each tab keeps its own icon as others are shown or hidden.
                key(tab) {
                    // Tabs' own options need the tab navigator, which settings don't have.
                    val (iconRes, titleRes) = navBarTabLooks.getValue(tab)
                    val icon = AnimatedImageVector.animatedVectorResource(iconRes)
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Icon(painter = rememberAnimatedVectorPainter(icon, atEnd = false), contentDescription = null)
                        Text(
                            text = stringResource(titleRes),
                            style = MaterialTheme.typography.labelSmall,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

/** Each tab's icon and name, for drawing the bar where the tabs themselves can't be asked. */
internal val navBarTabLooks: Map<Tab, Pair<Int, StringResource>> = mapOf(
    LibraryTab to (R.drawable.animated_library to MR.strings.label_library),
    UpdatesTab to (R.drawable.animated_updates to MR.strings.label_recent_updates),
    HistoryTab to (R.drawable.animated_history to MR.strings.label_recent_manga),
    BrowseTab to (R.drawable.animated_browse_enter to MR.strings.browse),
    MoreTab to (R.drawable.animated_more_enter to MR.strings.label_more),
)
