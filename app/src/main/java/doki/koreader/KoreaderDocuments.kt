package doki.koreader

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import tachiyomi.domain.manga.model.Manga

/** A chapter's file as KOReader identifies it: its partial MD5 ([KoreaderHash]) and page count. */
@Serializable
data class KoreaderDocument(val hash: String, val pages: Int)

/** What KOReader sync knows about a chapter: its URL and memo, and its page count once read. */
data class KoreaderChapterRef(val url: String, val memo: JsonObject, val pageCount: Int?)

/**
 * Finds the files behind one source's chapters. KOReader matches documents by file, so a source
 * takes part in KOReader sync only if Doki can reach the file each chapter was made from:
 * a source serving page images alone can't be matched.
 */
interface KoreaderDocumentProvider {

    val sourceId: Long

    /** Documents for these chapters of [manga], keyed by chapter URL; chapters that can't be matched are left out. */
    suspend fun documents(manga: Manga, chapters: List<KoreaderChapterRef>): Map<String, KoreaderDocument>
}

/**
 * Documents that took requests or file reads to work out, kept across restarts. Keys belong to
 * the provider, which includes whatever would change when the file does.
 */
@Inject
@SingleIn(AppScope::class)
class KoreaderDocumentCache(
    private val preferences: KoreaderPreferences,
    private val json: Json,
) {

    private val mutex = Mutex()

    suspend fun get(key: String): KoreaderDocument? = mutex.withLock { read()[key] }

    suspend fun put(key: String, document: KoreaderDocument) = mutex.withLock {
        val current = read()
        if (current[key] != document) write(current + (key to document))
    }

    private fun read(): Map<String, KoreaderDocument> {
        val raw = preferences.documentCache.get()
        if (raw.isBlank()) return emptyMap()
        return runCatching { json.decodeFromString<Map<String, KoreaderDocument>>(raw) }.getOrElse { emptyMap() }
    }

    private fun write(documents: Map<String, KoreaderDocument>) {
        preferences.documentCache.set(json.encodeToString(documents))
    }
}
