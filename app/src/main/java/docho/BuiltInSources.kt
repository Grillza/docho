package docho

import androidx.annotation.DrawableRes
import docho.bookorbit.BookOrbitSource
import docho.kavita.KavitaSource
import docho.komga.KomgaSource
import eu.kanade.tachiyomi.R

/** Sources Docho builds in rather than loading from extensions. */
object BuiltInSources {

    private val ids = setOf(KavitaSource.ID, BookOrbitSource.ID, KomgaSource.ID)

    /**
     * Built-in sources serve the user's own files, so they skip the language filter, and their
     * chapter numbers are exact rather than recognised from chapter names.
     */
    fun isBuiltIn(sourceId: Long): Boolean = sourceId in ids

    /** The server's logo, shown where an extension would show its icon. */
    @DrawableRes
    fun iconRes(sourceId: Long): Int? = when (sourceId) {
        KavitaSource.ID -> R.drawable.brand_kavita
        BookOrbitSource.ID -> R.drawable.brand_bookorbit
        KomgaSource.ID -> R.drawable.brand_komga
        else -> null
    }
}
