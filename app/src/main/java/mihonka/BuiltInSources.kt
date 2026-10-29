package mihonka

import androidx.annotation.DrawableRes
import eu.kanade.tachiyomi.R
import mihonka.bookorbit.BookOrbitSource
import mihonka.kavita.KavitaSource
import mihonka.komga.KomgaSource

/** Sources Mihonka builds in rather than loading from extensions. */
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
