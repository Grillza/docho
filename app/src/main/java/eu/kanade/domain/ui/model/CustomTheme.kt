package eu.kanade.domain.ui.model

import kotlinx.serialization.Serializable

/**
 * A colour theme the user made. Colours are ARGB. The rest of the app's colours (text on
 * buttons, containers, outlines and so on) are worked out from these, more or less strongly
 * apart as [contrast] (0 to 1) says.
 */
@Serializable
data class CustomTheme(
    val name: String,
    val primary: Int,
    val secondary: Int,
    val tertiary: Int,
    val background: Int,
    val surface: Int,
    val text: Int,
    val contrast: Float = 0.5f,
) {
    companion object {
        /** How many custom themes can be kept. */
        const val MAX = 5
    }
}
