package docho.dochosync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkerParameters
import eu.kanade.tachiyomi.util.system.workManager
import kotlinx.coroutines.delay
import mihon.app.di.AppGraph
import mihon.core.metro.metroGraph
import java.util.concurrent.TimeUnit

/**
 * Runs a Dōchō Sync: when the app opens and goes to the background, every few minutes while it's
 * open ([syncWhileOpen]), about every 15 minutes in the background at best, and when asked to in
 * settings. It's work rather than a coroutine so a sync started as the app closes still finishes.
 */
class DochoSyncWorker(context: Context, workerParams: WorkerParameters) :
    CoroutineWorker(context, workerParams) {

    private val graph: AppGraph = context.metroGraph()

    override suspend fun doWork(): Result {
        return when (graph.dochoSync.sync()) {
            is DochoSync.Status.Failed -> if (runAttemptCount < 3) Result.retry() else Result.failure()
            else -> Result.success()
        }
    }

    companion object {
        private const val TAG = "DochoSync"
        private const val PERIODIC_TAG = "DochoSyncPeriodic"
        private const val SOON_TAG = "DochoSyncSoon"

        /** How long after a change [syncSoon] syncs; changes made meanwhile go in the same sync. */
        private const val SOON_SECONDS = 15L

        /** The shortest time Android's periodic work runs at. */
        private const val MIN_BACKGROUND_MINUTES = 15L
        private const val CHECK_MILLIS = 60_000L

        private val constraints = Constraints(requiredNetworkType = NetworkType.CONNECTED)

        /** Syncs soon, if Dōchō Sync is set up (and automatic, unless [always]). */
        fun syncNow(context: Context, always: Boolean = false) {
            val preferences = context.metroGraph<AppGraph>().dochoSyncPreferences
            if (!preferences.isConfigured() || (!always && !preferences.automatic.get())) return
            val request = OneTimeWorkRequestBuilder<DochoSyncWorker>()
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .addTag(TAG)
                .build()
            // A sync already waiting picks up whatever changed by the time it starts
            context.workManager.enqueueUniqueWork(TAG, ExistingWorkPolicy.KEEP, request)
        }

        /**
         * Syncs a few seconds after something changed here, such as the page being read, so other
         * devices and Dōchō Server see it while you read. Changes made before then go in the same
         * sync instead of each starting one.
         */
        fun syncSoon(context: Context) {
            val preferences = context.metroGraph<AppGraph>().dochoSyncPreferences
            if (!preferences.isConfigured() || !preferences.automatic.get()) return
            val request = OneTimeWorkRequestBuilder<DochoSyncWorker>()
                .setConstraints(constraints)
                .setInitialDelay(SOON_SECONDS, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .addTag(SOON_TAG)
                .build()
            context.workManager.enqueueUniqueWork(SOON_TAG, ExistingWorkPolicy.KEEP, request)
        }

        /**
         * Keeps the background sync scheduled while Dōchō Sync is set up and automatic, as often as
         * the setting says, down to the 15 minutes that's the most Android allows.
         */
        fun schedulePeriodic(context: Context) {
            val preferences = context.metroGraph<AppGraph>().dochoSyncPreferences
            if (!preferences.isConfigured() || !preferences.automatic.get()) {
                context.workManager.cancelUniqueWork(PERIODIC_TAG)
                return
            }
            val minutes = preferences.intervalMinutes.get().toLong().coerceAtLeast(MIN_BACKGROUND_MINUTES)
            val request = PeriodicWorkRequestBuilder<DochoSyncWorker>(minutes, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .addTag(PERIODIC_TAG)
                .build()
            // UPDATE so an installed app moves off the old hourly schedule, and picks up the setting.
            context.workManager.enqueueUniquePeriodicWork(PERIODIC_TAG, ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        /**
         * Syncs every so often for as long as it runs, which is while the app is open. Android's
         * periodic work can't go below 15 minutes or be relied on, so this does the job while there's
         * someone to see it. A sync that just happened for another reason (such as reading) counts,
         * so reading doesn't add any syncs. Checks each minute, so a changed setting applies soon.
         */
        suspend fun syncWhileOpen(context: Context) {
            val preferences = context.metroGraph<AppGraph>().dochoSyncPreferences
            var lastAsked = System.currentTimeMillis()
            while (true) {
                delay(CHECK_MILLIS)
                val interval = preferences.intervalMinutes.get() * 60_000L
                val now = System.currentTimeMillis()
                if (now - maxOf(lastAsked, preferences.lastSyncAt.get()) >= interval) {
                    lastAsked = now
                    syncNow(context)
                }
            }
        }
    }
}
