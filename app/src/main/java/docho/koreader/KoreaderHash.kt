package docho.koreader

import java.io.InputStream
import java.security.MessageDigest

/**
 * KOReader's document hash (`util.partialMD5`): the MD5 of 1 KiB samples taken at offset 0 and
 * at 1 KiB << 2i for i = 0..10, stopping at the end of the file. Servers such as BookOrbit and
 * Kavita store the same hash for each file, which is how a position finds its book.
 */
object KoreaderHash {

    private const val BLOCK_SIZE = 1024

    /** Where the samples of a file of [size] bytes start. */
    fun offsets(size: Long): List<Long> =
        (listOf(0L) + (0..10).map { BLOCK_SIZE.toLong() shl (2 * it) }).filter { it < size }

    /**
     * Hashes a file through [read], which returns up to `length` bytes from `offset`, and
     * reports the file's size once known. The first read is at offset 0.
     */
    suspend fun compute(read: suspend (offset: Long, length: Int) -> Pair<ByteArray, Long>): String {
        val md5 = MessageDigest.getInstance("MD5")
        val (first, size) = read(0L, BLOCK_SIZE)
        md5.update(first)
        offsets(size).drop(1).forEach { offset ->
            md5.update(read(offset, BLOCK_SIZE).first)
        }
        return md5.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Hashes a file that can only be read from the start, such as a download. Reading stops after
     * the last sample, so only that much of the file is transferred. [size] is the file's length
     * if known; without it, the samples run until the stream ends, which gives the same hash.
     */
    suspend fun compute(input: InputStream, size: Long?): String {
        var position = 0L
        return compute { offset, length ->
            while (position < offset) {
                val skipped = input.skip(offset - position)
                if (skipped > 0) {
                    position += skipped
                } else if (input.read() >= 0) {
                    position++
                } else {
                    return@compute ByteArray(0) to (size ?: position)
                }
            }
            val block = ByteArray(length)
            var filled = 0
            while (filled < length) {
                val read = input.read(block, filled, length - filled)
                if (read < 0) break
                filled += read
            }
            position += filled
            block.copyOf(filled) to (size ?: Long.MAX_VALUE)
        }
    }
}
