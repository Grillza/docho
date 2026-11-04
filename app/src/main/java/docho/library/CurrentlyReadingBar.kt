package docho.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import eu.kanade.presentation.manga.components.MangaCover
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.i18n.stringResource

/** The series being read, at most three, each with a Resume button, as on Dōchō Server. */
@Composable
fun CurrentlyReadingBar(
    items: List<CurrentlyReading.Reading>,
    onClickSeries: (Long) -> Unit,
    onResume: (CurrentlyReading.Reading) -> Unit,
) {
    if (items.isEmpty()) return
    Column(modifier = Modifier.padding(top = 8.dp, bottom = 4.dp)) {
        Text(
            text = stringResource(MR.strings.currently_reading),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(items, key = { it.mangaId }) { reading ->
                Card(modifier = Modifier.width(300.dp).height(96.dp).clickable { onClickSeries(reading.mangaId) }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        MangaCover.Book(data = reading.cover, modifier = Modifier.fillMaxHeight())
                        Column(
                            modifier = Modifier.weight(1f).padding(horizontal = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                reading.title,
                                style = MaterialTheme.typography.titleSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                if (reading.page > 0) {
                                    stringResource(MR.strings.currently_reading_page, reading.chapterName, reading.page)
                                } else {
                                    reading.chapterName
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            LinearProgressIndicator(
                                progress = { reading.readChapters.toFloat() / reading.totalChapters.coerceAtLeast(1) },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                            )
                            Text(
                                stringResource(MR.strings.currently_reading_read, reading.readChapters, reading.totalChapters),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Button(
                            onClick = { onResume(reading) },
                            contentPadding = PaddingValues(horizontal = 10.dp),
                            modifier = Modifier.padding(end = 8.dp),
                        ) { Text(stringResource(MR.strings.currently_reading_resume)) }
                    }
                }
            }
        }
    }
}
