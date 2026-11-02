package tachiyomi.domain.chapter.service

import eu.kanade.tachiyomi.util.lang.compareToCaseInsensitiveNaturalOrder
import tachiyomi.core.common.util.lang.compareToWithCollator
import tachiyomi.domain.chapter.model.Chapter
import tachiyomi.domain.manga.model.Manga

/**
 * Compares chapters as [manga]'s chapter list is sorted. With volumes or chapters first, that group comes first whichever
 * way the list runs. [readingOrder] is for reading through the series rather than showing it: volumes come before
 * chapters then, since a series' chapters carry on where its volumes end.
 */
fun getChapterSort(
    manga: Manga,
    sortDescending: Boolean = manga.sortDescending(),
    readingOrder: Boolean = false,
): (
    Chapter,
    Chapter,
) -> Int {
    val sort = getSortWithinKind(manga, sortDescending)
    val kindOrder = when {
        manga.kindOrder == Manga.CHAPTER_KIND_MIXED -> return sort
        readingOrder -> Manga.CHAPTER_VOLUMES_FIRST
        else -> manga.kindOrder
    }
    val volumesFirst = kindOrder == Manga.CHAPTER_VOLUMES_FIRST
    return { c1, c2 ->
        when {
            c1.isVolume == c2.isVolume -> sort(c1, c2)
            c1.isVolume == volumesFirst -> -1
            else -> 1
        }
    }
}

private fun getSortWithinKind(manga: Manga, sortDescending: Boolean): (Chapter, Chapter) -> Int {
    return when (manga.sorting) {
        Manga.CHAPTER_SORTING_SOURCE -> when (sortDescending) {
            true -> { c1, c2 -> c1.sourceOrder.compareTo(c2.sourceOrder) }
            false -> { c1, c2 -> c2.sourceOrder.compareTo(c1.sourceOrder) }
        }
        Manga.CHAPTER_SORTING_NUMBER -> when (sortDescending) {
            true -> { c1, c2 -> c2.chapterNumber.compareTo(c1.chapterNumber) }
            false -> { c1, c2 -> c1.chapterNumber.compareTo(c2.chapterNumber) }
        }
        Manga.CHAPTER_SORTING_UPLOAD_DATE -> when (sortDescending) {
            true -> { c1, c2 -> compareValues(c2.dateUpload, c1.dateUpload) }
            false -> { c1, c2 -> compareValues(c1.dateUpload, c2.dateUpload) }
        }
        Manga.CHAPTER_SORTING_ALPHABET -> when (sortDescending) {
            true -> { c1, c2 -> c2.name.compareToWithCollator(c1.name) }
            false -> { c1, c2 -> c1.name.compareToWithCollator(c2.name) }
        }
        Manga.CHAPTER_SORTING_FILE_NAME -> when (sortDescending) {
            true -> { c1, c2 -> c2.fileName.compareToCaseInsensitiveNaturalOrder(c1.fileName) }
            false -> { c1, c2 -> c1.fileName.compareToCaseInsensitiveNaturalOrder(c2.fileName) }
        }
        else -> throw NotImplementedError("Invalid chapter sorting method: ${manga.sorting}")
    }
}
