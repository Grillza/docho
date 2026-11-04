package docho.edit

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import docho.dochosync.DochoSyncWorker
import eu.kanade.presentation.components.AppBar
import eu.kanade.presentation.util.Screen
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.util.system.toast
import kotlinx.coroutines.launch
import mihon.app.di.AppGraph
import mihon.core.metro.metroGraph
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.Scaffold
import tachiyomi.presentation.core.i18n.stringResource

/** Settings → Tracking → Fill details from trackers: the scan and the list it leaves to review. */
class TrackerFillScreen : Screen() {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        val scan = remember { context.metroGraph<AppGraph>().trackerFillScan }
        val progress by scan.progress.collectAsState()
        val items by scan.items.collectAsState()
        var compareAll by rememberSaveable { mutableStateOf(true) }
        var forget by rememberSaveable { mutableStateOf(false) }
        var showReady by rememberSaveable { mutableStateOf(false) }
        var busy by remember { mutableStateOf(false) }
        var confirmScan by remember { mutableStateOf(false) }
        var confirmKeepAll by remember { mutableStateOf(false) }

        LaunchedEffect(Unit) { scan.load() }

        val list = items.orEmpty()
        val ready = list.filter { it.problem == FillProblem.READY }
        val conflicts = list.filter { it.problem != FillProblem.READY }

        fun act(action: suspend () -> Unit) {
            busy = true
            scope.launch {
                try {
                    action()
                    DochoSyncWorker.syncSoon(context)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    context.toast(e.message)
                }
                busy = false
            }
        }

        fun start() {
            if (!scan.canScan()) {
                context.toast(context.stringResource(MR.strings.edit_details_fill_not_signed_in))
                return
            }
            TrackerFillWorker.start(context, compareAll, forget)
            forget = false
        }

        if (confirmScan) {
            AlertDialog(
                onDismissRequest = { confirmScan = false },
                text = { Text(stringResource(MR.strings.tracker_fill_scan_replaces)) },
                confirmButton = {
                    TextButton(onClick = {
                        confirmScan = false
                        start()
                    }) { Text(stringResource(MR.strings.tracker_fill_scan)) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmScan = false }) { Text(stringResource(MR.strings.action_cancel)) }
                },
            )
        }
        if (confirmKeepAll) {
            AlertDialog(
                onDismissRequest = { confirmKeepAll = false },
                text = { Text(stringResource(MR.strings.tracker_fill_keep_all_confirm, conflicts.size)) },
                confirmButton = {
                    TextButton(onClick = {
                        confirmKeepAll = false
                        act { scan.dismissConflicts() }
                    }) { Text(stringResource(MR.strings.tracker_fill_keep_all)) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmKeepAll = false }) { Text(stringResource(MR.strings.action_cancel)) }
                },
            )
        }

        Scaffold(
            topBar = { scrollBehavior ->
                AppBar(
                    title = stringResource(MR.strings.tracker_fill_title),
                    navigateUp = navigator::pop,
                    scrollBehavior = scrollBehavior,
                )
            },
        ) { contentPadding ->
            LazyColumn(
                contentPadding = PaddingValues(
                    top = contentPadding.calculateTopPadding() + 8.dp,
                    bottom = contentPadding.calculateBottomPadding() + 16.dp,
                    start = 16.dp,
                    end = 16.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            stringResource(MR.strings.tracker_fill_info),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (progress.running) {
                            LinearProgressIndicator(
                                progress = { if (progress.total > 0) progress.done.toFloat() / progress.total else 0f },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Text(stringResource(MR.strings.tracker_fill_scanning, progress.done, progress.total))
                            OutlinedButton(onClick = { TrackerFillWorker.stop(context) }) {
                                Text(stringResource(MR.strings.tracker_fill_stop))
                            }
                        } else {
                            CheckRow(stringResource(MR.strings.tracker_fill_compare_all), compareAll) { compareAll = it }
                            CheckRow(stringResource(MR.strings.tracker_fill_forget), forget) { forget = it }
                            if (progress.finished) {
                                Text(
                                    stringResource(
                                        MR.strings.tracker_fill_last_scan,
                                        progress.done,
                                        progress.unchanged,
                                        progress.failed,
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                            Button(onClick = { if (list.isEmpty()) start() else confirmScan = true }) {
                                Text(stringResource(MR.strings.tracker_fill_scan))
                            }
                        }
                    }
                }
                item {
                    TabRow(selectedTabIndex = if (showReady) 1 else 0) {
                        Tab(
                            selected = !showReady,
                            onClick = { showReady = false },
                            text = { Text(stringResource(MR.strings.tracker_fill_conflicts, conflicts.size)) },
                        )
                        Tab(
                            selected = showReady,
                            onClick = { showReady = true },
                            text = { Text(stringResource(MR.strings.tracker_fill_ready, ready.size)) },
                        )
                    }
                }
                val shown = if (showReady) ready else conflicts
                if (shown.isEmpty()) {
                    item {
                        Text(
                            stringResource(
                                if (showReady) MR.strings.tracker_fill_nothing_ready else MR.strings.tracker_fill_nothing_conflicts,
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    item {
                        if (showReady) {
                            Button(
                                enabled = !busy,
                                onClick = {
                                    act {
                                        val (applied, failed) = scan.applyReady()
                                        context.toast(context.stringResource(MR.strings.tracker_fill_applied, applied, failed))
                                    }
                                },
                            ) { Text(stringResource(MR.strings.tracker_fill_apply_all, ready.size)) }
                        } else {
                            TextButton(enabled = !busy, onClick = { confirmKeepAll = true }) {
                                Text(stringResource(MR.strings.tracker_fill_keep_all), color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                    items(shown, key = { it.key }) { item ->
                        if (item.changes.isNotEmpty()) {
                            ChangesCard(
                                item = item,
                                busy = busy,
                                onApply = { act { scan.resolve(item.key, it) } },
                                onKeep = { act { scan.skip(item.key) } },
                            )
                        } else {
                            MatchCard(
                                item = item,
                                busy = busy,
                                onPick = { act { scan.pick(item.key, it) } },
                                onSearch = { act { scan.searchFor(item.key, it) } },
                                onSkip = { act { scan.skip(item.key) } },
                            )
                        }
                    }
                }
            }
        }
    }

    @Composable
    private fun CheckRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().clickable { onChange(!checked) },
        ) {
            Checkbox(checked = checked, onCheckedChange = onChange)
            Text(label, style = MaterialTheme.typography.bodyMedium)
        }
    }

    @Composable
    private fun fieldName(field: String) = stringResource(
        when (field) {
            TrackerFillRules.AUTHOR -> MR.strings.edit_details_author
            TrackerFillRules.ARTIST -> MR.strings.edit_details_artist
            TrackerFillRules.DESCRIPTION -> MR.strings.edit_details_description
            else -> MR.strings.edit_details_status
        },
    )

    @Composable
    private fun valueText(field: String, value: String): String {
        if (field != TrackerFillRules.STATUS) return value
        return stringResource(
            when (value.toIntOrNull()) {
                SManga.ONGOING -> MR.strings.ongoing
                SManga.COMPLETED -> MR.strings.completed
                SManga.LICENSED -> MR.strings.licensed
                SManga.PUBLISHING_FINISHED -> MR.strings.publishing_finished
                SManga.CANCELLED -> MR.strings.cancelled
                SManga.ON_HIATUS -> MR.strings.on_hiatus
                else -> MR.strings.unknown
            },
        )
    }

    /** A series whose fields need deciding, or that's ready to apply. */
    @Composable
    private fun ChangesCard(
        item: FillItem,
        busy: Boolean,
        onApply: (Map<String, String?>) -> Unit,
        onKeep: () -> Unit,
    ) {
        val choices = remember(item) {
            mutableStateMapOf<String, String?>().apply {
                item.changes.forEach { change ->
                    val empty = change.current.isBlank() || change.current == "0" ||
                        (change.field != TrackerFillRules.STATUS && TrackerFillRules.isEmptyName(change.current))
                    put(change.field, if (!change.conflict || empty) change.options.first().value else null)
                }
            }
        }
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(item.title, style = MaterialTheme.typography.titleMedium)
                item.changes.forEach { change ->
                    Text(fieldName(change.field), style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold)
                    if (change.conflict) {
                        val hasValue = change.current.isNotBlank() && change.current != "0"
                        if (hasValue) {
                            RadioRow(
                                stringResource(MR.strings.tracker_fill_keep, valueText(change.field, change.current)),
                                choices[change.field] == null,
                            ) { choices[change.field] = null }
                        }
                        change.options.forEach { option ->
                            RadioRow(
                                "${option.trackerName}: ${valueText(change.field, option.value)}",
                                choices[change.field] == option.value,
                            ) { choices[change.field] = option.value }
                        }
                    } else {
                        val option = change.options.first()
                        Text(
                            "${valueText(change.field, option.value).take(240)} (${option.trackerName})",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(enabled = !busy, onClick = { onApply(choices.toMap()) }) {
                        Text(stringResource(MR.strings.tracker_fill_apply))
                    }
                    TextButton(enabled = !busy, onClick = onKeep) {
                        Text(stringResource(MR.strings.tracker_fill_keep_everything))
                    }
                }
            }
        }
    }

    @Composable
    private fun RadioRow(label: String, selected: Boolean, onClick: () -> Unit) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().selectable(selected = selected, onClick = onClick),
        ) {
            RadioButton(selected = selected, onClick = onClick)
            Text(label, style = MaterialTheme.typography.bodyMedium)
        }
    }

    /** A series with no clear match: pick one of the results, search again, or leave it. */
    @Composable
    private fun MatchCard(
        item: FillItem,
        busy: Boolean,
        onPick: (Int) -> Unit,
        onSearch: (String) -> Unit,
        onSkip: () -> Unit,
    ) {
        var query by rememberSaveable(item.key) { mutableStateOf(item.title) }
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(item.title, style = MaterialTheme.typography.titleMedium)
                Text(
                    stringResource(
                        if (item.problem == FillProblem.SEVERAL_MATCHES) {
                            MR.strings.tracker_fill_several
                        } else {
                            MR.strings.tracker_fill_no_match
                        },
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                item.candidates.forEachIndexed { index, candidate ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = !busy) { onPick(index) }
                            .padding(vertical = 6.dp),
                    ) {
                        Text(candidate.title, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            listOf(candidate.trackerName, candidate.author, candidate.publishingStatus)
                                .filter { it.isNotBlank() }
                                .joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    label = { Text(stringResource(MR.strings.tracker_fill_search_other)) },
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(enabled = !busy && query.isNotBlank(), onClick = { onSearch(query) }) {
                        Text(stringResource(MR.strings.tracker_fill_search))
                    }
                    TextButton(enabled = !busy, onClick = onSkip) { Text(stringResource(MR.strings.tracker_fill_skip)) }
                }
            }
        }
    }
}
