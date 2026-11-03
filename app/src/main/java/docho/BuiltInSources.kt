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
    fun isBuiltIn(sourceId: Long): Boolean = sourceId in ids || isDochoServerLibrary(sourceId)

    /**
     * One of Dōchō Server's libraries or its Series Groups (ids 0x0D0C000000000000 + library id):
     * the user's own books, served through the Suwayomi sources, but listed like a built-in server.
     */
    fun isDochoServerLibrary(sourceId: Long): Boolean = sourceId in 0x0D0C_0000_0000_0000L..0x0D0C_0000_7FFF_FFFFL

    /** The server's logo, shown where an extension would show its icon. */
    @DrawableRes
    fun iconRes(sourceId: Long): Int? = when (sourceId) {
        KavitaSource.ID -> R.drawable.brand_kavita
        BookOrbitSource.ID -> R.drawable.brand_bookorbit
        KomgaSource.ID -> R.drawable.brand_komga
        else -> if (isDochoServerLibrary(sourceId)) R.drawable.brand_docho_server else null
    }
}
