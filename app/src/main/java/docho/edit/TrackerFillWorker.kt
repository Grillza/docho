package docho.edit

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import eu.kanade.tachiyomi.R
import eu.kanade.tachiyomi.data.notification.Notifications
import eu.kanade.tachiyomi.util.system.notificationBuilder
import eu.kanade.tachiyomi.util.system.setForegroundSafely
import eu.kanade.tachiyomi.util.system.workManager
import mihon.app.di.AppGraph
import mihon.core.metro.metroGraph
import tachiyomi.core.common.i18n.stringResource
import tachiyomi.i18n.MR

/** Runs a [TrackerFillScan] with a notification, so a long one goes on after the app is closed. */
class TrackerFillWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    private fun notification(done: Int, total: Int) = applicationContext
        .notificationBuilder(Notifications.CHANNEL_LIBRARY_PROGRESS)
        .setSmallIcon(R.drawable.ic_mihon)
        .setContentTitle(applicationContext.stringResource(MR.strings.tracker_fill_title))
        .setContentText(if (total > 0) "$done / $total" else null)
        .setProgress(total, done, total == 0)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .build()

    private fun foregroundInfo(done: Int, total: Int) = ForegroundInfo(
        NOTIFICATION_ID,
        notification(done, total),
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
    )

    override suspend fun getForegroundInfo() = foregroundInfo(0, 0)

    override suspend fun doWork(): Result {
        setForegroundSafely()
        val scan = applicationContext.metroGraph<AppGraph>().trackerFillScan
        scan.run(
            compareAll = inputData.getBoolean(KEY_COMPARE_ALL, true),
            forgetChoices = inputData.getBoolean(KEY_FORGET_CHOICES, false),
        ) { setForeground(foregroundInfo(it.done, it.total)) }
        docho.dochosync.DochoSyncWorker.syncSoon(applicationContext)
        return Result.success()
    }

    companion object {
        private const val TAG = "TrackerFillScan"
        private const val KEY_COMPARE_ALL = "compareAll"
        private const val KEY_FORGET_CHOICES = "forgetChoices"
        private const val NOTIFICATION_ID = -111

        fun start(context: Context, compareAll: Boolean, forgetChoices: Boolean) {
            val request = OneTimeWorkRequestBuilder<TrackerFillWorker>()
                .addTag(TAG)
                .setInputData(workDataOf(KEY_COMPARE_ALL to compareAll, KEY_FORGET_CHOICES to forgetChoices))
                .build()
            context.workManager.enqueueUniqueWork(TAG, ExistingWorkPolicy.KEEP, request)
        }

        fun stop(context: Context) {
            context.workManager.cancelUniqueWork(TAG)
        }
    }
}
