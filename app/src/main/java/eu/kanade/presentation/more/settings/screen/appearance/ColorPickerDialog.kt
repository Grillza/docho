package eu.kanade.presentation.more.settings.screen.appearance

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import eu.kanade.presentation.theme.colorscheme.CustomColorScheme
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.rounded.Check
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import android.graphics.Color as AndroidColor

/**
 * Picks a colour from a set of standard ones, or from a colour wheel with brightness and
 * saturation sliders, or by hex code. If [against] is given, shows how well the colour stands
 * out from it, such as text from its background.
 */
@Composable
fun ColorPickerDialog(
    title: String,
    initial: Color,
    against: Color?,
    onDismissRequest: () -> Unit,
    onConfirm: (Color) -> Unit,
) {
    // Hue, saturation and value, kept apart so a grey keeps its hue while saturation is at 0.
    val start = remember { initial.toHsv() }
    var hue by rememberSaveable { mutableFloatStateOf(start[0]) }
    var saturation by rememberSaveable { mutableFloatStateOf(start[1]) }
    var value by rememberSaveable { mutableFloatStateOf(start[2]) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val color = hsvColor(hue, saturation, value)

    fun set(newColor: Color) {
        val hsv = newColor.toHsv()
        // Black, white and greys have no hue of their own; keep the one there was.
        if (hsv[1] > 0f && hsv[2] > 0f) hue = hsv[0]
        saturation = hsv[1]
        value = hsv[2]
    }

    AlertDialog(
        onDismissRequest = onDismissRequest,
        title = { Text(text = title) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ColorComparison(old = initial, new = color)
                SecondaryTabRow(selectedTabIndex = tab) {
                    Tab(
                        selected = tab == 0,
                        onClick = { tab = 0 },
                        text = { Text(text = stringResource(MR.strings.color_picker_standard)) },
                    )
                    Tab(
                        selected = tab == 1,
                        onClick = { tab = 1 },
                        text = { Text(text = stringResource(MR.strings.color_picker_wheel)) },
                    )
                }
                if (tab == 0) {
                    StandardColors(selected = color, onSelect = ::set)
                } else {
                    ColorWheel(
                        hue = hue,
                        saturation = saturation,
                        value = value,
                        onChange = { h, s ->
                            hue = h
                            saturation = s
                        },
                        modifier = Modifier
                            .fillMaxWidth(0.85f)
                            .align(Alignment.CenterHorizontally),
                    )
                    LabelledSlider(
                        label = stringResource(MR.strings.color_picker_brightness),
                        value = value,
                        onValueChange = { value = it },
                    )
                    LabelledSlider(
                        label = stringResource(MR.strings.color_picker_saturation),
                        value = saturation,
                        onValueChange = { saturation = it },
                    )
                }
                HexField(color = color, onColor = ::set)
                if (against != null) ContrastRating(color = color, against = against)
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(color) }) {
                Text(text = stringResource(MR.strings.action_ok))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissRequest) {
                Text(text = stringResource(MR.strings.action_cancel))
            }
        },
    )
}

/** The colour before and after, side by side. */
@Composable
private fun ColorComparison(old: Color, new: Color) {
    val behind = MaterialTheme.colorScheme.surfaceContainerHigh
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .softShadowIfBlending(listOf(old, new), behind, MaterialTheme.shapes.small)
            .clip(MaterialTheme.shapes.small),
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .height(40.dp)
                .background(old),
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .height(40.dp)
                .background(new),
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StandardColors(selected: Color, onSelect: (Color) -> Unit) {
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        maxItemsInEachRow = 6,
    ) {
        StandardPalette.forEach { swatch ->
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .colorDot(swatch, behind = MaterialTheme.colorScheme.surfaceContainerHigh)
                    .clickable { onSelect(swatch) },
                contentAlignment = Alignment.Center,
            ) {
                // A tick in black or white, whichever shows on the colour, marks the one picked.
                if (swatch.toArgb() == selected.toArgb()) {
                    Icon(
                        imageVector = MaterialSymbols.Rounded.Check,
                        contentDescription = stringResource(MR.strings.selected),
                        tint = if (swatch.luminance() > 0.5f) Color.Black else Color.White,
                    )
                }
            }
        }
    }
}

/**
 * Hue around the wheel, saturation from the middle out, drawn at [value]'s brightness. Tap or
 * drag to choose.
 */
@Composable
private fun ColorWheel(
    hue: Float,
    saturation: Float,
    value: Float,
    onChange: (hue: Float, saturation: Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    fun pick(position: Offset, width: Int) {
        val radius = width / 2f
        val dx = position.x - radius
        val dy = position.y - radius
        val angle = Math.toDegrees(atan2(dy, dx).toDouble()).toFloat()
        onChange((angle + 360f) % 360f, (hypot(dx, dy) / radius).coerceIn(0f, 1f))
    }

    Canvas(
        modifier = modifier
            .aspectRatio(1f)
            .pointerInput(Unit) { detectTapGestures { pick(it, size.width) } }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { pick(it, size.width) },
                    onDrag = { change, _ -> pick(change.position, size.width) },
                )
            },
    ) {
        val radius = size.minDimension / 2f
        // Sweep gradients go clockwise from 3 o'clock, as screen angles do, so hue matches the angle.
        drawCircle(brush = Brush.sweepGradient((0..6).map { hsvColor(it * 60f, 1f, 1f) }), radius = radius)
        drawCircle(
            brush = Brush.radialGradient(listOf(Color.White, Color.Transparent), radius = radius),
            radius = radius,
        )
        drawCircle(color = Color.Black.copy(alpha = 1f - value), radius = radius)

        val angle = Math.toRadians(hue.toDouble())
        val marker = center + Offset(
            (cos(angle) * radius * saturation).toFloat(),
            (sin(angle) * radius * saturation).toFloat(),
        )
        drawCircle(color = hsvColor(hue, saturation, value), radius = 12.dp.toPx(), center = marker)
        drawCircle(color = Color.White, radius = 12.dp.toPx(), center = marker, style = Stroke(3.dp.toPx()))
        drawCircle(color = Color.Black, radius = 13.5.dp.toPx(), center = marker, style = Stroke(1.dp.toPx()))
    }
}

@Composable
private fun LabelledSlider(label: String, value: Float, onValueChange: (Float) -> Unit) {
    Column {
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(text = label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
            Text(text = "${(value * 100).toInt()}%", style = MaterialTheme.typography.labelLarge)
        }
        Slider(value = value, onValueChange = onValueChange)
    }
}

/** The colour as #RRGGBB, which can be typed over. */
@Composable
private fun HexField(color: Color, onColor: (Color) -> Unit) {
    val hex = color.toHex()
    // What's typed is kept while it isn't a whole colour yet; otherwise this follows the colour.
    var typed by remember { mutableStateOf<String?>(null) }
    OutlinedTextField(
        value = typed ?: hex,
        onValueChange = { text ->
            val parsed = parseHex(text)
            if (parsed != null) {
                onColor(parsed)
                typed = null
            } else {
                typed = text
            }
        },
        label = { Text(text = stringResource(MR.strings.color_picker_hex)) },
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
        isError = typed != null,
        leadingIcon = {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .colorDot(color, behind = MaterialTheme.colorScheme.surfaceContainerHigh),
            )
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

/** How well [color] stands out from [against], as a ratio and in words. */
@Composable
private fun ContrastRating(color: Color, against: Color) {
    val ratio = CustomColorScheme.contrastRatio(color, against)
    val (rating, ratingColor) = when {
        ratio >= 7f -> stringResource(MR.strings.color_contrast_great) to MaterialTheme.colorScheme.primary
        ratio >= 4.5f -> stringResource(MR.strings.color_contrast_good) to MaterialTheme.colorScheme.primary
        ratio >= 3f -> stringResource(MR.strings.color_contrast_low) to MaterialTheme.colorScheme.error
        else -> stringResource(MR.strings.color_contrast_poor) to MaterialTheme.colorScheme.error
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .clip(MaterialTheme.shapes.small)
                .background(against)
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            Text(text = "Aa", color = color, style = MaterialTheme.typography.titleMedium)
        }
        Column {
            Text(
                text = stringResource(MR.strings.color_contrast, "%.1f".format(ratio)),
                style = MaterialTheme.typography.labelLarge,
            )
            Text(text = rating, style = MaterialTheme.typography.bodySmall, color = ratingColor)
        }
    }
}

/**
 * Fills a circle with [color]. When it's so close to [behind], what it sits on, that it would
 * vanish, it gets a soft shadow; a light glow on dark backgrounds, where a dark shadow wouldn't
 * show.
 */
internal fun Modifier.colorDot(color: Color, behind: Color): Modifier =
    softShadowIfBlending(listOf(color), behind, CircleShape).clip(CircleShape).background(color)

private fun Modifier.softShadowIfBlending(colors: List<Color>, behind: Color, shape: Shape): Modifier {
    if (colors.none { CustomColorScheme.contrastRatio(it, behind) < BLENDS_IN_RATIO }) return this
    val shadow = if (behind.luminance() < 0.5f) Color.White else Color.Black
    return shadow(elevation = 3.dp, shape = shape, ambientColor = shadow, spotColor = shadow)
}

/** Colours nearer each other than this are hard to tell apart side by side. */
private const val BLENDS_IN_RATIO = 1.3f

internal fun Color.toHex(): String = "#%06X".format(toArgb() and 0xFFFFFF)

private fun parseHex(text: String): Color? {
    val digits = text.trim().removePrefix("#")
    if (digits.length != 6) return null
    return digits.toIntOrNull(16)?.let { Color(0xFF000000.toInt() or it) }
}

private fun Color.toHsv(): FloatArray = FloatArray(3).also { AndroidColor.colorToHSV(toArgb(), it) }

private fun hsvColor(hue: Float, saturation: Float, value: Float) =
    Color(AndroidColor.HSVToColor(floatArrayOf(hue, saturation, value)))

/** Material's main colours, then neutrals from white to black. */
private val StandardPalette = listOf(
    0xFFF44336, 0xFFE91E63, 0xFF9C27B0, 0xFF673AB7, 0xFF3F51B5, 0xFF2196F3,
    0xFF03A9F4, 0xFF00BCD4, 0xFF009688, 0xFF4CAF50, 0xFF8BC34A, 0xFFCDDC39,
    0xFFFFEB3B, 0xFFFFC107, 0xFFFF9800, 0xFFFF5722, 0xFF795548, 0xFF607D8B,
    0xFFB71C1C, 0xFF880E4F, 0xFF4A148C, 0xFF1A237E, 0xFF0D47A1, 0xFF004D40,
    0xFFFFCDD2, 0xFFF8BBD0, 0xFFE1BEE7, 0xFFC5CAE9, 0xFFBBDEFB, 0xFFC8E6C9,
    0xFFFFFFFF, 0xFFE0E0E0, 0xFF9E9E9E, 0xFF616161, 0xFF212121, 0xFF000000,
).map { Color(it) }
