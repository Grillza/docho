package docho.dochosync

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import docho.suwayomi.SuwayomiPreferences
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import java.util.UUID

/**
 * Dōchō Sync, built into Dōchō Server: whether to sync with it, and where syncing is up to. The
 * server's address and login are Dōchō Server's ([SuwayomiPreferences]).
 */
@Inject
@SingleIn(AppScope::class)
class DochoSyncPreferences(
    private val preferenceStore: PreferenceStore,
    private val server: SuwayomiPreferences,
) {

    /** Whether to sync with the Dōchō Server set up under Dōchō Server / Suwayomi. */
    val enabled: Preference<Boolean> = preferenceStore.getBoolean("docho_sync_enabled", true)

    /** Whether to sync while reading, when the app opens and closes, and every so often in between. */
    val automatic: Preference<Boolean> = preferenceStore.getBoolean("docho_sync_automatic", true)

    /** The server's change number this device has caught up to; 0 until the first sync. */
    val since: Preference<Long> = preferenceStore.getLong(Preference.appStateKey("docho_sync_since"), 0)

    val lastSyncAt: Preference<Long> = preferenceStore.getLong(Preference.appStateKey("docho_sync_last_at"), 0)

    val lastError: Preference<String> = preferenceStore.getString(Preference.appStateKey("docho_sync_last_error"), "")

    private val deviceId: Preference<String> = preferenceStore.getString(
        Preference.appStateKey("docho_sync_device_id"),
        "",
    )

    init {
        migrate()
    }

    fun serverUrl(): String = server.serverUrl.get()

    /** The server's basic-auth login; blank when it has none. */
    fun username(): String = server.username.get()

    fun password(): String = server.password.get()

    fun isConfigured(): Boolean = enabled.get() && server.isConfigured()

    fun deviceId(): String = deviceId.get().ifBlank {
        UUID.randomUUID().toString().also { deviceId.set(it) }
    }

    /** Forgets where syncing is up to, so the next sync is a first sync, which merges. */
    fun reset() {
        listOf(since, lastSyncAt, lastError).forEach { it.delete() }
    }

    /**
     * Before 0.32.1 Dōchō Sync had its own server address and account. The address moves to Dōchō
     * Server's settings if those are empty; the account isn't needed any more.
     */
    private fun migrate() {
        val oldUrl = preferenceStore.getString("docho_sync_server_url", "")
        if (oldUrl.get().isBlank()) return
        if (server.serverUrl.get().isBlank()) server.serverUrl.set(oldUrl.get())
        listOf(
            oldUrl,
            preferenceStore.getString("docho_sync_username", ""),
            preferenceStore.getString(Preference.privateKey("docho_sync_password"), ""),
            preferenceStore.getString(Preference.privateKey("docho_sync_token"), ""),
        ).forEach { it.delete() }
    }
}
