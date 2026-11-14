package docho.dochosync

import android.text.format.DateUtils
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import eu.kanade.domain.ui.UiPreferences
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.pluralStringResource
import tachiyomi.presentation.core.i18n.stringResource
import tachiyomi.presentation.core.util.collectAsState as collectPreferenceAsState
import kotlin.time.Duration.Companion.seconds

/**
 * "Is this where you're up to?": shown at the top of the screen when Dōchō Sync took a later
 * change that went back (an earlier page, or unread) while further progress was elsewhere. Compare
 * shows both and lets you keep either; Ignore keeps what's there. It hides itself after the time
 * set in Appearance, keeping what's there.
 */
@Composable
fun SyncConflictBanner(
    dochoSync: DochoSync,
    uiPreferences: UiPreferences,
    deviceId: String,
    modifier: Modifier = Modifier,
) {
    val conflicts by dochoSync.conflicts.collectAsState()
    val seconds by uiPreferences.syncBannerSeconds.collectPreferenceAsState()
    var comparing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Starts again when more arrive; not while comparing.
    LaunchedEffect(conflicts, seconds, comparing) {
        if (conflicts.isEmpty() || seconds <= 0 || comparing) return@LaunchedEffect
        delay(seconds.seconds)
        dochoSync.dismissConflicts(conflicts)
    }

    AnimatedVisibility(
        visible = conflicts.isNotEmpty() && !comparing,
        enter = slideInVertically { -it },
        exit = slideOutVertically { -it },
        modifier = modifier,
    ) {
        val first = conflicts.firstOrNull() ?: return@AnimatedVisibility
        Card(
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
            elevation = CardDefaults.cardElevation(defaultElevation = 6.dp),
            modifier = Modifier
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .widthIn(max = 640.dp)
                .fillMaxWidth(),
        ) {
            Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp)) {
                Text(stringResource(MR.strings.docho_sync_conflict_title), style = MaterialTheme.typography.titleSmall)
                Text(
                    summary(first, deviceId),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 4.dp, end = 8.dp),
                )
                if (conflicts.size > 1) {
                    Text(
                        pluralStringResource(MR.plurals.docho_sync_conflict_more, conflicts.size - 1, conflicts.size - 1),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = { dochoSync.dismissConflicts(conflicts) }) {
                        Text(stringResource(MR.strings.docho_sync_conflict_ignore))
                    }
                    TextButton(onClick = { comparing = true }) {
                        Text(stringResource(MR.strings.docho_sync_conflict_compare))
                    }
                }
            }
        }
    }

    if (comparing && conflicts.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = { comparing = false },
            title = { Text(stringResource(MR.strings.docho_sync_conflict_details)) },
            text = {
                LazyColumn {
                    items(conflicts, key = { it.chapterId }) { conflict ->
                        Column(Modifier.padding(vertical = 8.dp)) {
                            Text(conflict.seriesTitle, style = MaterialTheme.typography.titleSmall)
                            Text(conflict.chapterName, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                stringResource(MR.strings.docho_sync_conflict_now, progressText(conflict.kept)),
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.padding(top = 4.dp),
                            )
                            val device = deviceText(conflict.furtherDevice, deviceId)
                            Text(
                                conflict.furtherAt?.let {
                                    stringResource(
                                        MR.strings.docho_sync_conflict_further,
                                        progressText(conflict.further),
                                        device,
                                        DateUtils.getRelativeTimeSpanString(it).toString(),
                                    )
                                } ?: stringResource(MR.strings.docho_sync_conflict_further_undated, progressText(conflict.further), device),
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            Row(
                                Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.End,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                TextButton(onClick = { dochoSync.dismissConflicts(listOf(conflict)) }) {
                                    Text(stringResource(MR.strings.docho_sync_conflict_keep))
                                }
                                TextButton(onClick = { scope.launch { dochoSync.useFurther(conflict) } }) {
                                    Text(stringResource(MR.strings.docho_sync_conflict_use_further, progressText(conflict.further)))
                                }
                            }
                            HorizontalDivider(Modifier.padding(top = 4.dp))
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    dochoSync.dismissConflicts(conflicts)
                    comparing = false
                }) {
                    Text(stringResource(MR.strings.docho_sync_conflict_keep_all))
                }
            },
        )
    }
    // Closes once each is answered.
    LaunchedEffect(conflicts.isEmpty()) { if (conflicts.isEmpty()) comparing = false }
}

@Composable
private fun summary(conflict: DochoSync.Conflict, deviceId: String): String =
    if (conflict.keptHere) {
        stringResource(
            MR.strings.docho_sync_conflict_went_back_here,
            conflict.seriesTitle,
            conflict.chapterName,
            progressText(conflict.kept),
            deviceText(conflict.furtherDevice, deviceId),
            progressText(conflict.further),
        )
    } else {
        stringResource(
            MR.strings.docho_sync_conflict_went_back_there,
            conflict.seriesTitle,
            conflict.chapterName,
            progressText(conflict.kept),
            progressText(conflict.further),
        )
    }

/** "page 5", "unread" or "read"; pages count from 1 here, from 0 in the records. */
@Composable
private fun progressText(progress: DochoSync.Progress): String = when {
    progress.read -> stringResource(MR.strings.docho_sync_progress_read)
    progress.page > 0 -> stringResource(MR.strings.docho_sync_progress_page, progress.page + 1)
    else -> stringResource(MR.strings.docho_sync_progress_unread)
}

@Composable
private fun deviceText(device: String?, deviceId: String): String = when (device) {
    null, deviceId -> stringResource(MR.strings.docho_sync_device_this)
    "docho-server" -> stringResource(MR.strings.docho_sync_device_server)
    else -> stringResource(MR.strings.docho_sync_device_other)
}
