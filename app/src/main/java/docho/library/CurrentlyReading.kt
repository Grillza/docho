package docho.library

import dev.zacsweers.metro.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import tachiyomi.domain.chapter.interactor.GetChaptersByMangaId
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.history.model.HistoryWithRelations
import tachiyomi.domain.history.repository.HistoryRepository
import tachiyomi.domain.manga.model.Manga
import tachiyomi.domain.manga.model.MangaCover
import tachiyomi.domain.manga.repository.MangaRepository

/** The library series read most recently and not finished, for the bar at the top of the library. */
@Inject
class CurrentlyReading(
    private val historyRepository: HistoryRepository,
    private val mangaRepository: MangaRepository,
    private val getChaptersByMangaId: GetChaptersByMangaId,
) {

    data class Reading(
        val mangaId: Long,
        val title: String,
        val cover: MangaCover,
        /** The chapter to resume. */
        val chapterId: Long,
        val chapterName: String,
        /** The page reached in it, from 1; 0 if it wasn't started. */
        val page: Int,
        val readChapters: Int,
        val totalChapters: Int,
    )

    fun subscribe(): Flow<List<Reading>> = historyRepository.getHistory("").map(::readingFrom)

    private suspend fun readingFrom(history: List<HistoryWithRelations>): List<Reading> {
        val reading = mutableListOf<Reading>()
        for (entry in history.distinctBy { it.mangaId }) {
            val manga = runCatching { mangaRepository.getMangaById(entry.mangaId) }.getOrNull() ?: continue
            if (!manga.favorite) continue
            val chapters = getChaptersByMangaId.await(manga.id, applyScanlatorFilter = true)
            reading += reading(manga, entry, chapters) ?: continue
            if (reading.size == LIMIT) break
        }
        return reading
    }

    private fun reading(manga: Manga, entry: HistoryWithRelations, chapters: List<Chapter>): Reading? {
        val resume = resumeChapter(chapters, entry.chapterId) ?: return null
        return Reading(
            mangaId = manga.id,
            title = manga.title,
            cover = entry.coverData,
            chapterId = resume.id,
            chapterName = resume.name,
            page = if (resume.lastPageRead > 0) resume.lastPageRead.toInt() + 1 else 0,
            readChapters = chapters.count { it.read },
            totalChapters = chapters.size,
        )
    }

    companion object {
        const val LIMIT = 3

        /**
         * The chapter to go on with: the last one read if it's not finished, else the next unread
         * one after it in reading order, else the first unread one. Null if all are read.
         */
        fun resumeChapter(chapters: List<Chapter>, lastReadId: Long): Chapter? {
            // A source lists its newest chapter first
            val inOrder = chapters.sortedByDescending { it.sourceOrder }
            val last = inOrder.indexOfFirst { it.id == lastReadId }
            if (last >= 0 && !inOrder[last].read) return inOrder[last]
            if (last >= 0) inOrder.drop(last + 1).firstOrNull { !it.read }?.let { return it }
            return inOrder.firstOrNull { !it.read }
        }
    }
}
