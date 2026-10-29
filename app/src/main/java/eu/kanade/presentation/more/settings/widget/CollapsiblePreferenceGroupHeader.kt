package eu.kanade.presentation.more.settings.widget

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.rounded.ExpandMore
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.secondaryItemAlpha

/** The header of a collapsible preference group; tapping it folds or unfolds the group. */
@Composable
fun CollapsiblePreferenceGroupHeader(
    title: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    icon: Painter? = null,
    summary: String? = null,
    summaryWidget: @Composable (() -> Unit)? = null,
) {
    val chevronRotation by animateFloatAsState(if (expanded) 180f else 0f, label = "chevron")
    val state = stringResource(if (expanded) MR.strings.action_expanded else MR.strings.action_collapsed)
    // Once unfolded, the group's own items show the summary in full.
    val showSummary = !expanded
    BasePreferenceWidget(
        modifier = Modifier.semantics { stateDescription = state },
        title = title,
        subcomponent = if (showSummary && !summary.isNullOrBlank()) {
            {
                Text(
                    text = summary,
                    modifier = Modifier
                        .padding(horizontal = PrefsHorizontalPadding)
                        .secondaryItemAlpha(),
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 2,
                )
            }
        } else {
            null
        },
        icon = icon?.let {
            {
                Image(
                    painter = it,
                    contentDescription = null,
                    modifier = Modifier
                        .size(36.dp)
                        .clip(MaterialTheme.shapes.small),
                )
            }
        },
        onClick = onToggle,
        widget = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (showSummary) summaryWidget?.invoke()
                Icon(
                    imageVector = MaterialSymbols.Rounded.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.rotate(chevronRotation),
                )
            }
        },
    )
}
