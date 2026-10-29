package mihonka.bookorbit

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore

@Inject
@SingleIn(AppScope::class)
class BookOrbitPreferences(
    private val preferenceStore: PreferenceStore,
) {

    /** Address of the BookOrbit server as opened in a browser, e.g. `http://bookorbit.lan:3010`. */
    val serverUrl: Preference<String> = preferenceStore.getString("bookorbit_server_url", "")

    val username: Preference<String> = preferenceStore.getString("bookorbit_username", "")

    /** Kept out of backups, since it is the account's password. */
    val password: Preference<String> = preferenceStore.getString(Preference.privateKey("bookorbit_password"), "")

    /**
     * The session BookOrbit gave this install. Kept so the app doesn't sign in, and add a new
     * session to the account, every time it starts.
     */
    val refreshToken: Preference<String> = preferenceStore.getString(
        Preference.privateKey("bookorbit_refresh_token"),
        "",
    )

    /** Pushes reading progress to BookOrbit and pulls it back, page by page. */
    val syncProgress: Preference<Boolean> = preferenceStore.getBoolean("bookorbit_sync_progress", true)

    /** Progress writes that could not reach the server yet, keyed by BookOrbit file id. */
    val pendingProgress: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("bookorbit_pending_progress"),
        "",
    )

    fun isConfigured(): Boolean =
        serverUrl.get().isNotBlank() && username.get().isNotBlank() && password.get().isNotBlank()

    /** Erases this server's settings, sign-in and unsent progress; Delete in settings. */
    fun reset() {
        listOf(serverUrl, username, password, refreshToken, syncProgress, pendingProgress).forEach { it.delete() }
    }
}
