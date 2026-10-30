package mihonka.sync

import io.mockk.mockk
import kotlinx.serialization.json.Json
import mihonka.bookorbit.BookOrbitApi
import mihonka.bookorbit.BookOrbitPreferences
import mihonka.kavita.KavitaPreferences
import mihonka.komga.KomgaPreferences
import mihonka.koreader.KoreaderPreferences
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import tachiyomi.core.common.preference.InMemoryPreferenceStore
import tachiyomi.domain.backup.service.BackupPreferences

class SyncSettingsFileTest {

    /** One install's settings, each kept in its own in-memory store. */
    private class Install {
        private val store = InMemoryPreferenceStore()
        val kavita = KavitaPreferences(store)
        val bookOrbit = BookOrbitPreferences(store)
        val komga = KomgaPreferences(store)
        val koreader = KoreaderPreferences(store)
        val progressSync = ProgressSyncPreferences(store)
        val backup = BackupPreferences(store)
        val file = SyncSettingsFile(
            kavita,
            bookOrbit,
            BookOrbitApi(bookOrbit, mockk(relaxed = true), Json),
            komga,
            koreader,
            progressSync,
            backup,
            Json,
        )
    }

    private fun configured() = Install().apply {
        kavita.serverUrl.set("https://kavita.example")
        kavita.apiKey.set("kavita-key")
        kavita.syncProgress.set(false)
        bookOrbit.serverUrl.set("http://bookorbit.lan:3010")
        bookOrbit.username.set("reader")
        bookOrbit.password.set("bookorbit-password")
        komga.serverUrl.set("http://komga.lan:25600")
        komga.apiKey.set("komga-key")
        komga.koreaderDownloads.set(true)
        koreader.serverUrl.set("http://bookorbit.lan:3010/api/v1/koreader")
        koreader.username.set("reader")
        koreader.password.set("koreader-password")
        progressSync.mode.set(ProgressSyncMode.KOREADER)
        backup.backupInterval.set(48)
    }

    @Test
    fun `everything comes across when sign-in details are included`() {
        val from = configured()
        val to = Install()
        to.file.import(from.file.export(includeSignIn = true, password = PASSWORD), PASSWORD)

        assertEquals("https://kavita.example", to.kavita.serverUrl.get())
        assertEquals("kavita-key", to.kavita.apiKey.get())
        assertFalse(to.kavita.syncProgress.get())
        assertEquals("reader", to.bookOrbit.username.get())
        assertEquals("bookorbit-password", to.bookOrbit.password.get())
        assertEquals("komga-key", to.komga.apiKey.get())
        assertEquals(true, to.komga.koreaderDownloads.get())
        assertEquals("koreader-password", to.koreader.password.get())
        assertEquals(ProgressSyncMode.KOREADER, to.progressSync.mode.get())
        assertEquals(48, to.backup.backupInterval.get())
    }

    @Test
    fun `sign-in details stay behind unless asked for, and the ones here are kept`() {
        val text = configured().file.export(includeSignIn = false, password = null)
        listOf("kavita-key", "bookorbit-password", "komga-key", "koreader-password").forEach {
            assertFalse(it in text, "$it was exported")
        }

        val to = Install().apply { komga.apiKey.set("existing-key") }
        to.file.import(text)
        assertEquals("http://komga.lan:25600", to.komga.serverUrl.get())
        assertEquals("existing-key", to.komga.apiKey.get())
    }

    @Test
    fun `an encrypted file hides everything and needs its password`() {
        val text = configured().file.export(includeSignIn = true, password = PASSWORD)
        listOf("kavita.example", "reader", "kavita-key", "komga-key", "koreader-password").forEach {
            assertFalse(it in text, "$it is readable")
        }

        val to = Install()
        assertTrue(to.file.isEncrypted(text))
        assertThrows<PasswordRequiredException> { to.file.import(text) }
        assertThrows<WrongPasswordException> { to.file.import(text, "not the password") }
        assertEquals("", to.kavita.serverUrl.get())

        to.file.import(text, PASSWORD)
        assertEquals("https://kavita.example", to.kavita.serverUrl.get())
    }

    @Test
    fun `an encrypted file that's been changed is refused`() {
        val text = configured().file.export(includeSignIn = false, password = PASSWORD)
        val data = Regex("\"data\":\"(.)").find(text)!!.groups[1]!!
        val changed = text.replaceRange(data.range, if (data.value == "A") "B" else "A")
        assertThrows<WrongPasswordException> { Install().file.import(changed, PASSWORD) }
    }

    @Test
    fun `sign-in details are never written unencrypted`() {
        assertThrows<IllegalArgumentException> { configured().file.export(includeSignIn = true, password = null) }
    }

    @Test
    fun `other files are refused`() {
        val install = Install()
        assertThrows<InvalidSyncSettingsFileException> { install.file.import("not json") }
        assertThrows<InvalidSyncSettingsFileException> { install.file.import("""{"settings":{}}""") }
    }

    private companion object {
        const val PASSWORD = "correct horse battery"
    }
}
