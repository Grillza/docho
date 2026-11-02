package docho.dochosync

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import java.util.UUID

/** The Dōchō Sync server this install signs in to, and where its syncing is up to. */
@Inject
@SingleIn(AppScope::class)
class DochoSyncPreferences(
    private val preferenceStore: PreferenceStore,
) {

    val serverUrl: Preference<String> = preferenceStore.getString("docho_sync_server_url", "")

    val username: Preference<String> = preferenceStore.getString("docho_sync_username", "")

    /** Kept out of backups, since it is the account's password. */
    val password: Preference<String> = preferenceStore.getString(Preference.privateKey("docho_sync_password"), "")

    /** The server's sign-in for this device. */
    val token: Preference<String> = preferenceStore.getString(Preference.privateKey("docho_sync_token"), "")

    /** Whether to sync when the app opens and closes, and every so often in between. */
    val automatic: Preference<Boolean> = preferenceStore.getBoolean("docho_sync_automatic", true)

    /** The server's change number this device has caught up to; 0 until the first sync. */
    val since: Preference<Long> = preferenceStore.getLong(Preference.appStateKey("docho_sync_since"), 0)

    val lastSyncAt: Preference<Long> = preferenceStore.getLong(Preference.appStateKey("docho_sync_last_at"), 0)

    val lastError: Preference<String> = preferenceStore.getString(Preference.appStateKey("docho_sync_last_error"), "")

    private val deviceId: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("docho_sync_device_id"),
        "",
    )

    fun isConfigured(): Boolean =
        serverUrl.get().isNotBlank() && username.get().isNotBlank() && password.get().isNotBlank()

    fun deviceId(): String = deviceId.get().ifBlank {
        UUID.randomUUID().toString().also { deviceId.set(it) }
    }

    /** Forgets the server and the sync state, so a new server starts with a first sync. */
    fun reset() {
        listOf(serverUrl, username, password, token, since, lastSyncAt, lastError).forEach { it.delete() }
    }
}
