package eu.kanade.presentation.manga.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExposedDropdownMenu
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import docho.rename.RenameChapters
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.service.ChapterRecognition
import tachiyomi.domain.chapter.service.RenameLike
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.padding
import tachiyomi.presentation.core.i18n.stringResource
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

/** How a rename reaches past Docho, shown under the fields. */
enum class RenameReach { LOCAL_FILES, SERVER, APP_ONLY }

/** How the dialog renames: by name and number (one chapter), find and replace (several), or like another chapter. */
private enum class RenameMode { NAME, FIND, LIKE }

/**
 * Renames one chapter by its name and number, or several at once by replacing text in their names, e.g. taking
 * "Kaiju No. 8 " off every name so the 8 isn't read as the chapter number. Numbers left out are read from the new
 * names, or else kept. Either can also be renamed like one of [examples], see [RenameLike].
 */
@Composable
fun RenameChaptersDialog(
    chapters: List<Chapter>,
    examples: List<RenameChapters.Example>,
    mangaTitle: String,
    sourceName: String,
    reach: RenameReach,
    onDismissRequest: () -> Unit,
    onConfirm: (List<RenameChapters.Request>) -> Unit,
) {
    val single = chapters.singleOrNull()
    var name by rememberSaveable { mutableStateOf(single?.name.orEmpty()) }
    var number by rememberSaveable {
        mutableStateOf(single?.chapterNumber?.takeIf { it >= 0 }?.let(numberFormat::format).orEmpty())
    }
    // Whether the chapters are volumes or chapters; null keeps each as it is
    var kind by rememberSaveable {
        mutableStateOf(single?.let { if (it.isVolume) Chapter.KIND_VOLUME else Chapter.KIND_CHAPTER })
    }
    var find by rememberSaveable { mutableStateOf("") }
    var replace by rememberSaveable { mutableStateOf("") }
    var mode by rememberSaveable { mutableStateOf(if (single != null) RenameMode.NAME else RenameMode.FIND) }
    var exampleId by rememberSaveable { mutableStateOf(examples.firstOrNull()?.chapter?.id) }
    val example = examples.find { it.chapter.id == exampleId }
    val style = remember(example) {
        example?.let {
            RenameLike.learn(it.original, it.chapter.name, mangaTitle, it.chapter.isVolume)
        }
    }

    fun pickExample(chosen: RenameChapters.Example) {
        exampleId = chosen.chapter.id
        kind = if (chosen.chapter.isVolume) Chapter.KIND_VOLUME else Chapter.KIND_CHAPTER
    }

    fun numberFor(chapter: Chapter, newName: String, typed: String?): Double {
        typed?.trim()?.takeIf { it.isNotEmpty() }?.replace(',', '.')?.toDoubleOrNull()?.let { return it }
        return ChapterRecognition.parseChapterNumber(mangaTitle, newName).takeIf { it >= 0 } ?: chapter.chapterNumber
    }

    // Chapters renamed like the example, or null for those whose names don't say the number its style needs
    val liked = remember(chapters, style) {
        chapters.map { chapter -> style?.let { RenameLike.apply(it, chapter.name, mangaTitle) } }
    }
    val requests = remember(chapters, name, number, find, replace, kind, mode, liked) {
        if (mode == RenameMode.LIKE) {
            chapters.zip(liked) { chapter, renamed ->
                if (renamed == null) {
                    RenameChapters.Request(chapter, chapter.name, chapter.chapterNumber)
                } else {
                    RenameChapters.Request(chapter, renamed.name, renamed.number, kind)
                }
            }
        } else if (single != null) {
            listOf(RenameChapters.Request(single, name.trim(), numberFor(single, name.trim(), number), kind))
        } else {
            chapters.map { chapter ->
                val newName = if (find.isEmpty()) chapter.name else chapter.name.replace(find, replace).trim()
                RenameChapters.Request(chapter, newName, numberFor(chapter, newName, null), kind)
            }
        }
    }
    val numberValid =
        single == null || mode == RenameMode.LIKE || number.isBlank() ||
            number.replace(',', '.').toDoubleOrNull() != null
    val canConfirm = numberValid &&
        requests.all { it.name.isNotEmpty() } &&
        requests.any { it.changes }

    AlertDialog(
        onDismissRequest = onDismissRequest,
        title = {
            Text(
                if (single != null) {
                    stringResource(MR.strings.rename_chapter_title)
                } else {
                    stringResource(MR.strings.rename_chapters_title, chapters.size)
                },
            )
        },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                if (examples.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(MaterialTheme.padding.small)) {
                        listOf(
                            (if (single != null) RenameMode.NAME else RenameMode.FIND) to
                                (if (single != null) MR.strings.rename_mode_name else MR.strings.rename_mode_find),
                            RenameMode.LIKE to MR.strings.rename_mode_like,
                        ).forEach { (value, label) ->
                            FilterChip(
                                selected = mode == value,
                                onClick = {
                                    if (value == RenameMode.LIKE && mode != value) example?.let(::pickExample)
                                    mode = value
                                },
                                label = { Text(stringResource(label)) },
                            )
                        }
                    }
                    Spacer(Modifier.height(MaterialTheme.padding.small))
                }
                if (mode == RenameMode.LIKE) {
                    ExampleField(examples = examples, selected = example, onSelect = ::pickExample)
                    Text(
                        text = stringResource(
                            if (style == null) MR.strings.rename_like_no_style else MR.strings.rename_like_hint,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (style == null) MaterialTheme.colorScheme.error else Color.Unspecified,
                    )
                    if (style != null) {
                        Spacer(Modifier.height(MaterialTheme.padding.medium))
                        Text(
                            text = stringResource(MR.strings.rename_preview),
                            style = MaterialTheme.typography.labelLarge,
                        )
                        Column(modifier = Modifier.heightIn(max = 240.dp)) {
                            chapters.zip(liked).take(PREVIEW_COUNT).forEach { (chapter, renamed) ->
                                Text(
                                    text = renamed?.name ?: stringResource(MR.strings.rename_like_left, chapter.name),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = if (renamed == null) MaterialTheme.colorScheme.error else Color.Unspecified,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            if (chapters.size > PREVIEW_COUNT) {
                                Text(text = "…", style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                } else if (single != null) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text(stringResource(MR.strings.rename_chapter_name)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(MaterialTheme.padding.small))
                    OutlinedTextField(
                        value = number,
                        onValueChange = { number = it },
                        label = { Text(stringResource(MR.strings.rename_chapter_number)) },
                        supportingText = { Text(stringResource(MR.strings.rename_chapter_number_hint)) },
                        isError = !numberValid,
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    OutlinedTextField(
                        value = find,
                        onValueChange = { find = it },
                        label = { Text(stringResource(MR.strings.rename_find)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(MaterialTheme.padding.small))
                    OutlinedTextField(
                        value = replace,
                        onValueChange = { replace = it },
                        label = { Text(stringResource(MR.strings.rename_replace)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(MaterialTheme.padding.medium))
                    Text(
                        text = stringResource(MR.strings.rename_preview),
                        style = MaterialTheme.typography.labelLarge,
                    )
                    Column(modifier = Modifier.heightIn(max = 240.dp)) {
                        requests.take(PREVIEW_COUNT).forEach { request ->
                            val shownNumber = request.number.takeIf { it >= 0 }?.let { "${numberFormat.format(it)} · " }
                            Text(
                                text = shownNumber.orEmpty() + request.name,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (requests.size > PREVIEW_COUNT) {
                            Text(text = "…", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                Spacer(Modifier.height(MaterialTheme.padding.medium))
                Text(
                    text = stringResource(MR.strings.rename_kind),
                    style = MaterialTheme.typography.labelLarge,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(MaterialTheme.padding.small)) {
                    buildList {
                        if (single == null) add(null to MR.strings.rename_kind_keep)
                        add(Chapter.KIND_VOLUME to MR.strings.rename_kind_volume)
                        add(Chapter.KIND_CHAPTER to MR.strings.rename_kind_chapter)
                    }.forEach { (value, label) ->
                        FilterChip(
                            selected = kind == value,
                            onClick = { kind = value },
                            label = { Text(stringResource(label)) },
                        )
                    }
                }
                Text(
                    text = stringResource(MR.strings.rename_kind_hint),
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.height(MaterialTheme.padding.medium))
                Text(
                    text = when (reach) {
                        RenameReach.LOCAL_FILES -> stringResource(MR.strings.rename_local_note)
                        RenameReach.SERVER -> stringResource(MR.strings.rename_server_note, sourceName)
                        RenameReach.APP_ONLY -> stringResource(MR.strings.rename_app_only_note)
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissRequest) {
                Text(stringResource(MR.strings.action_cancel))
            }
        },
        confirmButton = {
            TextButton(
                enabled = canConfirm,
                onClick = {
                    onDismissRequest()
                    onConfirm(requests)
                },
            ) {
                Text(stringResource(MR.strings.action_rename))
            }
        },
    )
}

/** Picks the chapter to rename like, showing what it was called before it was renamed. */
@Composable
private fun ExampleField(
    examples: List<RenameChapters.Example>,
    selected: RenameChapters.Example?,
    onSelect: (RenameChapters.Example) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selected?.chapter?.name.orEmpty(),
            onValueChange = {},
            readOnly = true,
            singleLine = true,
            label = { Text(stringResource(MR.strings.rename_like_example)) },
            supportingText = selected?.original?.let { { Text(stringResource(MR.strings.rename_like_was, it)) } },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                .fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            examples.forEach { example ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(example.chapter.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            example.original?.let {
                                Text(
                                    text = stringResource(MR.strings.rename_like_was, it),
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    },
                    onClick = {
                        expanded = false
                        onSelect(example)
                    },
                )
            }
        }
    }
}

private const val PREVIEW_COUNT = 8

private val numberFormat = DecimalFormat("#.###", DecimalFormatSymbols(Locale.ROOT))
