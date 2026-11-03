import SwiftUI

/// Edits a series' title, author, artist, description, genres and status, as Kavita and Dōchō
/// Server do: an edited field is locked, so refreshing from the source keeps it (`SeriesEdits`).
/// Android's `EditDetailsScreen`.
struct EditDetailsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let series: SeriesRecord

    @State private var saved = SeriesEdits.Details()
    @State private var title = ""
    @State private var author = ""
    @State private var artist = ""
    @State private var summary = ""
    @State private var genres = ""
    @State private var status = 0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopAppBar(title: String(localized: "Edit details"), subtitle: series.name, showsBack: true) {
                AppBarIcon("check", label: String(localized: "Save")) { Task { await save() } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Edited fields stay over what the source sends when the series refreshes. They reach your other devices and Dōchō Server through Dōchō Sync, and edits made there show here.")
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                    M3TextField(label: String(localized: "Title"), text: $title, supporting: edited(saved.title))
                    M3TextField(label: String(localized: "Author"), text: $author, supporting: edited(saved.author))
                    M3TextField(label: String(localized: "Artist"), text: $artist, supporting: edited(saved.artist))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description").font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                        TextField(String(localized: "Description"), text: $summary, axis: .vertical)
                            .lineLimit(4...14)
                            .font(M3Type.bodyLarge)
                            .padding(12)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(m3.outline, lineWidth: 1))
                        if let note = edited(saved.description) {
                            Text(note).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                    }
                    M3TextField(
                        label: String(localized: "Genres"), text: $genres,
                        supporting: [edited(saved.genres), String(localized: "Separated by commas")].compactMap { $0 }.joined(separator: " · ")
                    )
                    Picker(selection: $status) {
                        ForEach(MangaStatus.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Text("Status")
                    }
                    .pickerStyle(.menu)
                    if let note = edited(saved.status) {
                        Text(note).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                    if !saved.isEmpty {
                        M3TextButton(title: String(localized: "Use the source's details"), color: m3.error) {
                            Task { await reset() }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(m3.surface)
        .onAppear(perform: load)
    }

    private func edited<T>(_ value: T?) -> String? { value == nil ? nil : String(localized: "Edited") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        saved = app.seriesEdits.get(source: series.source, url: series.url) ?? .init()
        title = series.name
        author = series.authors ?? ""
        artist = series.artists ?? ""
        summary = series.summary ?? ""
        genres = series.genreList.joined(separator: ", ")
        status = series.status
    }

    /// A field is edited if it was before, or is now different from what the series has.
    private func details() -> SeriesEdits.Details {
        func pick<T: Equatable>(_ was: T?, _ now: T, _ current: T) -> T? { was != nil || now != current ? now : nil }
        let genreList = genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SeriesEdits.Details(
            title: trimmedTitle.isEmpty ? nil : pick(saved.title, trimmedTitle, series.name),
            author: pick(saved.author, author.trimmingCharacters(in: .whitespaces), series.authors ?? ""),
            artist: pick(saved.artist, artist.trimmingCharacters(in: .whitespaces), series.artists ?? ""),
            description: pick(saved.description, summary.trimmingCharacters(in: .whitespacesAndNewlines), series.summary ?? ""),
            genres: pick(saved.genres, genreList, series.genreList),
            status: pick(saved.status, status, series.status)
        )
    }

    private func save() async {
        let details = details()
        app.seriesEdits.put(source: series.source, url: series.url, details)
        try? await app.database.writer.write { [series] db in
            guard var stored = try SeriesRecord.fetchOne(db, key: series.id) else { return }
            SeriesEdits.write(details, to: &stored)
            try stored.update(db)
        }
        app.dochoSync.syncSoon(after: 3)
        dismiss()
    }

    private func reset() async {
        app.seriesEdits.put(source: series.source, url: series.url, nil)
        // The source's details back, now.
        if let stored = try? await app.database.seriesRecord(id: series.id) {
            _ = try? await app.library.refresh(stored, details: true)
        }
        app.dochoSync.syncSoon(after: 3)
        dismiss()
    }
}
