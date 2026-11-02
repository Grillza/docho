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
import mihon.app.di.AppGraph
import mihon.core.metro.metroGraph
import java.util.concurrent.TimeUnit

/**
 * Runs a Dōchō Sync: when the app opens and goes to the background, every hour or so, and when
 * asked to in settings. It's work rather than a coroutine so a sync started as the app closes
 * still finishes.
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

        /** Keeps the hourly sync scheduled while Dōchō Sync is set up and automatic. */
        fun schedulePeriodic(context: Context) {
            val preferences = context.metroGraph<AppGraph>().dochoSyncPreferences
            if (!preferences.isConfigured() || !preferences.automatic.get()) {
                context.workManager.cancelUniqueWork(PERIODIC_TAG)
                return
            }
            val request = PeriodicWorkRequestBuilder<DochoSyncWorker>(1, TimeUnit.HOURS)
                .setConstraints(constraints)
                .addTag(PERIODIC_TAG)
                .build()
            context.workManager.enqueueUniquePeriodicWork(PERIODIC_TAG, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
