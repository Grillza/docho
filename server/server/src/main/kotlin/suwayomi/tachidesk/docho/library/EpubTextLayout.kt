package suwayomi.tachidesk.docho.library

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import org.apache.commons.compress.archivers.zip.ZipFile
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import java.awt.Color
import java.awt.Font
import java.awt.RenderingHints
import java.awt.font.FontRenderContext
import java.awt.font.LineBreakMeasurer
import java.awt.font.TextAttribute
import java.awt.image.BufferedImage
import java.io.File
import java.net.URLDecoder
import java.text.AttributedString
import javax.imageio.ImageIO

/**
 * Lays out an EPUB as page images. Picture books (each spine page an image) keep their images
 * as pages; text is set in a portrait page with simple typography, so a book reads in the same
 * image reader as manga, on the web and in the app.
 */
class EpubTextLayout private constructor(
    private val file: File,
    private val blocks: List<Block>,
    val pages: List<PageRef>,
) {
    sealed interface Block {
        data class Text(
            val text: String,
            val style: Style,
        ) : Block

        data class Image(
            val entry: String,
            val width: Int,
            val height: Int,
        ) : Block
    }

    enum class Style(
        val size: Float,
        val bold: Boolean,
        val spaceBefore: Float,
        val spaceAfter: Float,
        val centered: Boolean = false,
    ) {
        H1(56f, true, 1.2f, 0.8f, centered = true),
        H2(46f, true, 1.0f, 0.6f),
        H3(40f, true, 0.8f, 0.5f),
        BODY(36f, false, 0f, 0.55f),
    }

    sealed interface Draw {
        /** Characters [start, end) of [block] set as one line at baseline [y]. */
        data class Line(
            val block: Int,
            val start: Int,
            val end: Int,
            val y: Float,
        ) : Draw

        data class Picture(
            val block: Int,
            val x: Int,
            val y: Int,
            val width: Int,
            val height: Int,
        ) : Draw
    }

    sealed interface PageRef {
        /** A whole-page picture, shown as it is. */
        data class FullImage(
            val entry: String,
        ) : PageRef

        data class Laid(
            val draws: List<Draw>,
        ) : PageRef
    }

    fun render(index: Int): ByteArray =
        when (val page = pages[index]) {
            is PageRef.FullImage -> openZip(file).use { zip -> zip.getInputStream(zip.getEntry(page.entry)).use { it.readBytes() } }
            is PageRef.Laid -> renderLaid(page, index)
        }

    private fun renderLaid(
        page: PageRef.Laid,
        index: Int,
    ): ByteArray {
        val image = BufferedImage(WIDTH, HEIGHT, BufferedImage.TYPE_BYTE_GRAY)
        val g = image.createGraphics()
        try {
            g.color = Color.WHITE
            g.fillRect(0, 0, WIDTH, HEIGHT)
            g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON)
            g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_ON)
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BICUBIC)
            g.color = Color(0x1A, 0x1A, 0x1A)
            // Lines are broken again with the same context they were measured with, so they match.
            openZip(file).use { zip ->
                for (draw in page.draws) {
                    when (draw) {
                        is Draw.Line -> {
                            val block = blocks[draw.block] as Block.Text
                            val measurer = LineBreakMeasurer(attributed(block).iterator, frc)
                            measurer.position = draw.start
                            val layout = measurer.nextLayout(TEXT_WIDTH, draw.end, false) ?: continue
                            val x =
                                if (block.style.centered) {
                                    MARGIN_X + (TEXT_WIDTH - layout.advance) / 2f
                                } else {
                                    MARGIN_X.toFloat()
                                }
                            layout.draw(g, x, draw.y)
                        }

                        is Draw.Picture -> {
                            val block = blocks[draw.block] as Block.Image
                            val picture = zip.getEntry(block.entry)?.let { entry -> zip.getInputStream(entry).use { ImageIO.read(it) } }
                            if (picture != null) g.drawImage(picture, draw.x, draw.y, draw.width, draw.height, null)
                        }
                    }
                }
            }
            g.color = Color(0x88, 0x88, 0x88)
            g.font = Font(Font.SERIF, Font.PLAIN, 24)
            val number = (index + 1).toString()
            g.drawString(number, (WIDTH - g.fontMetrics.stringWidth(number)) / 2, HEIGHT - 50)
        } finally {
            g.dispose()
        }
        return BookFiles.encodePng(image)
    }

    companion object {
        const val WIDTH = 1200
        const val HEIGHT = 1800
        private const val MARGIN_X = 96
        private const val MARGIN_TOP = 120
        private const val MARGIN_BOTTOM = 130
        private const val TEXT_WIDTH = (WIDTH - 2 * MARGIN_X).toFloat()
        private const val TEXT_BOTTOM = (HEIGHT - MARGIN_BOTTOM).toFloat()
        private const val LINE_SPACING = 1.45f

        private val frc = FontRenderContext(null, true, true)

        private fun font(style: Style) = Font(Font.SERIF, if (style.bold) Font.BOLD else Font.PLAIN, 1).deriveFont(style.size)

        private fun attributed(block: Block.Text) =
            AttributedString(block.text).apply {
                addAttribute(TextAttribute.FONT, font(block.style))
            }

        /** Path of the OPF package document inside the EPUB. */
        fun packagePath(zip: ZipFile): String {
            val container = zip.getEntry("META-INF/container.xml") ?: return "OEBPS/content.opf"
            val doc = zip.getInputStream(container).use { Jsoup.parse(it, null, "", Parser.xmlParser()) }
            return doc.selectFirst("rootfile")?.attr("full-path")?.ifBlank { null } ?: "OEBPS/content.opf"
        }

        private fun resolve(
            base: String,
            href: String,
        ): String {
            val decoded = URLDecoder.decode(href.substringBefore('#'), Charsets.UTF_8)
            if (decoded.startsWith("/")) return decoded.removePrefix("/")
            val parts = base.split('/').filter { it.isNotEmpty() }.toMutableList()
            for (part in decoded.split('/')) {
                when (part) {
                    "", "." -> {}
                    ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.lastIndex)
                    else -> parts.add(part)
                }
            }
            return parts.joinToString("/")
        }

        private fun dirOf(path: String) = path.substringBeforeLast('/', "")

        /** The cover named in the package document, if it has one. */
        fun coverImage(zip: ZipFile): ByteArray? {
            val opfPath = packagePath(zip)
            val opf = zip.getEntry(opfPath)?.let { entry -> zip.getInputStream(entry).use { Jsoup.parse(it, null, "", Parser.xmlParser()) } } ?: return null
            val items = opf.select("manifest > item")
            val coverId = opf.select("meta[name=cover]").attr("content")
            val item =
                items.firstOrNull { it.attr("properties").split(' ').contains("cover-image") }
                    ?: items.firstOrNull { coverId.isNotEmpty() && it.attr("id") == coverId }
                    ?: return null
            val entry = zip.getEntry(resolve(dirOf(opfPath), item.attr("href"))) ?: return null
            return zip.getInputStream(entry).use { it.readBytes() }
        }

        private val blockSelector = "h1, h2, h3, h4, h5, h6, p, li, blockquote, pre, dt, dd, figcaption, img, image, div, td"

        fun load(file: File): EpubTextLayout =
            openZip(file).use { zip ->
                val opfPath = packagePath(zip)
                val opf = zip.getInputStream(zip.getEntry(opfPath)).use { Jsoup.parse(it, null, "", Parser.xmlParser()) }
                val manifest = opf.select("manifest > item").associateBy { it.attr("id") }
                val spine =
                    opf.select("spine > itemref").mapNotNull { ref ->
                        manifest[ref.attr("idref")]?.let { resolve(dirOf(opfPath), it.attr("href")) }
                    }

                val blocks = mutableListOf<Block>()
                val pages = mutableListOf<PageRef>()
                val composer = Composer(blocks, pages)

                for (docPath in spine) {
                    val entry = zip.getEntry(docPath) ?: continue
                    val doc = zip.getInputStream(entry).use { Jsoup.parse(it, null, "") }
                    val body = doc.body()
                    val images = body.select("img[src], image")
                    val text = body.text().trim()

                    // A picture page: show the image as the page.
                    if (images.size == 1 && text.length < 40) {
                        val image = images.first()!!
                        val src = image.attr("src").ifBlank { image.attr("xlink:href").ifBlank { image.attr("href") } }
                        val imagePath = resolve(dirOf(docPath), src)
                        if (zip.getEntry(imagePath) != null) {
                            composer.flush()
                            pages += PageRef.FullImage(imagePath)
                            continue
                        }
                    }

                    // Elements to set, without those inside another one we set.
                    val chosen = body.select(blockSelector).filter { el -> leaf(el) }
                    val chosenSet = chosen.toSet()
                    val top = chosen.filter { el -> el.parents().none { it in chosenSet } }
                    var first = true
                    for (el in top) {
                        val tag = el.tagName().lowercase()
                        if (tag == "img" || tag == "image") {
                            val src = el.attr("src").ifBlank { el.attr("xlink:href").ifBlank { el.attr("href") } }
                            val imagePath = resolve(dirOf(docPath), src)
                            val size = zip.getEntry(imagePath)?.let { imageSize(zip, it) } ?: continue
                            composer.add(Block.Image(imagePath, size.first, size.second))
                            continue
                        }
                        val content = el.wholeText().replace(Regex("""\s+"""), " ").trim()
                        if (content.isEmpty()) continue
                        val style =
                            when (tag) {
                                "h1" -> Style.H1
                                "h2" -> Style.H2
                                "h3", "h4", "h5", "h6" -> Style.H3
                                else -> Style.BODY
                            }
                        // Chapters start on a new page.
                        if (first && style == Style.H1) composer.flush()
                        first = false
                        composer.add(Block.Text(content, style))
                    }
                    composer.flush()
                }
                composer.flush()
                if (pages.isEmpty()) pages += PageRef.Laid(emptyList())
                EpubTextLayout(file, blocks, pages)
            }

        /** An element to set as one block: images, and text elements holding no other block. */
        private fun leaf(el: Element): Boolean {
            val tag = el.tagName().lowercase()
            if (tag == "img" || tag == "image") return true
            return el.select(blockSelector).none { it !== el }
        }

        private fun imageSize(
            zip: ZipFile,
            entry: org.apache.commons.compress.archivers.zip.ZipArchiveEntry,
        ): Pair<Int, Int>? =
            runCatching {
                zip.getInputStream(entry).use { stream ->
                    ImageIO.createImageInputStream(stream).use { input ->
                        val reader = ImageIO.getImageReaders(input).next()
                        try {
                            reader.input = input
                            reader.getWidth(0) to reader.getHeight(0)
                        } finally {
                            reader.dispose()
                        }
                    }
                }
            }.getOrNull()

        /** Fills pages top to bottom with lines and pictures. */
        private class Composer(
            private val blocks: MutableList<Block>,
            private val pages: MutableList<PageRef>,
        ) {
            private var draws = mutableListOf<Draw>()
            private var y = MARGIN_TOP.toFloat()

            fun flush() {
                if (draws.isNotEmpty()) pages += PageRef.Laid(draws)
                draws = mutableListOf()
                y = MARGIN_TOP.toFloat()
            }

            fun add(block: Block) {
                blocks += block
                val index = blocks.lastIndex
                when (block) {
                    is Block.Image -> addImage(block, index)
                    is Block.Text -> addText(block, index)
                }
            }

            private fun addImage(
                block: Block.Image,
                index: Int,
            ) {
                val maxHeight = TEXT_BOTTOM - MARGIN_TOP
                var width = block.width.toFloat()
                var height = block.height.toFloat()
                // Small images (icons, ornaments) keep their size; large ones fit the text area.
                val scale = minOf(TEXT_WIDTH / width, maxHeight / height, 2f)
                width *= scale
                height *= scale
                if (y + height > TEXT_BOTTOM) flush()
                draws += Draw.Picture(index, (MARGIN_X + (TEXT_WIDTH - width) / 2).toInt(), y.toInt(), width.toInt(), height.toInt())
                y += height + 24f
            }

            private fun addText(
                block: Block.Text,
                index: Int,
            ) {
                val style = block.style
                if (draws.isNotEmpty()) y += style.size * style.spaceBefore
                val measurer = LineBreakMeasurer(attributed(block).iterator, frc)
                val end = block.text.length
                while (measurer.position < end) {
                    val start = measurer.position
                    val layout = measurer.nextLayout(TEXT_WIDTH) ?: break
                    val lineHeight = (layout.ascent + layout.descent + layout.leading) * LINE_SPACING
                    if (y + lineHeight > TEXT_BOTTOM && draws.isNotEmpty()) flush()
                    val baseline = y + layout.ascent
                    draws += Draw.Line(index, start, measurer.position, baseline)
                    y += lineHeight
                }
                y += style.size * style.spaceAfter
            }
        }
    }
}
