package doki.koreader

import android.content.Context
import com.hippo.unifile.UniFile
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.source.model.SChapter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import logcat.LogPriority
import mihon.core.archive.archiveReader
import tachiyomi.core.common.util.system.ImageUtil
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.manga.model.Manga
import tachiyomi.source.local.LocalSource
import tachiyomi.source.local.io.Format
import java.io.FileInputStream
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Local source chapters for KOReader sync. An archive on the device is hashed directly, and its
 * pages counted the way the reader counts them; folders of images and EPUBs can't be matched.
 * Results are cached against the file's modification time, so an edited file is hashed again.
 */
@Inject
@SingleIn(AppScope::class)
class LocalKoreaderDocuments(
    private val context: Context,
    private val localSource: LocalSource,
    private val cache: KoreaderDocumentCache,
) : KoreaderDocumentProvider {

    override val sourceId: Long = LocalSource.ID

    override suspend fun documents(manga: Manga, chapters: List<KoreaderChapterRef>): Map<String, KoreaderDocument> =
        withContext(Dispatchers.IO) {
            chapters.mapNotNull { ref ->
                try {
                    val format = localSource.getFormat(SChapter.create().apply { url = ref.url })
                    val file = (format as? Format.Archive)?.file ?: return@mapNotNull null
                    val key = "local:${ref.url}@${file.lastModified()}"
                    val document = cache.get(key)
                        ?: KoreaderDocument(hash(file), ref.pageCount ?: countPages(file)).also { cache.put(key, it) }
                    ref.url to document
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    logcat(LogPriority.WARN, e) { "KOReader: could not read local chapter ${ref.url}" }
                    null
                }
            }.toMap()
        }

    private suspend fun hash(file: UniFile): String {
        val descriptor = context.contentResolver.openFileDescriptor(file.uri, "r")
            ?: throw IOException("Could not open ${file.uri}")
        return descriptor.use { pfd ->
            FileInputStream(pfd.fileDescriptor).channel.use { channel ->
                KoreaderHash.compute { offset, length ->
                    val buffer = ByteBuffer.allocate(length)
                    val read = channel.read(buffer, offset).coerceAtLeast(0)
                    buffer.array().copyOf(read) to channel.size()
                }
            }
        }
    }

    private fun countPages(file: UniFile): Int = file.archiveReader(context).use { reader ->
        reader.useEntries { entries ->
            entries.count { it.isFile && ImageUtil.isImage(it.name) { reader.getInputStream(it.name)!! } }
        }
    }
}
