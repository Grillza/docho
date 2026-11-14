package eu.kanade.tachiyomi.ui.reader.viewer.webgpu

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ca.mpreg.webgpuviewer.renderer.ImageFilterWgsl
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The bundled filter parses and runs on this device's GPU, and only while a page is shrunk. */
@RunWith(AndroidJUnit4::class)
class ReduceMoireFilterTest {

    private fun filter(): ImageFilterWgsl {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = context.assets.open("webgpu/reduce_moire.wgsl").use { it.readBytes().decodeToString() }
        return ImageFilterWgsl(source, "Reduce moiré")
    }

    @Test
    fun validatesOnDevice() = runBlocking {
        filter().validate()
    }

    @Test
    fun appliesOnlyWhenShrinking() {
        val filter = filter()
        assertTrue(filter.applies(0.72f))
        assertTrue(filter.applies(0.4f))
        assertFalse(filter.applies(1f))
        assertFalse(filter.applies(2f))
        assertTrue("halo ${filter.halo(0.72f)}", filter.halo(0.72f) >= 21)
    }
}
