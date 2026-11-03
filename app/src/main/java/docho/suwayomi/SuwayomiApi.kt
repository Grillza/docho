package docho.suwayomi

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.POST
import eu.kanade.tachiyomi.network.await
import eu.kanade.tachiyomi.network.jsonMime
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Credentials
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Talks to the configured Suwayomi server through its GraphQL API (`/api/graphql`). Suwayomi
 * runs Mihon's extensions on a computer or server; Docho can browse and read their sources
 * through it, beside the extensions installed on the device. [client] adds basic authentication
 * (when set) and Docho's user agent to each request for the server, page images and covers
 * included.
 */
@Inject
@SingleIn(AppScope::class)
class SuwayomiApi(
    private val preferences: SuwayomiPreferences,
    private val network: NetworkHelper,
    private val json: Json,
) {

    val client: OkHttpClient by lazy {
        network.client.newBuilder()
            .addInterceptor(AuthInterceptor())
            // The server fetches from the extension's site while answering; give slow ones time.
            .readTimeout(90, TimeUnit.SECONDS)
            .build()
    }

    /** `https://host[:port][/subpath]`, or `null` while no server is configured. */
    fun baseUrlOrNull(): String? = normalizeBaseUrl(preferences.serverUrl.get())

    private fun baseUrl(): String = baseUrlOrNull() ?: throw SuwayomiNotConfiguredException()

    /** A server path such as `/api/v1/manga/3/thumbnail` as a full URL. */
    fun absoluteUrl(path: String): String {
        if (path.startsWith("http://", ignoreCase = true) || path.startsWith("https://", ignoreCase = true)) {
            return path
        }
        return baseUrl() + if (path.startsWith("/")) path else "/$path"
    }

    /** The `Authorization` header for the server, or `null` when it has no sign-in. */
    fun authorization(): String? {
        val username = preferences.username.get()
        if (username.isBlank()) return null
        return Credentials.basic(username, preferences.password.get())
    }

    private val mutableConnection = MutableStateFlow<SuwayomiConnection>(SuwayomiConnection.Unknown)

    /** Outcome of the latest check, shown as the status light in settings. */
    val connection: StateFlow<SuwayomiConnection> = mutableConnection.asStateFlow()

    /** Asks the server for its name and version and publishes the outcome to [connection]. */
    suspend fun checkConnection(): SuwayomiConnection {
        val settings = Triple(preferences.serverUrl.get(), preferences.username.get(), preferences.password.get())
        if (baseUrlOrNull() == null) {
            return SuwayomiConnection.Unknown.also { mutableConnection.value = it }
        }
        mutableConnection.value = SuwayomiConnection.Checking
        val result = try {
            val about = graphQL("query { aboutServer { name version } }").obj("aboutServer")
            SuwayomiConnection.Connected(
                "${about?.string("name") ?: "Suwayomi"} ${about?.string("version").orEmpty()}".trim(),
            )
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            SuwayomiConnection.Failed(e.message ?: e.javaClass.simpleName)
        }
        // Settings may have changed while checking; only the latest check counts.
        if (settings == Triple(preferences.serverUrl.get(), preferences.username.get(), preferences.password.get())) {
            mutableConnection.value = result
        }
        return result
    }

    private suspend fun graphQL(query: String, variables: JsonObject = JsonObject(emptyMap())): JsonObject {
        val body = buildJsonObject {
            put("query", query)
            put("variables", variables)
        }
        val response = client.newCall(POST("${baseUrl()}/api/graphql", body = body.toString().toRequestBody(jsonMime)))
            .await()
        return response.use {
            if (it.code == 401 || it.code == 403) throw SuwayomiAuthException()
            val reply = runCatching { json.parseToJsonElement(it.body.string()).jsonObject }.getOrNull()
                ?: throw IOException("Suwayomi returned an error (HTTP ${it.code})")
            (reply["errors"] as? JsonArray)?.firstOrNull()?.let { error ->
                throw IOException(error.jsonObject.string("message") ?: "GraphQL error")
            }
            reply.obj("data") ?: JsonObject(emptyMap())
        }
    }

    // Sources

    /** The server's sources, apart from its Local source (Docho has its own). */
    suspend fun getSources(): List<SuwayomiSourceInfo> {
        val data = graphQL("query { sources { nodes { id name lang supportsLatest iconUrl contentWarning } } }")
        return data.obj("sources")?.array("nodes").orEmpty().mapNotNull { element ->
            val node = element.jsonObject
            val id = node.string("id")?.toLongOrNull()?.takeIf { it != 0L } ?: return@mapNotNull null
            SuwayomiSourceInfo(
                id = id,
                name = node.string("name").orEmpty(),
                lang = node.string("lang") ?: "other",
                supportsLatest = node.bool("supportsLatest") ?: false,
                iconPath = node.string("iconUrl").orEmpty(),
                isNsfw = node.string("contentWarning") == "NSFW",
            )
        }
    }

    // Browsing and reading

    /** Suwayomi's own manga ids, by source and URL: details and chapters are keyed by them. */
    private val mangaIds = ConcurrentHashMap<String, Int>()

    /** The series' page on the extension's site, by source and URL, for "Open in WebView". */
    private val realUrls = ConcurrentHashMap<String, String>()

    fun realUrl(source: Long, url: String): String? = realUrls["$source|$url"]

    /** A page of a source's listing; [type] is POPULAR, LATEST or SEARCH. */
    suspend fun fetchSourceManga(
        source: Long,
        type: String,
        page: Int,
        query: String? = null,
        filters: JsonArray? = null,
    ): MangasPage {
        val variables = buildJsonObject {
            put("source", source.toString())
            put("type", type)
            put("page", page)
            if (query != null) put("query", query)
            if (!filters.isNullOrEmpty()) put("filters", filters)
        }
        val data = graphQL(
            """
            mutation(${'$'}source: LongString!, ${'$'}type: FetchSourceMangaType!, ${'$'}page: Int!, ${'$'}query: String, ${'$'}filters: [FilterChangeInput!]) {
              fetchSourceManga(input: { source: ${'$'}source, type: ${'$'}type, page: ${'$'}page, query: ${'$'}query, filters: ${'$'}filters }) {
                hasNextPage mangas { $MANGA_FIELDS } } }
            """.trimIndent(),
            variables,
        )
        val payload = data.obj("fetchSourceManga")
        return MangasPage(
            payload?.array("mangas").orEmpty().map { toSManga(source, it.jsonObject) },
            payload?.bool("hasNextPage") ?: false,
        )
    }

    /** The listing entry as an [SManga], remembering Suwayomi's id for it. */
    private fun toSManga(source: Long, node: JsonObject): SManga = SManga.create().also {
        it.url = node.string("url").orEmpty()
        node.int("id")?.let { id -> mangaIds["$source|${it.url}"] = id }
        node.string("realUrl")?.let { url -> realUrls["$source|${it.url}"] = url }
        it.title = node.string("title").orEmpty()
        it.artist = node.string("artist")
        it.author = node.string("author")
        it.description = node.string("description")
        it.genre = node.array("genre")?.mapNotNull { genre -> genre.jsonPrimitive.contentOrNull }?.joinToString()
        it.status = when (node.string("status")) {
            "ONGOING" -> SManga.ONGOING
            "COMPLETED" -> SManga.COMPLETED
            "LICENSED" -> SManga.LICENSED
            "PUBLISHING_FINISHED" -> SManga.PUBLISHING_FINISHED
            "CANCELLED" -> SManga.CANCELLED
            "ON_HIATUS" -> SManga.ON_HIATUS
            else -> SManga.UNKNOWN
        }
        it.thumbnail_url = node.string("thumbnailUrl")?.let(::absoluteUrl)
        it.initialized = node.bool("initialized") ?: false
    }

    /** Suwayomi's id for a series, looked up by source and URL if it hasn't been listed yet. */
    private suspend fun mangaId(source: Long, url: String): Int {
        mangaIds["$source|$url"]?.let { return it }
        val data = graphQL(
            """
            query(${'$'}source: LongString!, ${'$'}url: String!) { mangas(condition: { sourceId: ${'$'}source, url: ${'$'}url }) { nodes { id } } }
            """.trimIndent(),
            buildJsonObject {
                put("source", source.toString())
                put("url", url)
            },
        )
        val id = data.obj("mangas")?.array("nodes")?.firstOrNull()?.jsonObject?.int("id")
            ?: throw IOException("Suwayomi doesn't know this series yet. Find it in the source's listing first.")
        mangaIds["$source|$url"] = id
        return id
    }

    /** Fetches the series from its source through the server: its details, its chapters, or both. */
    suspend fun fetchManga(
        source: Long,
        manga: SManga,
        details: Boolean,
        chapters: Boolean,
    ): Pair<SManga, List<SChapter>?> {
        val id = mangaId(source, manga.url)
        val data = graphQL(
            """
            mutation(${'$'}id: Int!, ${'$'}manga: Boolean!, ${'$'}chapters: Boolean!) {
              fetchMangaAndChapters(input: { id: ${'$'}id, fetchManga: ${'$'}manga, fetchChapters: ${'$'}chapters }) {
                manga { $MANGA_FIELDS }
                chapters { id url name chapterNumber scanlator uploadDate sourceOrder } } }
            """.trimIndent(),
            buildJsonObject {
                put("id", id)
                put("manga", details)
                put("chapters", chapters)
            },
        )
        val payload = data.obj("fetchMangaAndChapters")
        val updated = payload?.obj("manga")?.takeIf { details }
            ?.let { toSManga(source, it).apply { initialized = true } }
            ?: manga
        if (!chapters) return updated to null
        // Suwayomi's sourceOrder counts up from the oldest chapter; Mihon wants the newest first.
        val list = payload?.array("chapters").orEmpty()
            .map { it.jsonObject }
            .sortedByDescending { it.int("sourceOrder") ?: 0 }
            .map { node ->
                SChapter.create().apply {
                    url = node.string("url").orEmpty()
                    name = node.string("name").orEmpty()
                    chapter_number = node.string("chapterNumber")?.toFloatOrNull() ?: -1f
                    scanlator = node.string("scanlator")
                    date_upload = node.string("uploadDate")?.toLongOrNull()?.takeIf { it > 0 } ?: 0L
                    node.int("id")?.let { memo = buildJsonObject { put(MEMO_CHAPTER_ID, it) } }
                }
            }
        return updated to list
    }

    /** The chapter's page images, as full URLs. */
    suspend fun getPages(chapter: SChapter): List<String> {
        val chapterId = chapter.memo[MEMO_CHAPTER_ID]?.jsonPrimitive?.intOrNull ?: chapterId(chapter.url)
        val data = graphQL(
            "mutation(\$id: Int!) { fetchChapterPages(input: { chapterId: \$id }) { pages } }",
            buildJsonObject { put("id", chapterId) },
        )
        return data.obj("fetchChapterPages")?.array("pages").orEmpty()
            .mapNotNull { it.jsonPrimitive.contentOrNull?.let(::absoluteUrl) }
    }

    private suspend fun chapterId(url: String): Int {
        val data = graphQL(
            "query(\$url: String!) { chapters(condition: { url: \$url }) { nodes { id } } }",
            buildJsonObject { put("url", url) },
        )
        return data.obj("chapters")?.array("nodes")?.firstOrNull()?.jsonObject?.int("id")
            ?: throw IOException("Suwayomi doesn't know this chapter. Refresh the series first.")
    }

    // Filters

    /** The source's filters as Suwayomi describes them; turned into [FilterList]s by [toFilterList]. */
    suspend fun getFilters(source: Long): JsonArray {
        val fields = """
            __typename
            ... on HeaderFilter { name }
            ... on SeparatorFilter { name }
            ... on CheckBoxFilter { name checkDefault: default }
            ... on SelectFilter { name selectDefault: default values }
            ... on TriStateFilter { name triDefault: default }
            ... on TextFilter { name textDefault: default }
            ... on SortFilter { name sortDefault: default { index ascending } values }
        """.trimIndent()
        val data = graphQL(
            "query(\$id: LongString!) { source(id: \$id) { filters { $fields ... on GroupFilter { name filters { $fields } } } } }",
            buildJsonObject { put("id", source.toString()) },
        )
        return data.obj("source")?.array("filters") ?: JsonArray(emptyList())
    }

    companion object {
        private const val MANGA_FIELDS =
            "id url realUrl title thumbnailUrl artist author description genre status initialized"

        /** Where a chapter keeps its Suwayomi id, so reading it needs no lookup. */
        const val MEMO_CHAPTER_ID = "docho.suwayomiChapterId"

        private val USER_AGENT = "Docho v${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})"

        /** `http(s)://host[:port][/subpath]` from what the user typed, or `null` if it isn't an address. */
        fun normalizeBaseUrl(input: String): String? {
            var value = input.trim().trimEnd('/')
            if (value.isEmpty()) return null
            if (!value.startsWith("http://", ignoreCase = true) && !value.startsWith("https://", ignoreCase = true)) {
                value = "http://$value"
            }
            val apiIndex = value.indexOf("/api", ignoreCase = true)
            val base = if (apiIndex >= 0) value.substring(0, apiIndex) else value
            return base.takeIf { it.toHttpUrlOrNull() != null }
        }

        fun toFilterList(filters: JsonArray): FilterList = FilterList(filters.map { toFilter(it.jsonObject) })

        private fun toFilter(node: JsonObject): Filter<*> {
            val name = node.string("name").orEmpty()
            return when (node.string("__typename")) {
                "SeparatorFilter" -> Filter.Separator(name)
                "CheckBoxFilter" -> object : Filter.CheckBox(name, node.bool("checkDefault") ?: false) {}
                "SelectFilter" -> object : Filter.Select<String>(
                    name,
                    node.array("values").orEmpty().map { it.jsonPrimitive.content }.toTypedArray(),
                    node.int("selectDefault") ?: 0,
                ) {}
                "TriStateFilter" -> object : Filter.TriState(
                    name,
                    when (node.string("triDefault")) {
                        "INCLUDE" -> STATE_INCLUDE
                        "EXCLUDE" -> STATE_EXCLUDE
                        else -> STATE_IGNORE
                    },
                ) {}
                "TextFilter" -> object : Filter.Text(name, node.string("textDefault").orEmpty()) {}
                "SortFilter" -> object : Filter.Sort(
                    name,
                    node.array("values").orEmpty().map { it.jsonPrimitive.content }.toTypedArray(),
                    node.obj("sortDefault")?.let {
                        Selection(it.int("index") ?: 0, it.bool("ascending") ?: false)
                    },
                ) {}
                "GroupFilter" -> object : Filter.Group<Filter<*>>(
                    name,
                    node.array("filters").orEmpty().map { toFilter(it.jsonObject) },
                ) {}
                else -> Filter.Header(name)
            }
        }

        /** What differs from [defaults], as Suwayomi's `FilterChangeInput`s, by position. */
        fun filterChanges(filters: List<Filter<*>>, defaults: List<Filter<*>>): JsonArray = buildJsonArray {
            filters.forEachIndexed { position, filter ->
                val initial = defaults.getOrNull(position)
                if (filter == initial) return@forEachIndexed
                if (filter is Filter.Group<*>) {
                    val children = filter.state.filterIsInstance<Filter<*>>()
                    val initialChildren = (initial as? Filter.Group<*>)?.state?.filterIsInstance<Filter<*>>().orEmpty()
                    filterChanges(children, initialChildren).forEach { change ->
                        add(
                            buildJsonObject {
                                put("position", position)
                                put("groupChange", change)
                            },
                        )
                    }
                } else {
                    filterChange(filter)?.let { (key, value) ->
                        add(
                            buildJsonObject {
                                put("position", position)
                                put(key, value)
                            },
                        )
                    }
                }
            }
        }

        private fun filterChange(filter: Filter<*>): Pair<String, JsonElement>? = when (filter) {
            is Filter.CheckBox -> "checkBoxState" to JsonPrimitive(filter.state)
            is Filter.Select<*> -> "selectState" to JsonPrimitive(filter.state)
            is Filter.Text -> "textState" to JsonPrimitive(filter.state)
            is Filter.TriState -> "triState" to JsonPrimitive(
                when (filter.state) {
                    Filter.TriState.STATE_INCLUDE -> "INCLUDE"
                    Filter.TriState.STATE_EXCLUDE -> "EXCLUDE"
                    else -> "IGNORE"
                },
            )
            is Filter.Sort -> filter.state?.let {
                "sortState" to buildJsonObject {
                    put("index", it.index)
                    put("ascending", it.ascending)
                }
            }
            else -> null
        }
    }

    private inner class AuthInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val original = chain.request()
            val baseUrl = baseUrlOrNull()
            if (baseUrl == null || !original.url.toString().startsWith(baseUrl, ignoreCase = true)) {
                return chain.proceed(original)
            }
            val request = original.newBuilder().header("User-Agent", USER_AGENT)
            authorization()?.let { request.header("Authorization", it) }
            val response = chain.proceed(request.build())
            if (response.code == 401) {
                mutableConnection.value = SuwayomiConnection.Failed(SuwayomiAuthException().message!!)
            }
            return response
        }
    }
}

/** A source on the server (Suwayomi's `SourceType`), as kept between launches. */
@Serializable
data class SuwayomiSourceInfo(
    val id: Long,
    val name: String,
    val lang: String,
    val supportsLatest: Boolean,
    val iconPath: String,
    val isNsfw: Boolean,
)

class SuwayomiNotConfiguredException :
    IOException("Suwayomi is not set up. Add your server in Settings → Sync.")

class SuwayomiAuthException : IOException("Suwayomi rejected the username or password.")

sealed interface SuwayomiConnection {
    /** No server configured, or not checked yet. */
    data object Unknown : SuwayomiConnection

    data object Checking : SuwayomiConnection

    data class Connected(val server: String) : SuwayomiConnection

    data class Failed(val reason: String) : SuwayomiConnection
}

private fun JsonObject.obj(key: String): JsonObject? = (this[key] as? JsonObject)

private fun JsonObject.array(key: String): JsonArray? = (this[key] as? JsonArray)

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull

private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
