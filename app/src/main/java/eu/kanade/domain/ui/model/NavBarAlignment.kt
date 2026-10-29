package eu.kanade.domain.ui.model

import dev.icerock.moko.resources.StringResource
import tachiyomi.i18n.MR

/** Where the bottom navigation bar's tabs sit once some are hidden. */
enum class NavBarAlignment(val titleRes: StringResource) {
    START(MR.strings.nav_bar_alignment_left),
    CENTER(MR.strings.nav_bar_alignment_center),
    END(MR.strings.nav_bar_alignment_right),
}
