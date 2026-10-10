import SwiftUI

/// The download queue, and the series with chapters on the device.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var queue: [DownloadQueueItem] = []
    @State private var series: [DownloadedSeries] = []
    @State private var sizes: [Int: Int64] = [:]
    @State private var loaded = false

    var body: some View {
        List {
            if !queue.isEmpty {
                Section {
                    ForEach(queue) { item in
                        QueueRow(item: item)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await app.downloads.cancel([(item.download.seriesId, item.download.chapterId)]) }
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Queue")
                        Spacer()
                        if queue.contains(where: { $0.download.state == .failed }) {
                            Button("Retry Failed") { Task { await app.downloads.retryFailed() } }
                                .font(.footnote)
                        }
                    }
                }
            }
            if !series.isEmpty {
                Section("On This Device") {
                    ForEach(series) { series in
                        NavigationLink {
                            SeriesView(app: app, seriesId: series.id, title: series.name)
                        } label: {
                            SeriesDownloadRow(series: series, size: sizes[series.id])
                        }
                        .accessibilityIdentifier("downloads.series")
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await app.downloads.deleteSeries(series.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if loaded && queue.isEmpty && series.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download chapters from a series to read them without a network.")
                )
            }
        }
        .navigationTitle("Downloads")
        .task {
            do {
                for try await queue in app.database.downloadQueue() { self.queue = queue }
            } catch {}
        }
        .task {
            do {
                for try await series in app.database.downloadedSeries() {
                    self.series = series
                    loaded = true
                    await measure(series)
                }
            } catch {}
        }
    }

    /// Folder sizes, read off the main actor.
    private func measure(_ series: [DownloadedSeries]) async {
        let store = app.downloads.store
        let ids = series.map(\.id)
        sizes = await Task.detached {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, store.size(seriesId: $0)) })
        }.value
    }
}

private struct QueueRow: View {
    let item: DownloadQueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.seriesName).font(.subheadline).foregroundStyle(.secondary)
            Text(item.chapterName)
            switch item.download.state {
            case .queued:
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
            case .downloading:
                ProgressView(value: item.download.progress) {
                    Text("\(item.download.pagesDone) of \(item.download.pagesTotal) pages").font(.caption)
                }
            case .failed:
                Label(item.download.error ?? String(localized: "Failed"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("downloads.queued")
    }
}

private struct SeriesDownloadRow: View {
    let series: DownloadedSeries
    let size: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(series.name)
            HStack {
                Text("^[\(series.chapters) chapter](inflect: true)")
                if let size {
                    Text(size, format: .byteCount(style: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { DownloadsView() }
        .environment(AppModel())
}
