import Nuke
import SwiftUI

// MARK: - Categories

/// Mihon's category screen: add, rename, reorder and delete categories.
struct CategoriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var categories: [CategoryRecord] = []
    @State private var editing: CategoryRecord?
    @State private var creating = false
    @State private var deleting: CategoryRecord?
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Edit categories"), showsBack: true)
            if categories.isEmpty {
                EmptyScreen(message: String(localized: "You have no categories. Tap the plus button to create one for organizing your library."))
            } else {
                List {
                    ForEach(categories) { category in
                        HStack(spacing: 16) {
                            MIcon("label").foregroundStyle(m3.onSurfaceVariant)
                            Text(category.name).font(M3Type.bodyLarge).foregroundStyle(m3.onSurface)
                            Spacer()
                            AppBarIcon("edit", label: String(localized: "Rename")) {
                                name = category.name
                                editing = category
                            }
                            AppBarIcon("delete", label: String(localized: "Delete")) { deleting = category }
                        }
                        .foregroundStyle(m3.onSurfaceVariant)
                        .listRowBackground(RoundedRectangle(cornerRadius: 12).fill(m3.surfaceContainerLow).padding(.vertical, 4))
                        .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in
                        var reordered = categories
                        reordered.move(fromOffsets: from, toOffset: to)
                        categories = reordered
                        Task { try? await app.database.reorderCategories(reordered.map(\.id)) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
        .background(m3.surface)
        .overlay(alignment: .bottomTrailing) {
            ExtendedFAB(title: String(localized: "Add"), icon: "add") {
                name = ""
                creating = true
            }
            .padding(16)
        }
        .task {
            do {
                for try await categories in app.database.categories() { self.categories = categories }
            } catch {}
        }
        .m3Dialog(isPresented: $creating, title: String(localized: "Add category")) {
            M3TextField(label: String(localized: "Name"), text: $name).padding(.horizontal, 24).padding(.top, 8)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { creating = false }
            M3TextButton(title: String(localized: "Add")) {
                creating = false
                let name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !categories.contains(where: { $0.name == name }) else { return }
                Task { try? await app.database.createCategory(name) }
            }
        }
        .m3Dialog(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), title: String(localized: "Rename category")) {
            M3TextField(label: String(localized: "Name"), text: $name).padding(.horizontal, 24).padding(.top, 8)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { editing = nil }
            M3TextButton(title: String(localized: "OK")) {
                if let category = editing, !name.isBlank {
                    let name = name
                    Task { try? await app.database.renameCategory(category.id, to: name) }
                }
                editing = nil
            }
        }
        .m3Dialog(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), title: String(localized: "Delete category")) {
            Text("Do you wish to delete the category \"\(deleting?.name ?? "")\"?").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { deleting = nil }
            M3TextButton(title: String(localized: "OK")) {
                if let category = deleting { Task { try? await app.database.deleteCategory(category.id) } }
                deleting = nil
            }
        }
    }
}

// MARK: - Statistics

/// Mihon's statistics: overview, chapters and series counts.
struct StatisticsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var stats: LibraryStatistics?

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Statistics"), showsBack: true)
            if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section(String(localized: "Overview"), [
                            (String(stats.libraryCount), String(localized: "In library"), "collections_bookmark"),
                            (String(stats.completedSeries), String(localized: "Completed"), "local_library"),
                            (String(stats.readDuration), String(localized: "Read duration"), "schedule"),
                        ])
                        section(String(localized: "Titles"), [
                            (String(stats.startedSeries), String(localized: "Started"), "book"),
                            (String(stats.localSeries), String(localized: "Local"), "folder"),
                        ])
                        section(String(localized: "Chapters"), [
                            (String(stats.totalChapters), String(localized: "Total"), "numbers"),
                            (String(stats.readChapters), String(localized: "Read"), "done_all"),
                            (String(stats.downloadedChapters), String(localized: "Downloaded"), "download"),
                        ])
                    }
                    .padding(.bottom, 24)
                }
            } else {
                LoadingScreen()
            }
        }
        .background(m3.surface)
        .task { stats = try? await app.database.statistics() }
    }

    private func section(_ title: String, _ items: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferenceHeader(title: title)
            HStack(spacing: 0) {
                ForEach(items, id: \.1) { value, label, icon in
                    VStack(spacing: 4) {
                        Text(value).font(M3Type.titleLarge).foregroundStyle(m3.onSurface)
                        HStack(spacing: 4) {
                            MIcon(icon, size: 16).foregroundStyle(m3.primary)
                            Text(label).font(M3Type.labelMedium).foregroundStyle(m3.onSurfaceVariant)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 12).fill(m3.surfaceContainerLow))
            .padding(.horizontal, 16)
        }
    }
}

struct LibraryStatistics: Sendable {
    var libraryCount: Int
    var completedSeries: Int
    var startedSeries: Int
    var localSeries: Int
    var totalChapters: Int
    var readChapters: Int
    var downloadedChapters: Int
    var readDuration: String
}

extension AppDatabase {
    func statistics() async throws -> LibraryStatistics {
        try await writer.read { db in
            let library = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series WHERE inLibrary") ?? 0
            let completed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series WHERE inLibrary AND status = 2") ?? 0
            let started = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT series.id) FROM series JOIN chapter ON chapter.seriesId = series.id
                WHERE series.inLibrary AND (chapter.read OR chapter.lastPageRead > 0)
                """) ?? 0
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter JOIN series ON series.id = chapter.seriesId WHERE series.inLibrary") ?? 0
            let read = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter JOIN series ON series.id = chapter.seriesId WHERE series.inLibrary AND chapter.read") ?? 0
            let downloaded = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE isDownloaded") ?? 0
            let seconds = try Int.fetchOne(db, sql: "SELECT SUM(timeRead) FROM history") ?? 0
            let duration = Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow))
            return LibraryStatistics(
                libraryCount: library, completedSeries: completed, startedSeries: started, localSeries: 0,
                totalChapters: total, readChapters: read, downloadedChapters: downloaded, readDuration: duration
            )
        }
    }
}

// MARK: - Data and storage

/// Mihon's Data and storage: storage used by downloads and the image cache.
struct DataStorageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var downloadsSize: Int64 = 0
    @State private var cacheSize = 0
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Data and storage"), showsBack: true)
            ScrollView {
                VStack(spacing: 0) {
                    PreferenceHeader(title: String(localized: "Storage usage"))
                    PreferenceRow(
                        title: String(localized: "Downloads"),
                        subtitle: ByteCountFormatter.string(fromByteCount: downloadsSize, countStyle: .file), icon: "download"
                    )
                    PreferenceRow(
                        title: String(localized: "Clear chapter cache"),
                        subtitle: message ?? String(localized: "Used: \(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))"),
                        icon: "delete_sweep",
                        action: {
                            ImagePipeline.shared.cache.removeAll()
                            (ImagePipeline.shared.configuration.dataCache as? DataCache)?.removeAll()
                            cacheSize = 0
                            message = String(localized: "Cache cleared")
                        }
                    )
                    InfoPreference(text: String(localized: "Backups aren't on iOS yet. Library, progress and settings stay on the device, and reading progress syncs with your servers. To move your servers to another device, use Export settings in Settings → Sync / Self-hosted sources."))
                }
            }
        }
        .background(m3.surface)
        .task {
            downloadsSize = Self.size(of: app.downloads.store.root)
            cacheSize = (ImagePipeline.shared.configuration.dataCache as? DataCache)?.totalSize ?? 0
        }
    }

    static func size(of directory: URL) -> Int64 {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - About

/// Docho's About and help: version, the repository, the privacy policy and help.
struct AboutView: View {
    @Environment(\.m3) private var m3
    @Environment(\.openURL) private var openURL

    static let repository = URL(string: "https://github.com/Grillza/docho")!
    static var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "About"), showsBack: true)
            ScrollView {
                VStack(spacing: 0) {
                    LogoHeader()
                    PreferenceRow(title: String(localized: "Version"), subtitle: "iOS \(Self.version)")
                    PreferenceRow(title: String(localized: "What's new"), action: { openURL(Self.repository.appending(path: "releases")) })
                    PreferenceRow(title: String(localized: "Privacy policy"), action: {
                        openURL(Self.repository.appending(path: "blob/main/docs/privacy-policy.md"))
                    })
                    PreferenceRow(title: String(localized: "Help"), subtitle: String(localized: "Self-hosted sync guide"), action: {
                        openURL(Self.repository.appending(path: "blob/main/docs/self-hosted-sync.md"))
                    })
                    PreferenceRow(title: String(localized: "Getting started"), subtitle: String(localized: "Mihon's guides and troubleshooting"), action: {
                        openURL(URL(string: "https://mihon.app/docs/guides/troubleshooting/")!)
                    })
                    HStack(spacing: 24) {
                        Button { openURL(Self.repository) } label: {
                            MIcon("brand.github", size: 28).foregroundStyle(m3.onSurfaceVariant)
                        }
                        .accessibilityLabel("GitHub")
                    }
                    .padding(24)
                }
            }
        }
        .background(m3.surface)
    }
}

// MARK: - Acknowledgements

/// Docho's Acknowledgements (Android 0.24.0): what the app is built on, in folding sections.
struct AcknowledgementsView: View {
    @Environment(\.m3) private var m3
    @Environment(\.openURL) private var openURL
    @State private var expanded = Set<String>()

    private struct Project: Hashable {
        let name: String
        let note: String
        let url: String
    }

    private let sections: [(String, [Project])] = [
        (String(localized: "Built on"), [
            Project(name: "Mihon", note: String(localized: "The manga reader Dōchō is a fork of"), url: "https://github.com/mihonapp/mihon"),
            Project(name: "Tachiyomi", note: String(localized: "The app Mihon carries on from; its repository is no longer online"), url: "https://github.com/tachiyomiorg"),
        ]),
        (String(localized: "Servers and sync"), [
            Project(name: "Kavita", note: String(localized: "Self-hosted reading server, built in as a source"), url: "https://github.com/Kareadita/Kavita"),
            Project(name: "BookOrbit", note: String(localized: "Self-hosted reading server, built in as a source"), url: "https://github.com/bookorbit/bookorbit"),
            Project(name: "Komga", note: String(localized: "Self-hosted comics server, built in as a source"), url: "https://github.com/gotson/komga"),
            Project(name: "KOReader", note: String(localized: "Its progress sync and the way it fingerprints books"), url: "https://github.com/koreader/koreader"),
            Project(name: "KOReader sync server", note: String(localized: "The sync protocol Dōchō speaks"), url: "https://github.com/koreader/koreader-sync-server"),
        ]),
        (String(localized: "Libraries"), [
            Project(name: "GRDB.swift", note: String(localized: "The SQLite database the library is kept in"), url: "https://github.com/groue/GRDB.swift"),
            Project(name: "Nuke", note: String(localized: "Loads and caches covers and pages"), url: "https://github.com/kean/Nuke"),
        ]),
        (String(localized: "Icons and tools"), [
            Project(name: "Material Symbols", note: String(localized: "The app's icons, as on Android"), url: "https://github.com/google/material-design-icons"),
            Project(name: "Simple Icons", note: String(localized: "Brand icons"), url: "https://github.com/simple-icons/simple-icons"),
            Project(name: "XcodeGen", note: String(localized: "Generates the Xcode project"), url: "https://github.com/yonaskolb/XcodeGen"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Acknowledgements"), showsBack: true)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sections, id: \.0) { title, projects in
                        Button {
                            if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
                        } label: {
                            HStack {
                                Text(title).font(M3Type.titleSmall).foregroundStyle(m3.secondary)
                                Spacer()
                                MIcon(expanded.contains(title) ? "keyboard_arrow_up" : "keyboard_arrow_down").foregroundStyle(m3.onSurfaceVariant)
                            }
                            .padding(16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.ripple)
                        if expanded.contains(title) {
                            ForEach(projects, id: \.self) { project in
                                PreferenceRow(title: project.name, subtitle: project.note, action: {
                                    if let url = URL(string: project.url) { openURL(url) }
                                }) {
                                    MIcon("open_in_new", size: 18).foregroundStyle(m3.onSurfaceVariant)
                                }
                            }
                        }
                        M3Divider()
                    }
                    InfoPreference(text: String(localized: "Dōchō for iOS is released under the Apache License 2.0, like Mihon."))
                }
            }
        }
        .background(m3.surface)
    }
}
