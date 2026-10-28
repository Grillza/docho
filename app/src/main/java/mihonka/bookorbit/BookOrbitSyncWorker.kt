package mihonka.bookorbit

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkerParameters
import eu.kanade.tachiyomi.util.system.workManager
import mihon.app.di.AppGraph
import mihon.core.metro.metroGraph
import tachiyomi.core.common.util.lang.withIOContext
import java.util.concurrent.TimeUnit

/**
 * Delivers progress that was queued while BookOrbit couldn't be reached. Android
 * starts it once there is a network again, even if the app was closed in the meantime.
 */
class BookOrbitSyncWorker(context: Context, workerParams: WorkerParameters) :
    CoroutineWorker(context, workerParams) {

    private val graph: AppGraph = context.metroGraph()

    override suspend fun doWork(): Result {
        val done = withIOContext { graph.bookOrbitSync.syncQueued() }
        return if (done) Result.success() else Result.retry()
    }

    companion object {
        private const val TAG = "BookOrbitSync"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<BookOrbitSyncWorker>()
                .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                .addTag(TAG)
                .build()
            // An already waiting run delivers whatever is queued by the time it starts.
            context.workManager.enqueueUniqueWork(TAG, ExistingWorkPolicy.KEEP, request)
        }
    }
}
