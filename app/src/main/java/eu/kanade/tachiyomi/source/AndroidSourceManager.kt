package eu.kanade.tachiyomi.source

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.ContributesBinding
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.data.download.DownloadManager
import eu.kanade.tachiyomi.extension.ExtensionManager
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import mihonka.bookorbit.BookOrbitPreferences
import mihonka.bookorbit.BookOrbitSource
import mihonka.kavita.KavitaPreferences
import mihonka.kavita.KavitaSource
import mihonka.komga.KomgaPreferences
import mihonka.komga.KomgaSource
import tachiyomi.domain.source.model.StubSource
import tachiyomi.domain.source.repository.StubSourceRepository
import tachiyomi.domain.source.service.SourceManager
import tachiyomi.source.local.LocalSource
import java.util.concurrent.ConcurrentHashMap

@Inject
@SingleIn(AppScope::class)
@ContributesBinding(AppScope::class)
class AndroidSourceManager(
    private val extensionManager: ExtensionManager,
    private val sourceRepository: StubSourceRepository,
    private val localSource: LocalSource,
    private val kavitaSource: KavitaSource,
    private val kavitaPreferences: KavitaPreferences,
    private val bookOrbitSource: BookOrbitSource,
    private val bookOrbitPreferences: BookOrbitPreferences,
    private val komgaSource: KomgaSource,
    private val komgaPreferences: KomgaPreferences,
    private val downloadManager: Lazy<DownloadManager>,
) : SourceManager {

    private val scope = CoroutineScope(Job() + Dispatchers.IO)

    /**
     * Null until the extensions have loaded, so that nothing observes the empty seed value.
     */
    private val sourcesMapFlow = MutableStateFlow<Map<Long, Source>?>(null)

    private val stubSourcesMap = ConcurrentHashMap<Long, StubSource>()

    override val sources: Flow<List<Source>> = sourcesMapFlow
        .filterNotNull()
        .map { it.values.toList() }

    init {
        scope.launch {
            // Kavita, BookOrbit and Komga are built in; each is offered as a source only while a
            // server is configured.
            val kavitaConfigured = combine(
                kavitaPreferences.serverUrl.changes(),
                kavitaPreferences.apiKey.changes(),
            ) { _, _ -> kavitaPreferences.isConfigured() }
                .distinctUntilChanged()
            val bookOrbitConfigured = combine(
                bookOrbitPreferences.serverUrl.changes(),
                bookOrbitPreferences.username.changes(),
                bookOrbitPreferences.password.changes(),
            ) { _, _, _ -> bookOrbitPreferences.isConfigured() }
                .distinctUntilChanged()
            val komgaConfigured = combine(
                komgaPreferences.serverUrl.changes(),
                komgaPreferences.apiKey.changes(),
            ) { _, _ -> komgaPreferences.isConfigured() }
                .distinctUntilChanged()
            val builtInsConfigured = combine(kavitaConfigured, bookOrbitConfigured, komgaConfigured, ::Triple)

            combine(extensionManager.loadedExtensionsFlow, builtInsConfigured, ::Pair)
                .collectLatest { (extensions, builtIns) ->
                    val (kavitaEnabled, bookOrbitEnabled, komgaEnabled) = builtIns
                    val mutableMap = ConcurrentHashMap<Long, Source>(
                        mapOf(LocalSource.ID to localSource),
                    )
                    registerStubSource(StubSource.from(kavitaSource))
                    if (kavitaEnabled) {
                        mutableMap[KavitaSource.ID] = kavitaSource
                        kavitaSource.refreshLibraries()
                    }
                    registerStubSource(StubSource.from(bookOrbitSource))
                    if (bookOrbitEnabled) {
                        mutableMap[BookOrbitSource.ID] = bookOrbitSource
                        bookOrbitSource.refreshLibraries()
                    }
                    registerStubSource(StubSource.from(komgaSource))
                    if (komgaEnabled) {
                        mutableMap[KomgaSource.ID] = komgaSource
                        komgaSource.refreshLibraries()
                    }
                    extensions.forEach { extension ->
                        extension.sources.forEach {
                            mutableMap[it.id] = it
                            registerStubSource(StubSource.from(it))
                        }
                    }
                    sourcesMapFlow.value = mutableMap
                }
        }

        scope.launch {
            sourceRepository.subscribeAll()
                .collectLatest { sources ->
                    sources.forEach {
                        stubSourcesMap[it.id] = it
                    }
                }
        }
    }

    /**
     * Awaits the extensions to have loaded before returning the sources.
     */
    private suspend fun sourcesMap(): Map<Long, Source> = sourcesMapFlow.filterNotNull().first()

    override suspend fun get(sourceKey: Long): Source? {
        return sourcesMap()[sourceKey]
    }

    override suspend fun getOrStub(sourceKey: Long): Source {
        return sourcesMap()[sourceKey] ?: stubSourcesMap.getOrPut(sourceKey) {
            createStubSource(sourceKey)
        }
    }

    override suspend fun getAll(): List<Source> {
        return sourcesMap().values.toList()
    }

    override suspend fun getOnlineSources(): List<HttpSource> {
        return sourcesMap().values.filterIsInstance<HttpSource>()
    }

    override suspend fun getStubSources(): List<StubSource> {
        val onlineSourceIds = getOnlineSources().map { it.id }
        return stubSourcesMap.values.filterNot { it.id in onlineSourceIds }
    }

    private fun registerStubSource(source: StubSource) {
        scope.launch {
            val dbSource = sourceRepository.getStubSource(source.id)
            if (dbSource == source) return@launch
            sourceRepository.upsertStubSource(source.id, source.lang, source.name)
            if (dbSource != null) {
                downloadManager.value.renameSource(dbSource, source)
            }
        }
    }

    private suspend fun createStubSource(id: Long): StubSource {
        sourceRepository.getStubSource(id)?.let {
            return it
        }
        extensionManager.getSourceData(id)?.let {
            registerStubSource(it)
            return it
        }
        return StubSource(id = id, lang = "", name = "")
    }
}
