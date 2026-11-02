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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import docho.rename.RenameChapters
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.service.ChapterRecognition
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.padding
import tachiyomi.presentation.core.i18n.stringResource
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

/** How a rename reaches past Docho, shown under the fields. */
enum class RenameReach { LOCAL_FILES, SERVER, APP_ONLY }

/**
 * Renames one chapter by its name and number, or several at once by replacing text in their names, e.g. taking
 * "Kaiju No. 8 " off every name so the 8 isn't read as the chapter number. Numbers left out are read from the new
 * names, or else kept.
 */
@Composable
fun RenameChaptersDialog(
    chapters: List<Chapter>,
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

    fun numberFor(chapter: Chapter, newName: String, typed: String?): Double {
        typed?.trim()?.takeIf { it.isNotEmpty() }?.replace(',', '.')?.toDoubleOrNull()?.let { return it }
        return ChapterRecognition.parseChapterNumber(mangaTitle, newName).takeIf { it >= 0 } ?: chapter.chapterNumber
    }

    val requests = remember(chapters, name, number, find, replace, kind) {
        if (single != null) {
            listOf(RenameChapters.Request(single, name.trim(), numberFor(single, name.trim(), number), kind))
        } else {
            chapters.map { chapter ->
                val newName = if (find.isEmpty()) chapter.name else chapter.name.replace(find, replace).trim()
                RenameChapters.Request(chapter, newName, numberFor(chapter, newName, null), kind)
            }
        }
    }
    val numberValid = single == null || number.isBlank() || number.replace(',', '.').toDoubleOrNull() != null
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
                if (single != null) {
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

private const val PREVIEW_COUNT = 8

private val numberFormat = DecimalFormat("#.###", DecimalFormatSymbols(Locale.ROOT))
