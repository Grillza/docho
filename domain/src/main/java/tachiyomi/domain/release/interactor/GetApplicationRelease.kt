package tachiyomi.domain.release.interactor

import dev.zacsweers.metro.Inject
import tachiyomi.domain.release.model.Release
import tachiyomi.domain.release.service.ReleaseService

@Inject
class GetApplicationRelease(
    private val service: ReleaseService,
) {
    suspend fun await(arguments: Arguments): Result {
        val release = service.latest(arguments) ?: return Result.NoNewUpdate

        if (arguments.isNightly) {
            val newCount = release.version.replace("[^\\d]".toRegex(), "").toIntOrNull() ?: return Result.NoNewUpdate
            return if (newCount > arguments.commitCount) Result.NewUpdate(release) else Result.NoNewUpdate
        }

        val current = parseVersion(arguments.versionName) ?: return Result.NoNewUpdate
        val latest = parseVersion(release.version) ?: return Result.NoNewUpdate

        return when {
            compareVersions(latest, current) <= 0 -> Result.NoNewUpdate
            // Only the patch number changed (0.27.1 to 0.27.2): a bug fix the user opted out of.
            arguments.skipPatchUpdates && latest.take(2) == current.take(2) -> Result.NoNewUpdate
            else -> Result.NewUpdate(release)
        }
    }

    data class Arguments(
        val isFoss: Boolean,
        val isNightly: Boolean,
        val commitCount: Int,
        val versionName: String,
        val repository: String,
        val forceCheck: Boolean = false,
        val skipPatchUpdates: Boolean = false,
    )

    sealed interface Result {
        data class NewUpdate(val release: Release) : Result
        data object NoNewUpdate : Result
        data object OsTooOld : Result
    }

    companion object {
        private val versionRegex = """\d+(?:\.\d+)*""".toRegex()

        /**
         * The first dotted number in [name], padded to major.minor.patch:
         * "v0.27.1" and "0.27.1-1234" both give [0, 27, 1].
         */
        fun parseVersion(name: String): List<Int>? {
            val parts = versionRegex.find(name)?.value?.split(".")?.map { it.toIntOrNull() ?: return null }
                ?: return null
            return (parts + List(3) { 0 }).take(maxOf(3, parts.size))
        }

        fun compareVersions(a: List<Int>, b: List<Int>): Int {
            for (i in 0 until maxOf(a.size, b.size)) {
                val diff = a.getOrElse(i) { 0 } - b.getOrElse(i) { 0 }
                if (diff != 0) return diff
            }
            return 0
        }
    }
}
