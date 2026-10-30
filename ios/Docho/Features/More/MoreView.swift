import SwiftUI

/// Mihon's More tab: the logo, Downloaded only and Incognito mode, then the download queue,
/// categories, statistics, data and storage, settings, acknowledgements and about.
struct MoreView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var queue: [DownloadQueueItem] = []

    var body: some View {
        @Bindable var preferences = app.preferences
        ScrollView {
            VStack(spacing: 0) {
                LogoHeader()
                SwitchPreference(
                    title: String(localized: "Downloaded only"),
                    subtitle: String(localized: "Filters all entries in your library"),
                    icon: "cloud_off", isOn: $preferences.downloadedOnly
                )
                SwitchPreference(
                    title: String(localized: "Incognito mode"),
                    subtitle: String(localized: "Pauses reading history"),
                    icon: "eyeglasses_2", isOn: $preferences.incognitoMode
                )
                M3Divider()
                link(.downloadQueue, String(localized: "Download queue"), icon: "download", subtitle: queueSummary)
                    .accessibilityIdentifier("more.downloads")
                link(.categories, String(localized: "Categories"), icon: "label")
                link(.statistics, String(localized: "Statistics"), icon: "query_stats")
                link(.dataStorage, String(localized: "Data and storage"), icon: "storage")
                M3Divider()
                link(.settings, String(localized: "Settings"), icon: "settings")
                    .accessibilityIdentifier("more.settings")
                link(.acknowledgements, String(localized: "Acknowledgements"), icon: "favorite")
                link(.about, String(localized: "About and help"), icon: "info")
            }
        }
        .background(m3.surface)
        .task {
            do {
                for try await queue in app.database.downloadQueue() { self.queue = queue }
            } catch {}
        }
    }

    private var queueSummary: String? {
        let pending = queue.count
        if app.preferences.downloadsPaused {
            return pending == 0 ? String(localized: "Paused") : String(localized: "Paused • \(pending) remaining")
        }
        return pending == 0 ? nil : String(localized: "\(pending) remaining")
    }

    private func link(_ route: Route, _ title: String, icon: String, subtitle: String? = nil) -> some View {
        NavigationLink(value: route) {
            PreferenceRow(title: title, subtitle: subtitle, icon: icon)
        }
        .buttonStyle(.ripple)
    }
}

/// Docho's wordmark (同調 with どうちょう), as on Android's More tab.
struct LogoHeader: View {
    @Environment(\.m3) private var m3

    var body: some View {
        VStack(spacing: 0) {
            Image("wordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 96)
                .foregroundStyle(m3.onSurface)
                .padding(.vertical, 32)
                .accessibilityLabel("Dōchō")
            M3Divider()
        }
    }
}

// MARK: - Download queue

/// Mihon's download queue: the chapters waiting, with pause/resume, and cancel per chapter.
struct DownloadQueueView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var queue: [DownloadQueueItem] = []
    @State private var downloaded: [DownloadedSeries] = []

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Download queue"), showsBack: true) {
                if !queue.isEmpty {
                    OverflowMenu {
                        if queue.contains(where: { $0.download.state == .failed }) {
                            Button(String(localized: "Retry failed")) { Task { await app.downloads.retryFailed() } }
                        }
                        Button(String(localized: "Cancel all"), role: .destructive) { Task { await app.downloads.cancelAll() } }
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if queue.isEmpty {
                        EmptyScreen(message: String(localized: "No downloads")).frame(minHeight: 200)
                    }
                    ForEach(groupedQueue, id: \.name) { group in
                        Text("\(group.name) (\(group.items.count))")
                            .font(M3Type.bodyMedium)
                            .foregroundStyle(m3.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.items) { item in queueRow(item) }
                    }
                    if !downloaded.isEmpty {
                        PreferenceHeader(title: String(localized: "On this device"))
                        ForEach(downloaded) { series in
                            NavigationLink(value: Route.series(series.id)) {
                                PreferenceRow(
                                    title: series.name,
                                    subtitle: series.chapters == 1 ? String(localized: "1 chapter") : String(localized: "\(series.chapters) chapters"),
                                    icon: "folder"
                                ) {
                                    Text(ByteCountFormatter.string(fromByteCount: app.downloads.store.size(seriesId: series.id), countStyle: .file))
                                        .font(M3Type.bodySmall)
                                        .foregroundStyle(m3.onSurfaceVariant)
                                }
                            }
                            .buttonStyle(.ripple)
                            .contextMenu {
                                Button(String(localized: "Delete downloads"), role: .destructive) {
                                    Task { await app.downloads.deleteSeries(series.id) }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 88)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !queue.isEmpty {
                let paused = app.preferences.downloadsPaused
                ExtendedFAB(title: paused ? String(localized: "Resume") : String(localized: "Pause"), icon: paused ? "play_arrow.fill" : "pause.fill") {
                    app.preferences.downloadsPaused.toggle()
                    let pause = app.preferences.downloadsPaused
                    Task { await app.downloads.setPaused(pause) }
                }
                .padding(16)
            }
        }
        .background(m3.surface)
        .task {
            do {
                for try await queue in app.database.downloadQueue() { self.queue = queue }
            } catch {}
        }
        .task {
            do {
                for try await series in app.database.downloadedSeries() { downloaded = series }
            } catch {}
        }
    }

    /// Mihon groups the queue by source.
    private var groupedQueue: [(name: String, items: [DownloadQueueItem])] {
        let grouped = Dictionary(grouping: queue) { app.sources.source($0.source).name }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private func queueRow(_ item: DownloadQueueItem) -> some View {
        HStack(spacing: 8) {
            MIcon("drag_handle").foregroundStyle(m3.onSurfaceVariant)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.seriesName).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface).lineLimit(1)
                Text(item.chapterName).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant).lineLimit(1)
                HStack {
                    ProgressView(value: item.download.progress).tint(m3.primary)
                    Text(item.download.state == .failed
                        ? String(localized: "Failed")
                        : "\(item.download.pagesDone)/\(max(item.download.pagesTotal, 0))")
                        .font(M3Type.bodySmall)
                        .foregroundStyle(item.download.state == .failed ? m3.error : m3.onSurfaceVariant)
                }
                if let error = item.download.error, item.download.state == .failed {
                    Text(error).font(M3Type.bodySmall).foregroundStyle(m3.error).lineLimit(2)
                }
            }
            OverflowMenu {
                Button(String(localized: "Cancel"), role: .destructive) {
                    Task { await app.downloads.cancel([(item.download.seriesId, item.download.chapterId)]) }
                }
            }
            .foregroundStyle(m3.onSurfaceVariant)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Part A's download bar: while the queue has chapters, the one downloading, its pages, and
/// pause and cancel; tapping it opens the queue. Shown above the navigation bar.
struct DownloadBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let onOpen: () -> Void
    @State private var queue: [DownloadQueueItem] = []

    var body: some View {
        Group {
            if let state = DownloadBarState(queue: queue, paused: app.preferences.downloadsPaused) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.title)
                                .font(M3Type.labelLarge)
                                .foregroundStyle(m3.onSurface)
                                .lineLimit(1)
                            ProgressView(value: state.progress).tint(m3.primary)
                            Text(state.subtitle)
                                .font(M3Type.labelSmall)
                                .foregroundStyle(m3.onSurfaceVariant)
                                .lineLimit(1)
                        }
                        AppBarIcon(state.paused ? "play_arrow.fill" : "pause.fill", label: state.paused ? String(localized: "Resume") : String(localized: "Pause")) {
                            app.preferences.downloadsPaused.toggle()
                            let pause = app.preferences.downloadsPaused
                            Task { await app.downloads.setPaused(pause) }
                        }
                        .foregroundStyle(m3.onSurfaceVariant)
                        AppBarIcon("close", label: String(localized: "Cancel all")) {
                            Task { await app.downloads.cancelAll() }
                        }
                        .foregroundStyle(m3.onSurfaceVariant)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(m3.surfaceContainerHigh))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("downloads.bar")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: queue.isEmpty)
        .task {
            do {
                for try await queue in app.database.downloadQueue() { self.queue = queue }
            } catch {}
        }
    }
}

/// What the download bar shows for a queue (tested on its own).
struct DownloadBarState: Equatable {
    var title: String
    var subtitle: String
    var progress: Double
    var paused: Bool

    init?(queue: [DownloadQueueItem], paused: Bool) {
        guard !queue.isEmpty else { return nil }
        let active = queue.first { $0.download.state == .downloading } ?? queue.first { $0.download.state == .queued } ?? queue[0]
        let name = "\(active.seriesName) - \(active.chapterName)"
        title = name.count > 30 ? String(name.prefix(29)) + "…" : name
        self.paused = paused
        progress = active.download.progress
        let others = queue.count - 1
        var parts: [String] = []
        if paused {
            parts.append(String(localized: "Paused"))
        } else if active.download.state == .failed {
            parts.append(String(localized: "Failed"))
        } else if active.download.state == .downloading, active.download.pagesTotal > 0 {
            parts.append(String(localized: "Page \(active.download.pagesDone) of \(active.download.pagesTotal)"))
        } else {
            parts.append(String(localized: "Waiting"))
        }
        if others > 0 { parts.append(String(localized: "+\(others) queued")) }
        subtitle = parts.joined(separator: " • ")
    }
}
