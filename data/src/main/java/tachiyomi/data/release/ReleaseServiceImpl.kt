package tachiyomi.data.release

import android.os.Build
import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.ContributesBinding
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.parseAs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import tachiyomi.domain.release.interactor.GetApplicationRelease
import tachiyomi.domain.release.model.Release
import tachiyomi.domain.release.service.ReleaseService

@Inject
@SingleIn(AppScope::class)
@ContributesBinding(AppScope::class)
class ReleaseServiceImpl(
    private val networkService: NetworkHelper,
    private val json: Json,
) : ReleaseService {

    override suspend fun latest(arguments: GetApplicationRelease.Arguments): Release? {
        val release = withContext(Dispatchers.IO) {
            with(json) {
                networkService.client
                    .newCall(GET("https://api.github.com/repos/${arguments.repository}/releases/latest"))
                    .awaitSuccess()
                    .parseAs<GithubRelease>()
            }
        }

        val downloadLink = getDownloadLink(release = release, isFoss = arguments.isFoss) ?: return null

        // One release carries both apps, and the iOS version can run a patch ahead of Android's,
        // so the Android version comes from the APK names (docho-0.27.1-arm64-v8a.apk), not the tag.
        val version = release.assets.firstNotNullOfOrNull { apkVersionRegex.find(it.name)?.groupValues?.get(1) }
            ?.let { "v$it" }
            ?: release.version

        return Release(
            version = version,
            info = androidSection(release.info).replace(gitHubUsernameMentionRegex) { mention ->
                "[${mention.value}](https://github.com/${mention.value.substring(1)})"
            },
            releaseLink = release.releaseLink,
            downloadLink = downloadLink,
        )
    }

    /** The "## Android" part of the notes, without the iOS one. Falls back to the whole body. */
    private fun androidSection(body: String): String {
        val text = body.substringBeforeLast("<!-->")
        val start = androidHeadingRegex.find(text) ?: return text
        val rest = text.substring(start.range.last + 1)
        val end = nextH2Regex.find(rest)?.range?.first ?: rest.length
        return rest.substring(0, end).trim()
    }

    private fun getDownloadLink(release: GithubRelease, isFoss: Boolean): String? {
        val map = release.assets.associate { asset ->
            BUILD_TYPES.find { "-$it" in asset.name } to asset.downloadLink
        }

        return if (!isFoss) {
            map[Build.SUPPORTED_ABIS[0]] ?: map[null]
        } else {
            map[FOSS]
        }
    }

    companion object {
        private const val FOSS = "foss"
        private val BUILD_TYPES = listOf(FOSS, "arm64-v8a", "armeabi-v7a", "x86_64", "x86")

        private val apkVersionRegex = """-(\d+\.\d+\.\d+)-[^/]*\.apk$""".toRegex()
        private val androidHeadingRegex = """^##\s+Android\b.*$""".toRegex(RegexOption.MULTILINE)
        private val nextH2Regex = """^##\s""".toRegex(RegexOption.MULTILINE)

        /**
         * Regular expression that matches a mention to a valid GitHub username, like it's
         * done in GitHub Flavored Markdown. It follows these constraints:
         *
         * - Alphanumeric with single hyphens (no consecutive hyphens)
         * - Cannot begin or end with a hyphen
         * - Max length of 39 characters
         *
         * Reference: https://stackoverflow.com/a/30281147
         */
        private val gitHubUsernameMentionRegex = """\B@([a-z0-9](?:-(?=[a-z0-9])|[a-z0-9]){0,38}(?<=[a-z0-9]))"""
            .toRegex(RegexOption.IGNORE_CASE)
    }
}
