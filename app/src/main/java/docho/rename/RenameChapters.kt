package docho.rename

import dev.zacsweers.metro.Inject
import docho.bookorbit.BookOrbitApi
import docho.bookorbit.BookOrbitSource
import docho.kavita.KavitaApi
import docho.kavita.KavitaSource
import docho.komga.KomgaApi
import docho.komga.KomgaSource
import docho.rename.ChapterRenames.Companion.withKind
import eu.kanade.tachiyomi.data.download.DownloadManager
import eu.kanade.tachiyomi.data.download.DownloadProvider
import eu.kanade.tachiyomi.source.Source
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import logcat.LogPriority
import tachiyomi.core.common.util.system.logcat
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.repository.ChapterRepository
import tachiyomi.domain.manga.model.Manga
import tachiyomi.source.local.LocalSource

/**
 * Renames chapters in Docho, and where the chapter lives somewhere Docho can change it too: the file itself for the
 * Local source, the title and number on Komga and BookOrbit (its series index), the title on Kavita. Other sources
 * keep the new name in Docho only. Whether a chapter is a volume is kept in Docho only.
 */
@Inject
class RenameChapters(
    private val chapterRepository: ChapterRepository,
    private val chapterRenames: ChapterRenames,
    private val downloadManager: DownloadManager,
    private val downloadProvider: DownloadProvider,
    private val kavitaApi: KavitaApi,
    private val komgaApi: KomgaApi,
    private val bookOrbitApi: BookOrbitApi,
) {

    /** [kind] is [Chapter.KIND_VOLUME] or [Chapter.KIND_CHAPTER] to say which the chapter is, or null to leave it. */
    data class Request(val chapter: Chapter, val name: String, val number: Double, val kind: String? = null) {
        val renames: Boolean
            get() = name.trim().let { it.isNotEmpty() && (it != chapter.name || number != chapter.chapterNumber) }

        val changesKind: Boolean
            get() = kind != null && (kind == Chapter.KIND_VOLUME) != chapter.isVolume

        val changes: Boolean
            get() = renames || changesKind
    }

    /**
     * A chapter to rename others like, see [tachiyomi.domain.chapter.service.RenameLike]: [original] is its name
     * before the user renamed it, if they did, at [renamedAt] (0 if not).
     */
    data class Example(val chapter: Chapter, val original: String?, val renamedAt: Long) {
        val renamed: Boolean get() = original != null
    }

    /**
     * How a rename went: [renamed] chapters were renamed in Docho, [failed] weren't at all, and [serverError] is why
     * the server didn't take some of them, which Docho still shows renamed.
     */
    data class Result(val renamed: Int, val failed: Int, val serverError: Throwable?)

    suspend fun await(manga: Manga, source: Source, requests: List<Request>): Result = withContext(Dispatchers.IO) {
        var renamed = 0
        var failed = 0
        var serverError: Throwable? = null
        for (request in requests) {
            val old = request.chapter
            if (!request.changes) continue
            try {
                var new = old
                if (request.renames) {
                    val name = request.name.trim()
                    val url = if (source is LocalSource) source.renameChapter(old.url, name) else old.url
                    try {
                        updateServer(source, old.url, name, request.number)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        logcat(LogPriority.WARN, e) { "Server didn't rename ${old.url}" }
                        if (serverError == null) serverError = e
                    }
                    new = old.copy(url = url, name = name, chapterNumber = request.number)
                    val original = chapterRenames.get(source.id, old.url)?.original ?: old.name
                    chapterRenames.put(
                        source.id,
                        old.url,
                        url,
                        ChapterRenames.Rename(name, request.number, original, System.currentTimeMillis()),
                    )
                    if (source !is LocalSource && downloadProvider.isChapterDirNameChanged(old, new) &&
                        downloadManager.isChapterDownloaded(old.name, old.scanlator, old.url, manga.title, manga.source)
                    ) {
                        downloadManager.renameChapter(source, manga, old, new)
                    }
                }
                if (request.changesKind && request.kind != null) {
                    new = new.withKind(request.kind)
                    chapterRenames.putKind(source.id, new.url, request.kind)
                }
                chapterRepository.rename(old.id, new.url, new.name, new.chapterNumber, new.memo)
                renamed++
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                logcat(LogPriority.ERROR, e) { "Couldn't rename ${old.url}" }
                failed++
            }
        }
        Result(renamed, failed, serverError)
    }

    private suspend fun updateServer(source: Source, url: String, name: String, number: Double) {
        when (source.id) {
            KavitaSource.ID -> kavitaApi.setChapterTitle(KavitaSource.chapterId(url), name)
            KomgaSource.ID -> komgaApi.setBookTitle(KomgaSource.bookId(url), name, number)
            BookOrbitSource.ID -> bookOrbitApi.setBookTitle(
                BookOrbitSource.bookId(url),
                BookOrbitSource.titleFromChapterName(name),
                number,
            )
        }
    }
}
