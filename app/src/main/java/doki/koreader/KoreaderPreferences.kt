package doki.koreader

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import java.util.UUID

@Inject
@SingleIn(AppScope::class)
class KoreaderPreferences(
    private val preferenceStore: PreferenceStore,
) {

    /**
     * Address of the KOReader sync server as KOReader itself is given it, e.g.
     * `http://bookorbit.lan:3010/api/v1/koreader` for BookOrbit.
     */
    val serverUrl: Preference<String> = preferenceStore.getString("koreader_server_url", "")

    val username: Preference<String> = preferenceStore.getString("koreader_username", "")

    /** Kept out of backups, since it is the account's password. */
    val password: Preference<String> = preferenceStore.getString(Preference.privateKey("koreader_password"), "")

    /** Identifies this install to the server, like KOReader's own device id. */
    val deviceId: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("koreader_device_id"),
        "",
    )

    /** Progress writes that could not reach the server yet, keyed by document hash. */
    val pendingProgress: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("koreader_pending_progress"),
        "",
    )

    /** Documents worked out for chapters, see [KoreaderDocumentCache]. */
    val documentCache: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("koreader_document_cache"),
        "",
    )

    fun isConfigured(): Boolean =
        serverUrl.get().isNotBlank() && username.get().isNotBlank() && password.get().isNotBlank()

    /**
     * Erases the server, sign-in and unsent progress; Delete in settings. The device id and the
     * documents worked out from local files stay, as they belong to this install, not the server.
     */
    fun reset() {
        listOf(serverUrl, username, password, pendingProgress).forEach { it.delete() }
    }

    fun deviceId(): String = deviceId.get().ifBlank {
        UUID.randomUUID().toString().replace("-", "").uppercase().also { deviceId.set(it) }
    }
}
