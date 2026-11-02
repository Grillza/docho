package eu.kanade.tachiyomi.util.chapter

import eu.kanade.domain.chapter.model.applyFilters
import eu.kanade.tachiyomi.data.download.DownloadManager
import eu.kanade.tachiyomi.ui.manga.ChapterList
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.chapter.service.getChapterSort
import tachiyomi.domain.manga.model.Manga

/**
 * Gets next unread chapter with filters and sorting applied
 */
fun List<Chapter>.getNextUnread(manga: Manga, downloadManager: DownloadManager): Chapter? {
    return applyFilters(manga, downloadManager).let { chapters ->
        if (manga.kindOrder != Manga.CHAPTER_KIND_MIXED) {
            // Volumes or chapters listed first: the next to read still follows reading order
            chapters.sortedWith(getChapterSort(manga, sortDescending = false, readingOrder = true)).find { !it.read }
        } else if (manga.sortDescending()) {
            chapters.findLast { !it.read }
        } else {
            chapters.find { !it.read }
        }
    }
}

/**
 * Gets next unread chapter with filters and sorting applied
 */
fun List<ChapterList.Item>.getNextUnread(manga: Manga): Chapter? {
    return applyFilters(manga).let { chapters ->
        if (manga.kindOrder != Manga.CHAPTER_KIND_MIXED) {
            val readingOrder = getChapterSort(manga, sortDescending = false, readingOrder = true)
            chapters.sortedWith { a, b -> readingOrder(a.chapter, b.chapter) }.find { !it.chapter.read }
        } else if (manga.sortDescending()) {
            chapters.findLast { !it.chapter.read }
        } else {
            chapters.find { !it.chapter.read }
        }
    }?.chapter
}
