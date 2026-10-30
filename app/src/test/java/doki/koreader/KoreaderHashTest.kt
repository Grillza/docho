package doki.koreader

import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.io.FilterInputStream

class KoreaderHashTest {

    private fun file(size: Int) = ByteArray(size) { ((it * 31 + 7) % 251).toByte() }

    private fun hash(data: ByteArray): String = runBlocking {
        KoreaderHash.compute { offset, length ->
            val start = offset.toInt()
            data.copyOfRange(start, minOf(start + length, data.size)) to data.size.toLong()
        }
    }

    // Expected values come from a separate implementation of KOReader's util.partialMD5.
    @Test
    fun `a file smaller than one block is hashed whole`() {
        assertEquals("20d7e49d5efbe12563021059740872ae", hash(file(500)))
    }

    @Test
    fun `samples stop at the end of the file`() {
        assertEquals("724b94d04f9ceeab34ab28718b86062d", hash(file(70_000)))
    }

    @Test
    fun `a chapter-sized archive matches KOReader`() {
        assertEquals("26776a0cc9a8a34badc67cca03828cd4", hash(file(5_000_000)))
    }

    /** A download: skips nothing, so every byte up to a sample has to be read. */
    private fun download(data: ByteArray) = object : FilterInputStream(ByteArrayInputStream(data)) {
        var bytesRead = 0
        override fun skip(n: Long): Long = 0
        override fun read(): Int = super.read().also { if (it >= 0) bytesRead++ }
        override fun read(b: ByteArray, off: Int, len: Int): Int =
            super.read(b, off, minOf(len, 300)).also { if (it > 0) bytesRead += it }
    }

    @Test
    fun `a streamed file hashes the same, with or without its size`() {
        listOf(500, 70_000, 5_000_000).forEach { size ->
            val data = file(size)
            assertEquals(hash(data), runBlocking { KoreaderHash.compute(download(data), size.toLong()) })
            assertEquals(hash(data), runBlocking { KoreaderHash.compute(download(data), null) })
        }
    }

    @Test
    fun `a stream is read only up to the last sample`() {
        val data = file(5_000_000)
        val stream = download(data)
        runBlocking { KoreaderHash.compute(stream, data.size.toLong()) }
        // The last sample before 5 MB starts at 4 MiB.
        assertEquals((4L shl 20) + 1024, stream.bytesRead.toLong())
    }

    @Test
    fun `samples are taken where KOReader takes them`() {
        assertEquals(listOf(0L, 1024L, 4096L, 16384L, 65536L), KoreaderHash.offsets(70_000))
        assertEquals(1024L shl 20, KoreaderHash.offsets(Long.MAX_VALUE).last())
    }
}
