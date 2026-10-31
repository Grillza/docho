package tachiyomi.domain.release.interactor

import io.kotest.matchers.shouldBe
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tachiyomi.domain.release.model.Release
import tachiyomi.domain.release.service.ReleaseService

class GetApplicationReleaseTest {

    private lateinit var getApplicationRelease: GetApplicationRelease
    private lateinit var releaseService: ReleaseService

    @BeforeEach
    fun beforeEach() {
        releaseService = mockk()

        getApplicationRelease = GetApplicationRelease(releaseService)
    }

    @Test
    fun `When has update but is nightly expect new update`() = runTest {
        val release = Release(
            "r2000",
            "info",
            "http://example.com/release_link",
            "http://example.com/release_link.apk",
        )

        coEvery { releaseService.latest(any()) } returns release

        val result = getApplicationRelease.await(
            GetApplicationRelease.Arguments(
                isFoss = false,
                isNightly = true,
                commitCount = 1000,
                versionName = "",
                repository = "test",
            ),
        )

        (result as GetApplicationRelease.Result.NewUpdate).release shouldBe GetApplicationRelease.Result.NewUpdate(
            release,
        ).release
    }

    @Test
    fun `When has update expect new update`() = runTest {
        val release = Release(
            "v2.0.0",
            "info",
            "http://example.com/release_link",
            "http://example.com/release_link.apk",
        )

        coEvery { releaseService.latest(any()) } returns release

        val result = getApplicationRelease.await(
            GetApplicationRelease.Arguments(
                isFoss = false,
                isNightly = false,
                commitCount = 0,
                versionName = "v1.0.0",
                repository = "test",
            ),
        )

        (result as GetApplicationRelease.Result.NewUpdate).release shouldBe GetApplicationRelease.Result.NewUpdate(
            release,
        ).release
    }

    @Test
    fun `When has no update expect no new update`() = runTest {
        val release = Release(
            "v1.0.0",
            "info",
            "http://example.com/release_link",
            "http://example.com/release_link.apk",
        )

        coEvery { releaseService.latest(any()) } returns release

        val result = getApplicationRelease.await(
            GetApplicationRelease.Arguments(
                isFoss = false,
                isNightly = false,
                commitCount = 0,
                versionName = "v2.0.0",
                repository = "test",
            ),
        )

        result shouldBe GetApplicationRelease.Result.NoNewUpdate
    }

    private suspend fun check(current: String, latest: String, skipPatchUpdates: Boolean = false): Boolean {
        coEvery { releaseService.latest(any()) } returns Release(latest, "info", "link", "link.apk")
        val result = getApplicationRelease.await(
            GetApplicationRelease.Arguments(
                isFoss = false,
                isNightly = false,
                commitCount = 0,
                versionName = current,
                repository = "test",
                skipPatchUpdates = skipPatchUpdates,
            ),
        )
        return result is GetApplicationRelease.Result.NewUpdate
    }

    @Test
    fun `Compares versions numerically, not part by part`() = runTest {
        check("1.0.0", "0.99.0") shouldBe false
        check("0.27.1", "0.28.0") shouldBe true
        check("0.27.9", "0.27.10") shouldBe true
        check("0.27.1-1234", "v0.27.1") shouldBe false
    }

    @Test
    fun `When skipping patch updates expect only minor and major updates`() = runTest {
        check("0.27.1", "0.27.2", skipPatchUpdates = true) shouldBe false
        check("0.27.1", "0.27.2", skipPatchUpdates = false) shouldBe true
        check("0.27.1", "0.28.0", skipPatchUpdates = true) shouldBe true
        check("0.27.1", "1.0.0", skipPatchUpdates = true) shouldBe true
    }
}
