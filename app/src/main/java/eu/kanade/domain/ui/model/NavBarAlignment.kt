package eu.kanade.domain.ui.model

import dev.icerock.moko.resources.StringResource
import tachiyomi.i18n.MR

/** Where the navigation bar's tabs sit: along a bottom bar once some are hidden, or down the side rail. */
enum class NavBarAlignment(val titleRes: StringResource, val railTitleRes: StringResource) {
    START(MR.strings.nav_bar_alignment_left, MR.strings.nav_bar_alignment_top),
    CENTER(MR.strings.nav_bar_alignment_center, MR.strings.nav_bar_alignment_center),
    END(MR.strings.nav_bar_alignment_right, MR.strings.nav_bar_alignment_bottom),
}
