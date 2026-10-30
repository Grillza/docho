package docho.sync

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import tachiyomi.core.common.preference.Preference
import tachiyomi.core.common.preference.PreferenceStore
import tachiyomi.core.common.preference.getEnum

@Inject
@SingleIn(AppScope::class)
class ProgressSyncPreferences(
    private val preferenceStore: PreferenceStore,
) {

    /** Where reading progress is synced. */
    val mode: Preference<ProgressSyncMode> = preferenceStore.getEnum("progress_sync_mode", ProgressSyncMode.SOURCE)

    /**
     * Whether progress goes to the KOReader sync server alone. Sources' own syncs stand down,
     * and series whose files KOReader can't match aren't synced at all.
     */
    fun usesKoreader(): Boolean = mode.get() == ProgressSyncMode.KOREADER
}

enum class ProgressSyncMode {
    /** Each series syncs with the server it is read from. */
    SOURCE,

    /** Every series syncs with the KOReader sync server, and nothing else. */
    KOREADER,
}
