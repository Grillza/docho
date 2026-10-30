package eu.kanade.presentation.theme.colorscheme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import eu.kanade.domain.ui.UiPreferences
import eu.kanade.domain.ui.model.CustomTheme
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tachiyomi.core.common.preference.InMemoryPreferenceStore

class CustomColorSchemeTest {

    private val dark = CustomTheme(
        name = "Ember",
        primary = 0xFFFF5722.toInt(),
        secondary = 0xFF81A1C1.toInt(),
        tertiary = 0xFF88C0D0.toInt(),
        background = 0xFF212121.toInt(),
        surface = 0xFF2E2E2E.toInt(),
        text = 0xFFFFFFFF.toInt(),
    )

    @Test
    fun `contrast ratio runs from 1 to 21`() {
        assertEquals(21f, CustomColorScheme.contrastRatio(Color.Black, Color.White), 0.01f)
        assertEquals(1f, CustomColorScheme.contrastRatio(Color.Red, Color.Red), 0.01f)
    }

    @Test
    fun `picked colours are used as they are`() {
        val scheme = CustomColorScheme.colorScheme(dark, isAmoled = false)
        assertEquals(dark.primary, scheme.primary.toArgb())
        assertEquals(dark.background, scheme.background.toArgb())
        assertEquals(dark.surface, scheme.surfaceContainer.toArgb())
        assertEquals(dark.text, scheme.onBackground.toArgb())
    }

    @Test
    fun `text on coloured things is readable at any contrast`() {
        listOf(0f, 0.5f, 1f).forEach { contrast ->
            val scheme = CustomColorScheme.colorScheme(dark.copy(contrast = contrast), isAmoled = false)
            listOf(
                scheme.primary to scheme.onPrimary,
                scheme.secondary to scheme.onSecondary,
                scheme.secondaryContainer to scheme.onSecondaryContainer,
                scheme.tertiary to scheme.onTertiary,
            ).forEach { (background, text) ->
                assertTrue(CustomColorScheme.contrastRatio(background, text) >= 4.5f) {
                    "contrast $contrast: ${CustomColorScheme.contrastRatio(background, text)}"
                }
            }
        }
    }

    @Test
    fun `pure black only applies to dark themes`() {
        assertEquals(Color.Black, CustomColorScheme.colorScheme(dark, isAmoled = true).background)
        val light = dark.copy(background = 0xFFFAFAFA.toInt(), text = 0xFF000000.toInt())
        assertEquals(light.background, CustomColorScheme.colorScheme(light, isAmoled = true).background.toArgb())
    }

    @Test
    fun `themes are stored and read back`() {
        val preferences = UiPreferences(InMemoryPreferenceStore())
        preferences.customThemes.set(listOf(dark, dark.copy(name = "Second")))
        preferences.customThemeIndex.set(1)
        assertEquals("Second", preferences.selectedCustomTheme()?.name)
        // An index left past the end, such as after a delete, falls back to the first.
        preferences.customThemeIndex.set(4)
        assertEquals("Ember", preferences.selectedCustomTheme()?.name)
    }
}
