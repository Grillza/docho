package eu.kanade.presentation.theme.colorscheme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import eu.kanade.domain.ui.model.CustomTheme

/**
 * A [CustomTheme] as a full colour scheme. The colours the user picked are used as they are;
 * the rest are mixed from them. The theme is dark or light by its background, whatever the
 * app's light/dark setting, since the user chose that background.
 */
internal class CustomColorScheme(theme: CustomTheme) : BaseColorScheme() {

    val isDark = Color(theme.background).isDark()

    private val scheme = build(theme, isDark)

    override val darkScheme = scheme
    override val lightScheme = scheme

    companion object {
        /** The scheme for [theme], with pure black backgrounds if [isAmoled] and it's dark. */
        fun colorScheme(theme: CustomTheme, isAmoled: Boolean): ColorScheme {
            val custom = CustomColorScheme(theme)
            return custom.getColorScheme(
                isDark = custom.isDark,
                isAmoled = isAmoled,
                overrideDarkSurfaceContainers = true,
            )
        }

        /** A custom theme with [colorScheme]'s colours, to start editing from. */
        fun from(colorScheme: ColorScheme, name: String) = CustomTheme(
            name = name,
            primary = colorScheme.primary.toArgb(),
            secondary = colorScheme.secondary.toArgb(),
            tertiary = colorScheme.tertiary.toArgb(),
            background = colorScheme.background.toArgb(),
            surface = colorScheme.surfaceContainer.toArgb(),
            text = colorScheme.onBackground.toArgb(),
        )

        /** WCAG contrast ratio of two colours, from 1 (the same) to 21 (black on white). */
        fun contrastRatio(a: Color, b: Color): Float {
            val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
            return (light + 0.05f) / (dark + 0.05f)
        }

        private fun build(theme: CustomTheme, isDark: Boolean): ColorScheme {
            val contrast = theme.contrast.coerceIn(0f, 1f)
            val primary = Color(theme.primary)
            val secondary = Color(theme.secondary)
            val tertiary = Color(theme.tertiary)
            val background = Color(theme.background)
            val surface = Color(theme.surface)
            val text = Color(theme.text)

            // Text on a colour: its best of black or white, tinted by the colour less as contrast rises.
            fun on(color: Color) = lerp(color, color.bestText(), 0.8f + 0.2f * contrast)

            // Containers sit between a colour and the background, nearer the colour as contrast rises.
            fun container(color: Color) = lerp(color, background, 0.6f - 0.3f * contrast)

            // Surfaces a step further from the background than the bars, for raised things.
            fun raised(step: Float) = lerp(surface, text, step * (0.5f + contrast))

            val error = if (isDark) Color(0xFFFFB4AB) else Color(0xFFBA1A1A)
            val errorContainer = container(error)
            val base = if (isDark) darkColorScheme() else lightColorScheme()

            return base.copy(
                primary = primary,
                onPrimary = on(primary),
                primaryContainer = container(primary),
                onPrimaryContainer = on(container(primary)),
                inversePrimary = lerp(primary, background, 0.5f),
                secondary = secondary,
                onSecondary = on(secondary),
                secondaryContainer = container(secondary),
                onSecondaryContainer = on(container(secondary)),
                tertiary = tertiary,
                onTertiary = on(tertiary),
                tertiaryContainer = container(tertiary),
                onTertiaryContainer = on(container(tertiary)),
                background = background,
                onBackground = text,
                surface = background,
                onSurface = text,
                surfaceVariant = surface,
                onSurfaceVariant = lerp(text, background, 0.3f - 0.25f * contrast),
                surfaceTint = primary,
                inverseSurface = text,
                inverseOnSurface = background,
                error = error,
                onError = on(error),
                errorContainer = errorContainer,
                onErrorContainer = on(errorContainer),
                outline = lerp(text, background, 0.55f - 0.3f * contrast),
                outlineVariant = lerp(text, background, 0.8f - 0.2f * contrast),
                surfaceBright = raised(0.12f),
                surfaceDim = lerp(background, surface, 0.25f),
                surfaceContainerLowest = lerp(background, surface, 0.25f),
                surfaceContainerLow = lerp(background, surface, 0.6f),
                surfaceContainer = surface,
                surfaceContainerHigh = raised(0.06f),
                surfaceContainerHighest = raised(0.12f),
            )
        }

        private fun Color.isDark() = contrastRatio(this, Color.White) > contrastRatio(this, Color.Black)

        private fun Color.bestText() = if (isDark()) Color.White else Color.Black
    }
}
