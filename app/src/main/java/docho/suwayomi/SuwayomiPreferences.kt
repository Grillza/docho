package docho.suwayomi

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore

@Inject
@SingleIn(AppScope::class)
class SuwayomiPreferences(
    private val preferenceStore: PreferenceStore,
) {

    /** Address of the Suwayomi server as opened in a browser, e.g. `http://192.168.1.20:4567`. */
    val serverUrl: Preference<String> = preferenceStore.getString("suwayomi_server_url", "")

    /** For servers with basic authentication turned on; empty when it's off. */
    val username: Preference<String> = preferenceStore.getString("suwayomi_username", "")

    /** Kept out of backups, since it grants access to the server. */
    val password: Preference<String> = preferenceStore.getString(Preference.privateKey("suwayomi_password"), "")

    /** Whether the server's NSFW sources are listed. */
    val showNsfw: Preference<Boolean> = preferenceStore.getBoolean("suwayomi_show_nsfw", false)

    /** The server's sources as last fetched, so series from them open before it has answered. */
    val sourcesCache: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("suwayomi_sources_cache"),
        "",
    )

    fun isConfigured(): Boolean = SuwayomiApi.normalizeBaseUrl(serverUrl.get()) != null

    /** Erases this server's settings and sign-in; Delete in settings. */
    fun reset() {
        listOf(serverUrl, username, password, showNsfw, sourcesCache).forEach { it.delete() }
    }
}
