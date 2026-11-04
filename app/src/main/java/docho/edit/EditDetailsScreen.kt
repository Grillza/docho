package docho.edit

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import docho.dochosync.DochoSyncWorker
import eu.kanade.presentation.components.AppBar
import eu.kanade.presentation.components.AppBarTitle
import eu.kanade.presentation.util.Screen
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.launch
import mihon.core.metro.metroGraph
import mihon.app.di.AppGraph
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.domain.manga.model.Manga
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.Scaffold
import tachiyomi.presentation.core.i18n.stringResource

/**
 * Edits a series' title, author, artist, description, genres and status, as Kavita and Dōchō
 * Server do: an edited field is locked, so refreshing from the source keeps it ([SeriesEdits]).
 */
class EditDetailsScreen(
    private val manga: Manga,
) : Screen() {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val graph = remember { context.metroGraph<AppGraph>() }
        val edits = graph.seriesEdits
        val saved = remember { edits.get(manga.source, manga.url) ?: SeriesEdits.Details() }

        var title by rememberSaveable { mutableStateOf(manga.title) }
        var author by rememberSaveable { mutableStateOf(manga.author.orEmpty()) }
        var artist by rememberSaveable { mutableStateOf(manga.artist.orEmpty()) }
        var description by rememberSaveable { mutableStateOf(manga.description.orEmpty()) }
        var genres by rememberSaveable { mutableStateOf(manga.genre.orEmpty().joinToString(", ")) }
        var status by rememberSaveable { mutableStateOf(manga.status) }

        fun details(): SeriesEdits.Details {
            // A field is edited if it was before, or is now different from what the series has
            fun <T> pick(was: T?, now: T, current: T): T? = if (was != null || now != current) now else null
            val genreList = genres.split(",").map { it.trim() }.filter { it.isNotEmpty() }.distinct()
            return SeriesEdits.Details(
                title = pick(saved.title, title.trim(), manga.title).takeIf { !it.isNullOrBlank() },
                author = pick(saved.author, author.trim(), manga.author.orEmpty()),
                artist = pick(saved.artist, artist.trim(), manga.artist.orEmpty()),
                description = pick(saved.description, description.trim(), manga.description.orEmpty()),
                genres = pick(saved.genres, genreList, manga.genre.orEmpty()),
                status = pick(saved.status, status, manga.status),
            )
        }

        var filling by remember { mutableStateOf(false) }
        var picking by remember { mutableStateOf<List<TrackerFill.Match>>(emptyList()) }

        // Only what's empty; nothing is saved until Save, so it can all be checked first
        fun fillFrom(matches: List<TrackerFill.Match>) {
            val before = TrackerFill.Form(author, artist, description, status)
            val filled = matches.fold(before) { form, match -> TrackerFill.fill(form, match, saved.status != null) }
            author = filled.author
            artist = filled.artist
            description = filled.description
            status = filled.status
            context.toast(
                if (filled == before) {
                    context.stringResource(MR.strings.edit_details_fill_nothing)
                } else {
                    context.stringResource(MR.strings.edit_details_fill_done, matches.first().trackerName)
                },
            )
        }

        fun startFill() {
            if (!graph.trackerFill.canFill()) {
                context.toast(context.stringResource(MR.strings.edit_details_fill_not_signed_in))
                return
            }
            filling = true
            scope.launch {
                val linked = graph.trackerFill.linked(manga)
                if (linked.isNotEmpty()) {
                    fillFrom(linked)
                } else {
                    val found = runCatching { graph.trackerFill.search(title.trim().ifEmpty { manga.title }) }
                    found.onFailure { context.toast(it.message) }
                    found.onSuccess {
                        if (it.isEmpty()) context.toast(context.stringResource(MR.strings.edit_details_fill_no_results))
                        picking = it
                    }
                }
                filling = false
            }
        }

        if (picking.isNotEmpty()) {
            AlertDialog(
                onDismissRequest = { picking = emptyList() },
                title = { Text(stringResource(MR.strings.edit_details_fill_pick)) },
                text = {
                    LazyColumn {
                        items(picking) { match ->
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        picking = emptyList()
                                        fillFrom(listOf(match))
                                    }
                                    .padding(vertical = 8.dp),
                            ) {
                                Text(match.title, style = MaterialTheme.typography.bodyLarge)
                                Text(
                                    listOf(match.trackerName, match.author, match.publishingStatus)
                                        .filter { it.isNotBlank() }
                                        .joinToString(" · "),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { picking = emptyList() }) { Text(stringResource(MR.strings.action_cancel)) }
                },
            )
        }

        val savedText = stringResource(MR.strings.edit_details_saved)
        Scaffold(
            topBar = { scrollBehavior ->
                AppBar(
                    titleContent = {
                        AppBarTitle(title = stringResource(MR.strings.action_edit_details), subtitle = manga.title)
                    },
                    navigateUp = navigator::pop,
                    scrollBehavior = scrollBehavior,
                )
            },
        ) { contentPadding ->
            Column(
                modifier = Modifier
                    .padding(contentPadding)
                    .imePadding()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = stringResource(MR.strings.edit_details_info),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Field(MR.strings.edit_details_title, title, saved.title != null) { title = it }
                Field(MR.strings.edit_details_author, author, saved.author != null) { author = it }
                Field(MR.strings.edit_details_artist, artist, saved.artist != null) { artist = it }
                Field(MR.strings.edit_details_description, description, saved.description != null, singleLine = false) {
                    description = it
                }
                Field(
                    MR.strings.edit_details_genres,
                    genres,
                    saved.genres != null,
                    supporting = stringResource(MR.strings.edit_details_genres_hint),
                ) { genres = it }
                StatusField(status, saved.status != null) { status = it }
                OutlinedButton(enabled = !filling, onClick = ::startFill) {
                    Text(stringResource(MR.strings.edit_details_fill))
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, alignment = androidx.compose.ui.Alignment.End),
                ) {
                    if (saved != SeriesEdits.Details()) {
                        OutlinedButton(
                            onClick = {
                                scope.launch {
                                    edits.edit(manga, null)
                                    // The source's details back, now
                                    graph.updateMangaFromRemote(manga, fetchDetails = true)
                                    DochoSyncWorker.syncSoon(context)
                                    navigator.pop()
                                }
                            },
                        ) { Text(stringResource(MR.strings.edit_details_reset)) }
                    }
                    Button(
                        onClick = {
                            scope.launch {
                                edits.edit(manga, details())
                                DochoSyncWorker.syncSoon(context)
                                context.toast(savedText)
                                navigator.pop()
                            }
                        },
                    ) { Text(stringResource(MR.strings.action_save)) }
                }
            }
        }
    }

    @Composable
    private fun Field(
        label: dev.icerock.moko.resources.StringResource,
        value: String,
        edited: Boolean,
        singleLine: Boolean = true,
        supporting: String? = null,
        onChange: (String) -> Unit,
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            label = { Text(stringResource(label)) },
            singleLine = singleLine,
            minLines = if (singleLine) 1 else 4,
            supportingText = when {
                edited && supporting != null -> {
                    { Text("${stringResource(MR.strings.edit_details_edited)} · $supporting") }
                }
                edited -> {
                    { Text(stringResource(MR.strings.edit_details_edited)) }
                }
                supporting != null -> {
                    { Text(supporting) }
                }
                else -> null
            },
            modifier = Modifier.fillMaxWidth(),
        )
    }

    @Composable
    private fun StatusField(status: Long, edited: Boolean, onChange: (Long) -> Unit) {
        val statuses = listOf(
            SManga.UNKNOWN.toLong() to MR.strings.unknown,
            SManga.ONGOING.toLong() to MR.strings.ongoing,
            SManga.COMPLETED.toLong() to MR.strings.completed,
            SManga.LICENSED.toLong() to MR.strings.licensed,
            SManga.PUBLISHING_FINISHED.toLong() to MR.strings.publishing_finished,
            SManga.CANCELLED.toLong() to MR.strings.cancelled,
            SManga.ON_HIATUS.toLong() to MR.strings.on_hiatus,
        )
        var open by remember { mutableStateOf(false) }
        Box {
            TextButton(onClick = { open = true }) {
                val name = statuses.firstOrNull { it.first == status }?.second ?: MR.strings.unknown
                val suffix = if (edited) " · ${stringResource(MR.strings.edit_details_edited)}" else ""
                Text("${stringResource(MR.strings.edit_details_status)}: ${stringResource(name)}$suffix")
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                statuses.forEach { (value, name) ->
                    DropdownMenuItem(
                        text = { Text(stringResource(name)) },
                        onClick = {
                            onChange(value)
                            open = false
                        },
                    )
                }
            }
        }
    }
}
