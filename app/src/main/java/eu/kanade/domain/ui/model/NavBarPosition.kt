package eu.kanade.domain.ui.model

import dev.icerock.moko.resources.StringResource
import tachiyomi.i18n.MR

/** Where the navigation bar sits in the tablet layout: a rail down the left, or a bar along the bottom. */
enum class NavBarPosition(val titleRes: StringResource) {
    LEFT(MR.strings.nav_bar_position_left),
    BOTTOM(MR.strings.nav_bar_position_bottom),
}
