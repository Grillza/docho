package mihonka.komga

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore

@Inject
@SingleIn(AppScope::class)
class KomgaPreferences(
    private val preferenceStore: PreferenceStore,
) {

    /** Address of the Komga server as opened in a browser, e.g. `http://komga.lan:25600`. */
    val serverUrl: Preference<String> = preferenceStore.getString("komga_server_url", "")

    /** Kept out of backups, since it grants access to the Komga account. */
    val apiKey: Preference<String> = preferenceStore.getString(Preference.privateKey("komga_api_key"), "")

    /** Pushes reading progress to Komga and pulls it back, page by page. */
    val syncProgress: Preference<Boolean> = preferenceStore.getBoolean("komga_sync_progress", true)

    /** Progress writes that could not reach the server yet, keyed by Komga book id. */
    val pendingProgress: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("komga_pending_progress"),
        "",
    )

    /**
     * Whether Komga books may be downloaded in full to match them with KOReader, which knows a
     * book by a hash of samples across its file. Komga can't serve part of a file.
     */
    val koreaderDownloads: Preference<Boolean> = preferenceStore.getBoolean("komga_koreader_downloads", false)

    /** Set by "Don't show this again" on the notice explaining [koreaderDownloads]. */
    val koreaderNoticeHidden: Preference<Boolean> = preferenceStore.getBoolean(
        Preference.appStateKey("komga_koreader_notice_hidden"),
        false,
    )

    fun isConfigured(): Boolean = serverUrl.get().isNotBlank() && apiKey.get().isNotBlank()
}
