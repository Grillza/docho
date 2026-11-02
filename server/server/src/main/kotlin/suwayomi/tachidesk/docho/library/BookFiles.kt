package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import com.github.junrar.Archive
import eu.kanade.tachiyomi.util.lang.compareToCaseInsensitiveNaturalOrder
import io.github.oshai.kotlinlogging.KotlinLogging
import org.apache.commons.compress.archivers.sevenz.SevenZFile
import org.apache.commons.compress.archivers.zip.ZipFile
import org.apache.pdfbox.Loader
import org.apache.pdfbox.pdmodel.PDDocument
import org.apache.pdfbox.rendering.ImageType
import org.apache.pdfbox.rendering.PDFRenderer
import suwayomi.tachidesk.manga.impl.util.storage.ImageUtil
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.Collections
import javax.imageio.IIOImage
import javax.imageio.ImageIO
import javax.imageio.ImageWriteParam

/**
 * Opens a ZIP reading only its central directory. By default commons-compress also reads every
 * entry's local header, a seek per page, which is slow on a USB hard drive.
 */
fun openZip(file: File): ZipFile = ZipFile.builder().setFile(file).setIgnoreLocalFileHeader(true).get()

/** Which kinds of file a library picks up, as Kavita's library settings name them. */
enum class FileType {
    ARCHIVE,
    EPUB,
    PDF,
    IMAGES,
}

/** How a chapter's file is stored. */
enum class BookFormat(
    val fileType: FileType,
) {
    ZIP(FileType.ARCHIVE),
    RAR(FileType.ARCHIVE),
    SEVEN_ZIP(FileType.ARCHIVE),
    EPUB(FileType.EPUB),
    PDF(FileType.PDF),
    IMAGES(FileType.IMAGES),
    ;

    companion object {
        private val imageExtensions = setOf("jpg", "jpeg", "png", "webp", "gif", "avif", "jxl", "heic", "heif", "bmp")

        fun isImageName(name: String) = name.substringAfterLast('.', "").lowercase() in imageExtensions

        fun of(file: File): BookFormat? =
            if (file.isDirectory) {
                IMAGES.takeIf { file.listFiles().orEmpty().any { it.isFile && isImageName(it.name) } }
            } else {
                when (file.extension.lowercase()) {
                    "cbz", "zip" -> ZIP
                    "cbr", "rar" -> RAR
                    "cb7", "7z" -> SEVEN_ZIP
                    "epub" -> EPUB
                    "pdf" -> PDF
                    else -> null
                }
            }
    }
}

/** A file's page count and metadata, read when a scan finds it new or changed. */
data class Inspection(
    val pageCount: Int,
    val metadata: BookMetadata,
)

/**
 * Opens library files: lists their pages, reads pages and covers, and reads their metadata.
 * PDF pages are rendered to images, and EPUBs that are text rather than pictures are laid out
 * into page images by [EpubTextLayout], so every format reads in an image reader.
 */
object BookFiles {
    private val logger = KotlinLogging.logger { }

    private val fileNameTitle = Regex("""\.(pdf|docx?|indd|qxd|tex|txt)$""", RegexOption.IGNORE_CASE)

    private const val PDF_DPI = 150f
    private const val PDF_COVER_DPI = 50f

    private data class Key(
        val path: String,
        val modified: Long,
    )

    private fun File.key() = Key(absolutePath, lastModified())

    private fun <K, V> lru(size: Int): MutableMap<K, V> =
        Collections.synchronizedMap(
            object : LinkedHashMap<K, V>(size, 0.75f, true) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = this.size > size
            },
        )

    private val pageNames = lru<Key, List<String>>(64)
    private val epubLayouts = lru<Key, EpubTextLayout>(4)

    // ---- Inspecting ----

    fun inspect(
        file: File,
        format: BookFormat,
    ): Inspection =
        when (format) {
            BookFormat.PDF -> {
                Loader.loadPDF(file).use { doc ->
                    val info = doc.documentInformation
                    val fields = mutableMapOf<String, String>()
                    // Many PDFs carry the name of the file they were made from as their title.
                    info
                        ?.title
                        ?.trim()
                        ?.takeIf { title -> title.contains(' ') && !fileNameTitle.containsMatchIn(title) }
                        ?.let { fields["Title"] = it }
                    info?.author?.takeIf { it.isNotBlank() }?.let { fields["Writer"] = it }
                    info?.subject?.takeIf { it.isNotBlank() }?.let { fields["Summary"] = it }
                    info?.keywords?.takeIf { it.isNotBlank() }?.let { fields["Tags"] = it }
                    info?.creationDate?.get(java.util.Calendar.YEAR)?.let { fields["Year"] = it.toString() }
                    Inspection(doc.numberOfPages, BookMetadata(fields))
                }
            }

            BookFormat.EPUB -> {
                openZip(file).use { zip ->
                    val opf = EpubTextLayout.packagePath(zip)
                    val metadata = zip.getEntry(opf)?.let { entry -> zip.getInputStream(entry).use(BookMetadata::fromOpf) }
                    Inspection(-1, metadata ?: BookMetadata.EMPTY)
                }
            }

            BookFormat.ZIP -> {
                openZip(file).use { zip ->
                    val entries = zip.entries.toList()
                    val names = entries.filter { !it.isDirectory && BookFormat.isImageName(it.name) && !it.name.contains("__MACOSX") }
                    val comicInfo =
                        entries
                            .firstOrNull { it.name.equals("ComicInfo.xml", true) || it.name.endsWith("/ComicInfo.xml", true) }
                            ?.let { entry -> zip.getInputStream(entry).use(BookMetadata::fromComicInfo) }
                    Inspection(names.size, comicInfo ?: BookMetadata.EMPTY)
                }
            }

            else -> {
                val names = listPages(file, format)
                val comicInfo =
                    when (format) {
                        BookFormat.IMAGES ->
                            File(file, "ComicInfo.xml").takeIf { it.isFile }?.inputStream()?.use(BookMetadata::fromComicInfo)

                        else -> readEntry(file, format) { it.equals("ComicInfo.xml", ignoreCase = true) || it.endsWith("/ComicInfo.xml", ignoreCase = true) }
                            ?.let { ByteArrayInputStream(it).use(BookMetadata::fromComicInfo) }
                    }
                Inspection(names.size, comicInfo ?: BookMetadata.EMPTY)
            }
        }

    // ---- Pages ----

    fun pageCount(
        file: File,
        format: BookFormat,
    ): Int =
        when (format) {
            BookFormat.PDF -> Loader.loadPDF(file).use { it.numberOfPages }
            BookFormat.EPUB -> epubPages(file).size
            else -> listPages(file, format).size
        }

    fun openPage(
        file: File,
        format: BookFormat,
        index: Int,
    ): Pair<InputStream, String> {
        val bytes =
            when (format) {
                BookFormat.PDF -> return renderPdfPage(file, index, PDF_DPI)
                BookFormat.EPUB -> return openEpubPage(file, index)
                BookFormat.IMAGES -> File(file, listPages(file, format)[index]).readBytes()
                else -> {
                    val name = listPages(file, format)[index]
                    readEntry(file, format) { it == name } ?: throw IllegalStateException("Page $index is missing from ${file.name}")
                }
            }
        return ByteArrayInputStream(bytes) to mimeOf(bytes)
    }

    /** The first page, or a cover image beside it, as an image. */
    fun cover(
        file: File,
        format: BookFormat,
    ): ByteArray? =
        runCatching {
            when (format) {
                BookFormat.PDF -> renderPdfPage(file, 0, PDF_COVER_DPI).first.use { it.readBytes() }

                BookFormat.EPUB -> {
                    openZip(file).use { zip -> EpubTextLayout.coverImage(zip) }
                        ?: openEpubPage(file, 0).first.use { it.readBytes() }
                }

                else -> {
                    val names = listPages(file, format)
                    val coverName =
                        names.firstOrNull { it.substringAfterLast('/').substringBeforeLast('.').equals("cover", true) }
                            ?: names.firstOrNull()
                            ?: return null
                    openPage(file, format, names.indexOf(coverName)).first.use { it.readBytes() }
                }
            }
        }.onFailure { logger.warn(it) { "No cover from ${file.absolutePath}" } }.getOrNull()

    private fun mimeOf(bytes: ByteArray): String = ImageUtil.findImageType(ByteArrayInputStream(bytes))?.mime ?: "image/jpeg"

    /** Image entries in reading order. */
    fun listPages(
        file: File,
        format: BookFormat,
    ): List<String> =
        pageNames.getOrPut(file.key()) {
            val names =
                when (format) {
                    BookFormat.ZIP ->
                        openZip(file).use { zip ->
                            zip.entries.toList().filter { !it.isDirectory && BookFormat.isImageName(it.name) }.map { it.name }
                        }

                    BookFormat.RAR ->
                        Archive(file).use { rar ->
                            rar.fileHeaders.filter { !it.isDirectory && BookFormat.isImageName(it.fileName) }.map { it.fileName }
                        }

                    BookFormat.SEVEN_ZIP ->
                        SevenZFile.builder().setFile(file).get().use { sevenZip ->
                            sevenZip.entries.filter { !it.isDirectory && BookFormat.isImageName(it.name) }.map { it.name }
                        }

                    BookFormat.IMAGES ->
                        file.listFiles().orEmpty().filter { it.isFile && BookFormat.isImageName(it.name) }.map { it.name }

                    BookFormat.EPUB, BookFormat.PDF -> emptyList()
                }
            names
                .filterNot { name -> name.substringAfterLast('/').startsWith('.') || name.contains("__MACOSX") }
                .sortedWith { a, b -> a.compareToCaseInsensitiveNaturalOrder(b) }
        }

    private fun readEntry(
        file: File,
        format: BookFormat,
        matches: (String) -> Boolean,
    ): ByteArray? =
        when (format) {
            BookFormat.ZIP, BookFormat.EPUB ->
                openZip(file).use { zip ->
                    zip.entries.toList().firstOrNull { matches(it.name) }?.let { entry -> zip.getInputStream(entry).use { it.readBytes() } }
                }

            BookFormat.RAR ->
                Archive(file).use { rar ->
                    rar.fileHeaders.firstOrNull { matches(it.fileName) }?.let { header -> rar.getInputStream(header).use { it.readBytes() } }
                }

            BookFormat.SEVEN_ZIP ->
                SevenZFile.builder().setFile(file).get().use { sevenZip ->
                    var entry = sevenZip.nextEntry
                    while (entry != null) {
                        if (!entry.isDirectory && matches(entry.name)) {
                            return@use sevenZip.getInputStream(entry).use { it.readBytes() }
                        }
                        entry = sevenZip.nextEntry
                    }
                    null
                }

            else -> null
        }

    // ---- PDF ----

    private val openPdfs = lru<Key, PDDocument>(3)

    private fun renderPdfPage(
        file: File,
        index: Int,
        dpi: Float,
    ): Pair<InputStream, String> {
        val image =
            synchronized(this) {
                val key = file.key()
                val doc =
                    openPdfs[key] ?: Loader.loadPDF(file).also { doc ->
                        // Closing the one pushed out of the cache.
                        val before = openPdfs.values.toSet()
                        openPdfs[key] = doc
                        (before - openPdfs.values.toSet()).forEach { runCatching { it.close() } }
                    }
                PDFRenderer(doc).renderImageWithDPI(index, dpi, ImageType.RGB)
            }
        return ByteArrayInputStream(encodeJpeg(image)) to "image/jpeg"
    }

    fun encodeJpeg(
        image: BufferedImage,
        quality: Float = 0.88f,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        val writer = ImageIO.getImageWritersByFormatName("jpeg").next()
        ImageIO.createImageOutputStream(out).use { output ->
            writer.output = output
            val params =
                writer.defaultWriteParam.apply {
                    compressionMode = ImageWriteParam.MODE_EXPLICIT
                    compressionQuality = quality
                }
            writer.write(null, IIOImage(image, null, null), params)
            writer.dispose()
        }
        return out.toByteArray()
    }

    fun encodePng(image: BufferedImage): ByteArray = ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()

    // ---- EPUB ----

    private fun epubLayout(file: File): EpubTextLayout = epubLayouts.getOrPut(file.key()) { EpubTextLayout.load(file) }

    private fun epubPages(file: File): List<EpubTextLayout.PageRef> = epubLayout(file).pages

    private fun openEpubPage(
        file: File,
        index: Int,
    ): Pair<InputStream, String> {
        val bytes = epubLayout(file).render(index)
        return ByteArrayInputStream(bytes) to mimeOf(bytes)
    }
}
