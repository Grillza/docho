import NukeUI
import SwiftUI

/// Settings → Tracking (Android's `SettingsTrackingScreen`): sign in to each site, and whether
/// reading updates them.
struct TrackingSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var passwordFor: TrackerBox?
    @State private var username = ""
    @State private var password = ""
    @State private var busy: Int64?
    @State private var error: String?
    @State private var webSignIn = WebSignIn()

    var body: some View {
        @Bindable var trackers = app.trackers
        SwitchPreference(title: String(localized: "Update progress after reading"), isOn: $trackers.updateAfterReading)
        PreferenceHeader(title: String(localized: "Services"))
        ForEach(app.trackers.trackers.map(TrackerBox.init)) { box in
            row(box.tracker)
        }
        InfoPreference(text: String(localized: "Tracking keeps your reading progress on these sites. Link a series from its Tracking button once you're signed in."))
            .m3Dialog(isPresented: Binding(get: { passwordFor != nil }, set: { if !$0 { passwordFor = nil } }), title: passwordFor.map { String(localized: "Sign in to \($0.tracker.name)") }) {
                VStack(spacing: 12) {
                    M3TextField(label: String(localized: "Username"), text: $username)
                    M3TextField(label: String(localized: "Password"), text: $password, secure: true)
                }
                .padding(.horizontal, 24)
            } buttons: {
                M3TextButton(title: String(localized: "Cancel")) { passwordFor = nil }
                M3TextButton(title: String(localized: "Sign in")) {
                    guard let tracker = passwordFor?.tracker else { return }
                    passwordFor = nil
                    run(tracker) { try await app.trackers.signIn(tracker, username: username, password: password) }
                }
            }
            .m3Dialog(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), title: String(localized: "Couldn't sign in")) {
                Text(error ?? "").font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } buttons: {
                M3TextButton(title: String(localized: "OK")) { error = nil }
            }
    }

    private func row(_ tracker: any Tracker) -> some View {
        let signedIn = app.trackers.signedIn.contains { $0.id == tracker.id }
        return Button {
            if signedIn {
                app.trackers.signOut(tracker)
            } else {
                switch tracker.signIn {
                case .oauth(let url):
                    run(tracker) {
                        let callback = try await webSignIn.start(url)
                        try await app.trackers.signIn(tracker, callback: callback)
                    }
                case .password:
                    username = ""
                    password = ""
                    passwordFor = TrackerBox(tracker)
                }
            }
        } label: {
            HStack(spacing: 16) {
                TrackerLogo(tracker: tracker).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.name).font(M3Type.bodyLarge).foregroundStyle(m3.onSurface)
                    if signedIn, !tracker.username.isEmpty {
                        Text(tracker.username).font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    }
                }
                Spacer()
                if busy == tracker.id {
                    ProgressView().tint(m3.primary)
                } else {
                    Text(signedIn ? String(localized: "Sign out") : String(localized: "Sign in"))
                        .font(M3Type.labelLarge)
                        .foregroundStyle(signedIn ? m3.error : m3.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
        .accessibilityIdentifier("tracking.\(tracker.name)")
    }

    private func run(_ tracker: any Tracker, _ work: @escaping () async throws -> Void) {
        busy = tracker.id
        Task {
            do {
                try await work()
            } catch TrackerError.cancelled {
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
        }
    }
}

/// A tracker in an `Identifiable` box, for lists and sheets.
struct TrackerBox: Identifiable {
    let tracker: any Tracker
    var id: Int64 { tracker.id }

    init(_ tracker: any Tracker) {
        self.tracker = tracker
    }
}

/// The site's initial on its brand colour.
struct TrackerLogo: View {
    let tracker: any Tracker

    var body: some View {
        Text(tracker.name.prefix(1))
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: tracker.brandColor)))
            .accessibilityHidden(true)
    }
}

// MARK: - A series' tracking

/// Android's `TrackInfoDialogHome`: each signed-in site, linked or not, with its status,
/// chapters, score and dates.
struct TrackingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openURL) private var openURL
    let seriesId: Int
    let seriesTitle: String

    @State private var tracks: [TrackRecord] = []
    @State private var searching: TrackerBox?
    @State private var editing: Edit?
    @State private var removing: TrackRecord?
    @State private var error: String?
    @State private var date = Date.now

    enum Field { case status, chapters, score, start, finish }

    struct Edit: Identifiable {
        let track: TrackRecord
        let field: Field
        var id: String { "\(track.trackerId)-\(field)" }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                let trackers = app.trackers.signedIn
                if trackers.isEmpty {
                    Text("Sign in to a tracking site in Settings → Tracking to link this series.")
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .padding(24)
                }
                ForEach(trackers.map(TrackerBox.init)) { box in
                    if let track = tracks.first(where: { $0.trackerId == box.id }) {
                        card(box.tracker, track)
                    } else {
                        Button { searching = box } label: {
                            HStack(spacing: 16) {
                                TrackerLogo(tracker: box.tracker).frame(width: 48, height: 48)
                                Text("Add tracking").font(M3Type.labelLarge).foregroundStyle(m3.primary)
                                Spacer()
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(m3.surfaceContainerHigh))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.ripple)
                    }
                }
            }
            .padding(16)
        }
        .background(m3.surfaceContainerLow)
        .task {
            do {
                for try await value in app.database.observeTracks(seriesId: seriesId) { tracks = value }
            } catch {}
        }
        .sheet(item: $searching) { box in
            TrackSearchView(tracker: box.tracker, seriesId: seriesId, initialQuery: seriesTitle)
        }
        .m3Dialog(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), title: editing.map(editTitle)) {
            if let editing { editor(editing) }
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { editing = nil }
            if let editing, editing.field == .start || editing.field == .finish {
                M3TextButton(title: String(localized: "Remove")) {
                    save(editing.track) { editing.field == .start ? ($0.startDate = nil) : ($0.finishDate = nil) }
                }
                M3TextButton(title: String(localized: "OK")) {
                    let picked = date
                    save(editing.track) { editing.field == .start ? ($0.startDate = picked) : ($0.finishDate = picked) }
                }
            }
        }
        .m3Dialog(isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), title: String(localized: "Remove tracking?")) {
            Text("Stop tracking this series here, or take it off your list on the site too.")
                .font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { removing = nil }
            if let track = removing {
                M3TextButton(title: String(localized: "Also on the site")) { unlink(track, fromSite: true) }
                M3TextButton(title: String(localized: "Remove")) { unlink(track, fromSite: false) }
            }
        }
        .m3Dialog(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), title: String(localized: "Tracking failed")) {
            Text(error ?? "").font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        } buttons: {
            M3TextButton(title: String(localized: "OK")) { error = nil }
        }
    }

    private func card(_ tracker: any Tracker, _ track: TrackRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TrackerLogo(tracker: tracker).frame(width: 48, height: 48)
                Button {
                    if let url = URL(string: track.remoteUrl) { openURL(url) }
                } label: {
                    Text(track.title).font(M3Type.titleMedium).foregroundStyle(m3.onSurface).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                OverflowMenu {
                    Button(String(localized: "Refresh")) { Task { await attempt { try await app.trackers.refresh(track) } } }
                    Button(String(localized: "Change match")) { searching = TrackerBox(tracker) }
                    Button(String(localized: "Remove"), role: .destructive) { removing = track }
                }
            }
            .padding(12)
            M3Divider()
            HStack(spacing: 0) {
                cell(tracker.statusTitle(track.status)) { editing = Edit(track: track, field: .status) }
                M3VerticalDivider()
                cell(track.totalChapters > 0 ? "\(Int(track.lastChapterRead))/\(track.totalChapters)" : "\(Int(track.lastChapterRead))") {
                    editing = Edit(track: track, field: .chapters)
                }
                M3VerticalDivider()
                cell(track.score == 0 ? "-" : tracker.displayScore(track.score), placeholder: track.score == 0) {
                    editing = Edit(track: track, field: .score)
                }
            }
            .frame(height: 48)
            if tracker.supportsReadingDates {
                M3Divider()
                HStack(spacing: 0) {
                    cell(track.startDate.map(Self.format) ?? String(localized: "Start date"), placeholder: track.startDate == nil) {
                        date = track.startDate ?? .now
                        editing = Edit(track: track, field: .start)
                    }
                    M3VerticalDivider()
                    cell(track.finishDate.map(Self.format) ?? String(localized: "Finish date"), placeholder: track.finishDate == nil) {
                        date = track.finishDate ?? .now
                        editing = Edit(track: track, field: .finish)
                    }
                }
                .frame(height: 48)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(m3.surfaceContainerHigh))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func cell(_ text: String, placeholder: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(M3Type.bodyMedium)
                .foregroundStyle(placeholder ? m3.onSurfaceVariant : m3.onSurface)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ripple)
    }

    private func editTitle(_ edit: Edit) -> String {
        switch edit.field {
        case .status: String(localized: "Status")
        case .chapters: String(localized: "Chapters")
        case .score: String(localized: "Score")
        case .start: String(localized: "Start date")
        case .finish: String(localized: "Finish date")
        }
    }

    @ViewBuilder
    private func editor(_ edit: Edit) -> some View {
        let tracker = app.trackers.tracker(edit.track.trackerId)
        switch edit.field {
        case .status:
            VStack(spacing: 0) {
                ForEach(tracker?.statuses ?? [], id: \.id) { status in
                    RadioRow(title: status.title, selected: status.id == edit.track.status) {
                        save(edit.track) { $0.status = status.id }
                    }
                }
            }
        case .chapters:
            let upper = max(edit.track.totalChapters, Int(edit.track.lastChapterRead) + 100)
            Picker("", selection: Binding(get: { Int(edit.track.lastChapterRead) }, set: { value in
                save(edit.track, close: false) { $0.lastChapterRead = Double(value) }
            })) {
                ForEach(0...upper, id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 180)
        case .score:
            let scores = tracker?.scores ?? []
            Picker("", selection: Binding(get: { tracker?.scoreIndex(edit.track.score) ?? 0 }, set: { index in
                save(edit.track, close: false) { $0.score = tracker?.indexToScore(index) ?? 0 }
            })) {
                ForEach(scores.indices, id: \.self) { Text(scores[$0]).tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 180)
        case .start, .finish:
            DatePicker("", selection: $date, in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(m3.primary)
                .padding(.horizontal, 16)
        }
    }

    /// Applies a change, sends it to the site and keeps it.
    private func save(_ track: TrackRecord, close: Bool = true, _ change: (inout TrackRecord) -> Void) {
        var updated = track
        change(&updated)
        if close {
            editing = nil
        } else if let field = editing?.field {
            editing = Edit(track: updated, field: field)
        }
        tracks = tracks.map { $0.trackerId == updated.trackerId ? updated : $0 }
        Task { await attempt { try await app.trackers.update(updated) } }
    }

    private func unlink(_ track: TrackRecord, fromSite: Bool) {
        removing = nil
        Task { await attempt { try await app.trackers.unlink(track, fromSite: fromSite) } }
    }

    private func attempt(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Android's `TrackerSearch`: find the series on the site and pick it.
struct TrackSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let tracker: any Tracker
    let seriesId: Int
    let initialQuery: String

    @State private var query = ""
    @State private var results: [TrackSearch] = []
    @State private var selected: TrackSearch?
    @State private var loading = false
    @State private var linking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AppBarIcon("close", label: String(localized: "Close")) { dismiss() }
                    .foregroundStyle(m3.onSurface)
                    .padding(.leading, 4)
                AppBarSearchField(placeholder: String(localized: "Search \(tracker.name)…"), text: $query) { search() }
                    .padding(.leading, 4)
            }
            .frame(height: 64)
            .padding(.trailing, 8)
            M3Divider()
            if loading {
                LoadingScreen()
            } else if results.isEmpty {
                EmptyScreen(message: error ?? String(localized: "No results found")) {}
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                    .padding(16)
                }
            }
            if selected != nil {
                M3Divider()
                Button {
                    link()
                } label: {
                    Group {
                        if linking { ProgressView().tint(m3.onPrimary) } else { Text("Track") }
                    }
                    .font(M3Type.labelLarge)
                    .foregroundStyle(m3.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Capsule().fill(m3.primary))
                }
                .buttonStyle(.plain)
                .disabled(linking)
                .padding(16)
            }
        }
        .background(m3.surface)
        .onAppear {
            guard query.isEmpty else { return }
            query = initialQuery
            search()
        }
    }

    private func resultRow(_ result: TrackSearch) -> some View {
        let isSelected = selected?.remoteId == result.remoteId
        return Button { selected = result } label: {
            HStack(alignment: .top, spacing: 12) {
                LazyImage(url: result.coverURL) { state in
                    if let image = state.image { image.resizable().scaledToFill() } else { m3.surfaceContainerHighest }
                }
                .frame(width: 68, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(M3Type.titleMedium).foregroundStyle(m3.onSurface).lineLimit(2)
                    let details = [result.publishingType, result.startDate, result.publishingStatus].filter { !$0.isEmpty }
                    if !details.isEmpty {
                        Text(details.joined(separator: " • ")).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                    if !result.summary.isEmpty {
                        Text(result.summary).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? m3.secondaryContainer : m3.surfaceContainerHigh)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? m3.primary : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        loading = true
        error = nil
        selected = nil
        Task {
            do {
                results = try await tracker.search(text)
            } catch {
                results = []
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func link() {
        guard let selected else { return }
        linking = true
        Task {
            do {
                // Changing the match replaces the old link.
                if let old = try? await app.database.tracks(seriesId: seriesId).first(where: { $0.trackerId == tracker.id }),
                   old.remoteId != selected.remoteId {
                    try await app.database.deleteTrack(old)
                }
                try await app.trackers.link(seriesId: seriesId, to: selected, tracker: tracker)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                results = []
            }
            linking = false
        }
    }
}
