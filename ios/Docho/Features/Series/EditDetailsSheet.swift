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
    @State private var filling = false
    @State private var fillMessage: String?
    @State private var picking: [TrackerFill.Match] = []

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
                    M3TextButton(title: String(localized: "Fill from tracker"), color: m3.primary) {
                        Task { await fill() }
                    }
                    .disabled(filling)
                    if let fillMessage {
                        Text(fillMessage).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
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
        .sheet(isPresented: Binding(get: { !picking.isEmpty }, set: { if !$0 { picking = [] } })) {
            NavigationStack {
                List(Array(picking.enumerated()), id: \.offset) { _, match in
                    Button {
                        picking = []
                        fillFrom([match])
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title).font(M3Type.bodyLarge).foregroundStyle(m3.onSurface)
                            Text([match.trackerName, match.author, match.publishingStatus].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(M3Type.bodySmall)
                                .foregroundStyle(m3.onSurfaceVariant)
                        }
                    }
                }
                .navigationTitle(String(localized: "Which series is this?"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { picking = [] }
                    }
                }
            }
        }
    }

    /// The linked trackers' details, or else search results to pick from. Only fills the form:
    /// nothing is saved until Save, so it can all be checked first.
    private func fill() async {
        let fill = TrackerFill(trackers: app.trackers.signedIn)
        guard fill.canFill else {
            fillMessage = String(localized: "Sign in to a tracker in Settings → Tracking first")
            return
        }
        filling = true
        defer { filling = false }
        fillMessage = nil
        let tracks = (try? await app.database.tracks(seriesId: series.id)) ?? []
        let linked = await fill.linked(tracks)
        if !linked.isEmpty {
            fillFrom(linked)
            return
        }
        do {
            let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let found = try await fill.search(query.isEmpty ? series.name : query)
            if found.isEmpty {
                fillMessage = String(localized: "No tracker found this series. Try changing the title above, then search again.")
            }
            picking = found
        } catch {
            fillMessage = error.localizedDescription
        }
    }

    private func fillFrom(_ matches: [TrackerFill.Match]) {
        let before = TrackerFill.Form(author: author, artist: artist, description: summary, status: status)
        let filled = matches.reduce(before) { TrackerFill.fill($0, from: $1, statusEdited: saved.status != nil) }
        author = filled.author
        artist = filled.artist
        summary = filled.description
        status = filled.status
        fillMessage = if filled == before {
            String(localized: "Nothing to fill: the tracker has nothing for the empty fields")
        } else {
            String(localized: "Filled from \(matches[0].trackerName). Check the details, then save.")
        }
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
