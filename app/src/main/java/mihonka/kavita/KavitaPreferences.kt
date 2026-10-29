package mihonka.kavita

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore

@Inject
@SingleIn(AppScope::class)
class KavitaPreferences(
    private val preferenceStore: PreferenceStore,
) {

    /**
     * Base address of the Kavita server as entered by the user, e.g. `https://kavita.example.com`.
     * Anything after `/api` (an OPDS link, for instance) is stripped when it is used.
     */
    val serverUrl: Preference<String> = preferenceStore.getString("kavita_server_url", "")

    /** Kept out of backups, since it grants full access to the Kavita account. */
    val apiKey: Preference<String> = preferenceStore.getString(Preference.privateKey("kavita_api_key"), "")

    /** Pushes reading progress to Kavita and pulls it back, page by page. */
    val syncProgress: Preference<Boolean> = preferenceStore.getBoolean("kavita_sync_progress", true)

    /** Progress writes that could not reach the server yet, keyed by Kavita chapter id. */
    val pendingProgress: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("kavita_pending_progress"),
        "",
    )

    fun isConfigured(): Boolean = serverUrl.get().isNotBlank() && apiKey.get().isNotBlank()

    /** Erases this server's settings, sign-in and unsent progress; Delete in settings. */
    fun reset() {
        listOf(serverUrl, apiKey, syncProgress, pendingProgress).forEach { it.delete() }
    }
}
