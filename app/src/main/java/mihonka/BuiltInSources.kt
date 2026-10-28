package mihonka

import mihonka.bookorbit.BookOrbitSource
import mihonka.kavita.KavitaSource

/** Sources Mihonka builds in rather than loading from extensions. */
object BuiltInSources {

    private val ids = setOf(KavitaSource.ID, BookOrbitSource.ID)

    /**
     * Built-in sources serve the user's own files, so they skip the language filter, and their
     * chapter numbers are exact rather than recognised from chapter names.
     */
    fun isBuiltIn(sourceId: Long): Boolean = sourceId in ids
}
