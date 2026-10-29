package mihonka.acknowledgements

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import dev.icerock.moko.resources.StringResource
import eu.kanade.presentation.components.AppBar
import eu.kanade.presentation.more.settings.screen.about.OpenSourceLicensesScreen
import eu.kanade.presentation.more.settings.widget.CollapsiblePreferenceGroupHeader
import eu.kanade.presentation.more.settings.widget.TextPreferenceWidget
import eu.kanade.presentation.util.Screen
import mihon.icons.materialsymbols.MaterialSymbols
import mihon.icons.materialsymbols.automirroredrounded.OpenInNew
import tachiyomi.i18n.MR
import tachiyomi.presentation.core.components.material.Scaffold
import tachiyomi.presentation.core.components.material.padding
import tachiyomi.presentation.core.i18n.stringResource
import androidx.compose.foundation.layout.padding as paddingModifier

/**
 * The projects Mihonka is made from, each with a link to its source. The full list of libraries
 * and their licences is one tap further, generated at build time.
 */
class AcknowledgementsScreen : Screen() {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val uriHandler = LocalUriHandler.current
        // Sections start folded to their names, so the list fits on a screen.
        val expandedSections = rememberSaveable(
            saver = listSaver(save = { it.toList() }, restore = { it.toMutableStateList() }),
        ) { mutableStateListOf<String>() }

        Scaffold(
            topBar = { scrollBehavior ->
                AppBar(
                    title = stringResource(MR.strings.label_acknowledgements),
                    navigateUp = navigator::pop,
                    scrollBehavior = scrollBehavior,
                )
            },
        ) { contentPadding ->
            LazyColumn(contentPadding = contentPadding) {
                item {
                    Text(
                        text = stringResource(MR.strings.acknowledgements_intro),
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.paddingModifier(
                            horizontal = MaterialTheme.padding.medium,
                            vertical = MaterialTheme.padding.small,
                        ),
                    )
                }
                SECTIONS.forEach { section ->
                    val key = section.title.resourceId.toString()
                    val expanded = key in expandedSections
                    item(key = key) {
                        CollapsiblePreferenceGroupHeader(
                            title = stringResource(section.title),
                            expanded = expanded,
                            onToggle = { if (expanded) expandedSections.remove(key) else expandedSections.add(key) },
                            summary = section.projects.joinToString { it.name },
                        )
                    }
                    if (!expanded) return@forEach
                    items(section.projects, key = { it.url }) { project ->
                        TextPreferenceWidget(
                            title = project.name,
                            subtitle = project.description,
                            widget = {
                                Icon(
                                    imageVector = MaterialSymbols.AutoMirroredRounded.OpenInNew,
                                    contentDescription = null,
                                )
                            },
                            onPreferenceClick = { uriHandler.openUri(project.url) },
                        )
                    }
                }
                item {
                    TextPreferenceWidget(
                        title = stringResource(MR.strings.acknowledgements_all_licenses),
                        subtitle = stringResource(MR.strings.acknowledgements_all_licenses_summary),
                        onPreferenceClick = { navigator.push(OpenSourceLicensesScreen()) },
                    )
                }
            }
        }
    }

    private class Project(val name: String, val description: String, repo: String) {
        /** `owner/repo`, or a full address for a project that isn't one repository. */
        val url: String = if (repo.startsWith("https://")) repo else "https://github.com/$repo"
    }

    private class Section(val title: StringResource, val projects: List<Project>)

    private companion object {
        val SECTIONS = listOf(
            Section(
                MR.strings.acknowledgements_built_on,
                listOf(
                    Project("Mihon", "The manga reader Mihonka is a fork of", "mihonapp/mihon"),
                    Project(
                        "Tachiyomi",
                        "The app Mihon carries on from; its repository is no longer online",
                        "https://github.com/tachiyomiorg",
                    ),
                ),
            ),
            Section(
                MR.strings.acknowledgements_servers,
                listOf(
                    Project("Kavita", "Self-hosted reading server, built in as a source", "Kareadita/Kavita"),
                    Project("BookOrbit", "Self-hosted reading server, built in as a source", "bookorbit/bookorbit"),
                    Project("Komga", "Self-hosted comics server, built in as a source", "gotson/komga"),
                    Project("KOReader", "Its progress sync and the way it fingerprints books", "koreader/koreader"),
                    Project(
                        "KOReader sync server",
                        "The sync protocol Mihonka speaks",
                        "koreader/koreader-sync-server",
                    ),
                ),
            ),
            Section(
                MR.strings.acknowledgements_libraries,
                listOf(
                    Project("Kotlin", "The language Mihonka is written in", "JetBrains/kotlin"),
                    Project("kotlinx.coroutines", "Background work", "Kotlin/kotlinx.coroutines"),
                    Project("kotlinx.serialization", "Reading and writing JSON", "Kotlin/kotlinx.serialization"),
                    Project("kotlinx-datetime", "Dates and times", "Kotlin/kotlinx-datetime"),
                    Project("AndroidX and Jetpack Compose", "Android's libraries and UI toolkit", "androidx/androidx"),
                    Project(
                        "Material Components for Android",
                        "Material Design widgets",
                        "material-components/material-components-android",
                    ),
                    Project("OkHttp", "Every network request", "lysine-dev/okhttp"),
                    Project("Okio", "Fast input and output", "lysine-dev/okio"),
                    Project("Coil", "Loading covers and images", "coil-kt/coil"),
                    Project("SQLDelight", "The library database", "sqldelight/sqldelight"),
                    Project("Voyager", "Navigation between screens", "adrielcafe/voyager"),
                    Project("Metro", "Dependency injection", "ZacSweers/metro"),
                    Project("Injekt", "Dependency injection for older code", "kohesive/injekt"),
                    Project("moko-resources", "Translated text", "icerockdev/moko-resources"),
                    Project("jsoup", "Reading web pages", "jhy/jsoup"),
                    Project("RxJava", "Used by older extensions", "ReactiveX/RxJava"),
                    Project("QuickJS for Java", "Running JavaScript for extensions", "zhanghai/quickjs-java"),
                    Project(
                        "libarchive for Android",
                        "Opening CBZ, CBR and other archives",
                        "zhanghai/libarchive-android",
                    ),
                    Project("image-decoder", "Decoding manga pages", "tachiyomiorg/image-decoder"),
                    Project(
                        "Subsampling Scale Image View",
                        "Zooming into large pages",
                        "mihonapp/subsampling-scale-image-view",
                    ),
                    Project("UniFile", "Storage access", "mihon/unifile"),
                    Project("PhotoView", "Zooming images", "Baseflow/PhotoView"),
                    Project("DirectionalViewPager", "The paged reader", "tachiyomiorg/DirectionalViewPager"),
                    Project("FlexibleAdapter", "Lists in the reader", "davideas/FlexibleAdapter"),
                    Project("Shizuku API", "Installing extensions without prompts", "RikkaApps/Shizuku-API"),
                    Project("Apollo Kotlin", "GraphQL for trackers", "apollographql/apollo-kotlin"),
                    Project("Conscrypt", "Modern TLS on older Android versions", "google/conscrypt"),
                    Project("MaterialKolor", "Colour themes", "jordond/MaterialKolor"),
                    Project("AboutLibraries", "The licence list", "mikepenz/AboutLibraries"),
                    Project(
                        "Multiplatform Markdown Renderer",
                        "Formatted text in descriptions and changelogs",
                        "mikepenz/multiplatform-markdown-renderer",
                    ),
                    Project("Compose Rich Editor", "Editing notes", "MohamedRejeb/compose-rich-editor"),
                    Project("Reorderable", "Drag-to-reorder lists", "Calvin-LL/Reorderable"),
                    Project("swipe", "Swipe actions on chapters", "saket/swipe"),
                    Project("compose-webview", "Web views in Compose", "KevinnZou/compose-webview"),
                    Project("Material Motion Compose", "Screen transitions", "fornewid/material-motion-compose"),
                    Project("Grid Layout for Compose", "Grids", "cheonjaeung/gridlayout-compose"),
                    Project("xmlutil", "Reading XML such as ComicInfo", "pdvrieze/xmlutil"),
                    Project("string-similarity-kotlin", "Matching titles", "aallam/string-similarity-kotlin"),
                    Project("java-nat-sort", "Natural sorting, as in file names", "gpanther/java-nat-sort"),
                    Project("DiskLruCache", "The image cache", "JakeWharton/DiskLruCache"),
                    Project("Logcat", "Logging", "square/logcat"),
                    Project("Firebase", "Crash reports, in builds that include them", "firebase/firebase-android-sdk"),
                ),
            ),
            Section(
                MR.strings.acknowledgements_icons,
                listOf(
                    Project("Material Symbols", "Most of the app's icons", "google/material-design-icons"),
                    Project("Simple Icons", "Brand icons", "simple-icons/simple-icons"),
                    Project("Lucide", "The orbit in BookOrbit's logo", "lucide-icons/lucide"),
                ),
            ),
            Section(
                MR.strings.acknowledgements_tools,
                listOf(
                    Project("Gradle", "Building the app", "gradle/gradle"),
                    Project("Spotless", "Code formatting", "diffplug/spotless"),
                    Project("ktlint", "Kotlin style checks", "ktlint/ktlint"),
                    Project("JUnit", "Tests", "junit-team/junit-framework"),
                    Project("MockK", "Test doubles", "mockk/mockk"),
                    Project("Kotest", "Test assertions", "kotest/kotest"),
                    Project("LeakCanary", "Finding memory leaks in debug builds", "square/leakcanary"),
                    Project("Claude Code", "Helped write Mihonka's own features", "anthropics/claude-code"),
                ),
            ),
        )
    }
}
