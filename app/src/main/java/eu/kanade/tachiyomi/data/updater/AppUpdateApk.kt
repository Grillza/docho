package eu.kanade.tachiyomi.data.updater

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.pm.PackageInfoCompat
import logcat.LogPriority
import tachiyomi.core.common.util.system.logcat
import java.io.File

/** The app update downloaded from Settings → About, which is deleted once it's no use. */
object AppUpdateApk {

    fun file(context: Context): File = File(context.externalCacheDir, "update.apk")

    /**
     * Deletes the downloaded update once this version is at least as new as it, which is the case after it was
     * installed, and also when it can't be read. A newer one that wasn't installed yet is kept for Install.
     */
    fun cleanUp(context: Context) {
        val apk = file(context)
        if (!apk.exists()) return
        try {
            val apkVersion = context.packageManager.getPackageArchiveInfo(apk.path, 0)
                ?.let(PackageInfoCompat::getLongVersionCode)
            val installedVersion = context.packageManager.getPackageInfo(context.packageName, 0)
                .let(PackageInfoCompat::getLongVersionCode)
            if (apkVersion == null || apkVersion <= installedVersion) delete(context)
        } catch (e: PackageManager.NameNotFoundException) {
            logcat(LogPriority.WARN, e)
        }
    }

    fun delete(context: Context) {
        val apk = file(context)
        if (apk.exists() && !apk.delete()) logcat(LogPriority.WARN) { "Couldn't delete ${apk.path}" }
    }
}
