package eu.kanade.tachiyomi.ui.home

import androidx.compose.animation.graphics.res.animatedVectorResource
import androidx.compose.animation.graphics.res.rememberAnimatedVectorPainter
import androidx.compose.animation.graphics.vector.AnimatedImageVector
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.surfaceColorAtElevation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.fastForEach
import dev.icerock.moko.resources.StringResource
import eu.kanade.domain.ui.model.NavBarAlignment
import eu.kanade.presentation.util.Tab
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.ui.browse.BrowseTab
import eu.kanade.tachiyomi.ui.history.HistoryTab
import eu.kanade.tachiyomi.ui.library.LibraryTab
import eu.kanade.tachiyomi.ui.more.MoreTab
import eu.kanade.tachiyomi.ui.updates.UpdatesTab
import mihon.app.di.appGraph
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState

/** Every tab of the navigation bar, in order. */
internal val NavBarTabs: List<Tab> = listOf(
    LibraryTab,
    UpdatesTab,
    HistoryTab,
    BrowseTab,
    MoreTab,
)

/** The tabs the user hasn't hidden. Library and More can't be hidden. */
@Composable
internal fun visibleNavBarTabs(): List<Tab> {
    val uiPreferences = LocalContext.current.appGraph.uiPreferences
    val showUpdates by uiPreferences.showUpdatesTab.collectAsState()
    val showHistory by uiPreferences.showHistoryTab.collectAsState()
    val showBrowse by uiPreferences.showBrowseTab.collectAsState()
    return NavBarTabs.filter {
        when (it) {
            UpdatesTab -> showUpdates
            HistoryTab -> showHistory
            BrowseTab -> showBrowse
            else -> true
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
