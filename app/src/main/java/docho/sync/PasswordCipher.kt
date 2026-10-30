package docho.sync

import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypts with a password: AES-256-GCM, with the key stretched from the password by
 * PBKDF2-HMAC-SHA256 over a random salt, so guessing passwords is slow. GCM also detects a
 * wrong password or a changed file, as [WrongPasswordException].
 */
internal object PasswordCipher {

    /** OWASP's recommendation for PBKDF2-HMAC-SHA256; a second or so on a phone. */
    const val ITERATIONS = 600_000

    private const val KEY_BITS = 256
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    class Sealed(val salt: ByteArray, val iv: ByteArray, val iterations: Int, val data: ByteArray)

    /** [associated] isn't hidden, but is checked: changing it makes decrypting fail. */
    fun encrypt(plain: ByteArray, password: String, associated: ByteArray, iterations: Int = ITERATIONS): Sealed {
        val random = SecureRandom()
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val cipher = cipher(Cipher.ENCRYPT_MODE, password, salt, iv, iterations, associated)
        return Sealed(salt, iv, iterations, cipher.doFinal(plain))
    }

    fun decrypt(sealed: Sealed, password: String, associated: ByteArray): ByteArray {
        val cipher = cipher(Cipher.DECRYPT_MODE, password, sealed.salt, sealed.iv, sealed.iterations, associated)
        return try {
            cipher.doFinal(sealed.data)
        } catch (e: AEADBadTagException) {
            throw WrongPasswordException()
        }
    }

    private fun cipher(
        mode: Int,
        password: String,
        salt: ByteArray,
        iv: ByteArray,
        iterations: Int,
        associated: ByteArray,
    ): Cipher {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, KEY_BITS)
        val key = try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, iv))
            updateAAD(associated)
        }
    }
}

class WrongPasswordException : IllegalArgumentException("Wrong password")
