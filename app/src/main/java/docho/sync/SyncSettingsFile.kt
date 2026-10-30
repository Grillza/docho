package docho.sync

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import docho.bookorbit.BookOrbitApi
import docho.bookorbit.BookOrbitPreferences
import docho.kavita.KavitaPreferences
import docho.komga.KomgaPreferences
import docho.koreader.KoreaderPreferences
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import tachiyomi.core.common.preference.Preference
import tachiyomi.domain.backup.service.BackupPreferences
import java.util.Base64

/**
 * Moves the Sync / Self-hosted sources settings, and how often to back up, between installs as a
 * JSON file. With a password the settings are encrypted (see [PasswordCipher]), and one is
 * needed to include sign-in details. What belongs to this install alone (unsent progress, the
 * KOReader device id, the backup folder) stays behind.
 */
@Inject
@SingleIn(AppScope::class)
class SyncSettingsFile(
    kavita: KavitaPreferences,
    bookOrbit: BookOrbitPreferences,
    private val bookOrbitApi: BookOrbitApi,
    komga: KomgaPreferences,
    koreader: KoreaderPreferences,
    progressSync: ProgressSyncPreferences,
    backup: BackupPreferences,
    private val json: Json,
) {

    private val entries: List<Entry> = listOf(
        Entry.Text(kavita.serverUrl),
        Entry.Text(kavita.apiKey, secret = true),
        Entry.Flag(kavita.syncProgress),
        Entry.Text(bookOrbit.serverUrl),
        Entry.Text(bookOrbit.username),
        Entry.Text(bookOrbit.password, secret = true),
        Entry.Flag(bookOrbit.syncProgress),
        Entry.Text(komga.serverUrl),
        Entry.Text(komga.apiKey, secret = true),
        Entry.Flag(komga.syncProgress),
        Entry.Flag(komga.koreaderDownloads),
        Entry.Text(koreader.serverUrl),
        Entry.Text(koreader.username),
        Entry.Text(koreader.password, secret = true),
        Entry.Mode(progressSync.mode),
        Entry.Number(backup.backupInterval),
    )

    /**
     * The settings as a file's text, encrypted with [password] if there is one. Sign-in details
     * are only written to an encrypted file.
     */
    fun export(includeSignIn: Boolean, password: String?): String {
        require(!includeSignIn || !password.isNullOrEmpty()) { "Sign-in details need a password" }
        val settings = buildJsonObject {
            entries
                .filter { includeSignIn || !it.secret }
                .forEach { put(it.key, it.read()) }
        }
        val file = if (password.isNullOrEmpty()) {
            buildJsonObject {
                put(FORMAT_KEY, FORMAT)
                put(VERSION_KEY, VERSION_PLAIN)
                put(SETTINGS_KEY, settings)
            }
        } else {
            val plain = json.encodeToString(JsonObject.serializer(), settings).toByteArray()
            val sealed = PasswordCipher.encrypt(plain, password, ASSOCIATED_DATA)
            buildJsonObject {
                put(FORMAT_KEY, FORMAT)
                put(VERSION_KEY, VERSION_ENCRYPTED)
                put(
                    ENCRYPTION_KEY,
                    buildJsonObject {
                        put("cipher", "AES-256-GCM")
                        put("kdf", "PBKDF2-HMAC-SHA256")
                        put(ITERATIONS_KEY, sealed.iterations)
                        put(SALT_KEY, sealed.salt.toBase64())
                        put(IV_KEY, sealed.iv.toBase64())
                    },
                )
                put(DATA_KEY, sealed.data.toBase64())
            }
        }
        return json.encodeToString(JsonObject.serializer(), file)
    }

    /** Whether [text] is an encrypted settings file, which needs a password to import. */
    fun isEncrypted(text: String): Boolean = runCatching { parse(text)[ENCRYPTION_KEY] != null }.getOrDefault(false)

    /**
     * Applies the settings in [text], returning how many were set. An encrypted file needs its
     * [password]; without one this throws [PasswordRequiredException], and with the wrong one
     * [WrongPasswordException].
     */
    fun import(text: String, password: String? = null): Int {
        val file = parse(text)
        val encryption = file[ENCRYPTION_KEY] as? JsonObject
        val settings = if (encryption == null) {
            file[SETTINGS_KEY] as? JsonObject ?: throw InvalidSyncSettingsFileException()
        } else {
            if (password.isNullOrEmpty()) throw PasswordRequiredException()
            val sealed = try {
                PasswordCipher.Sealed(
                    salt = encryption.getValue(SALT_KEY).jsonPrimitive.content.fromBase64(),
                    iv = encryption.getValue(IV_KEY).jsonPrimitive.content.fromBase64(),
                    iterations = encryption.getValue(ITERATIONS_KEY).jsonPrimitive.int,
                    data = file.getValue(DATA_KEY).jsonPrimitive.content.fromBase64(),
                )
            } catch (e: Exception) {
                throw InvalidSyncSettingsFileException()
            }
            // A made-up file mustn't be able to keep the phone busy for minutes.
            if (sealed.iterations !in 1..MAX_ITERATIONS) throw InvalidSyncSettingsFileException()
            val plain = PasswordCipher.decrypt(sealed, password, ASSOCIATED_DATA)
            try {
                json.parseToJsonElement(plain.decodeToString()).jsonObject
            } catch (e: Exception) {
                throw InvalidSyncSettingsFileException()
            }
        }

        val applied = entries.count { entry -> settings[entry.key]?.let(entry::write) == true }
        // BookOrbit's session belongs to the old account; sign in afresh with the new details.
        bookOrbitApi.signOut()
        return applied
    }

    private fun parse(text: String): JsonObject {
        val file = try {
            json.parseToJsonElement(text).jsonObject
        } catch (e: Exception) {
            throw InvalidSyncSettingsFileException()
        }
        if (file[FORMAT_KEY]?.jsonPrimitive?.content != FORMAT) throw InvalidSyncSettingsFileException()
        return file
    }

    private sealed class Entry(val key: String, val secret: Boolean) {
        abstract fun read(): JsonElement

        /** Sets the value from [element], returning whether it was one this setting takes. */
        abstract fun write(element: JsonElement): Boolean

        class Text(private val preference: Preference<String>, secret: Boolean = false) :
            Entry(preference.key(), secret) {
            override fun read() = JsonPrimitive(preference.get())
            override fun write(element: JsonElement): Boolean {
                val value = (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return false
                preference.set(value)
                return true
            }
        }

        class Flag(private val preference: Preference<Boolean>) : Entry(preference.key(), false) {
            override fun read() = JsonPrimitive(preference.get())
            override fun write(element: JsonElement): Boolean {
                val value = (element as? JsonPrimitive)?.booleanOrNull ?: return false
                preference.set(value)
                return true
            }
        }

        class Number(private val preference: Preference<Int>) : Entry(preference.key(), false) {
            override fun read() = JsonPrimitive(preference.get())
            override fun write(element: JsonElement): Boolean {
                val value = (element as? JsonPrimitive)?.intOrNull ?: return false
                preference.set(value)
                return true
            }
        }

        class Mode(private val preference: Preference<ProgressSyncMode>) : Entry(preference.key(), false) {
            override fun read() = JsonPrimitive(preference.get().name)
            override fun write(element: JsonElement): Boolean {
                val name = (element as? JsonPrimitive)?.content
                val value = ProgressSyncMode.entries.firstOrNull { it.name == name } ?: return false
                preference.set(value)
                return true
            }
        }
    }

    companion object {
        private const val FORMAT_KEY = "format"
        private const val FORMAT = "docho-sync-settings"
        private const val VERSION_KEY = "version"
        private const val VERSION_PLAIN = 1
        private const val VERSION_ENCRYPTED = 2
        private const val SETTINGS_KEY = "settings"
        private const val ENCRYPTION_KEY = "encryption"
        private const val ITERATIONS_KEY = "iterations"
        private const val SALT_KEY = "salt"
        private const val IV_KEY = "iv"
        private const val DATA_KEY = "data"
        private const val MAX_ITERATIONS = 5_000_000

        // Ties the encrypted data to this kind of file.
        private val ASSOCIATED_DATA = "$FORMAT/$VERSION_ENCRYPTED".toByteArray()

        private fun ByteArray.toBase64(): String = Base64.getEncoder().encodeToString(this)

        private fun String.fromBase64(): ByteArray = Base64.getDecoder().decode(this)

        const val MIME_TYPE = "application/json"
        const val FILE_NAME = "docho-sync-settings.json"
    }
}

class InvalidSyncSettingsFileException : IllegalArgumentException("Not a Dōchō sync settings file")

class PasswordRequiredException : IllegalArgumentException("The settings file is encrypted")
