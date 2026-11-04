import SwiftUI

/// Settings → Tracking → Fill details from trackers: the scan and the list it leaves to review.
/// Android's `TrackerFillScreen`.
struct TrackerFillView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    @State private var compareAll = true
    @State private var forget = false
    @State private var showReady = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmScan = false
    @State private var confirmKeepAll = false

    private var scan: TrackerFillScan { app.trackerFillScan }

    var body: some View {
        let ready = scan.items.filter { $0.problem == .ready }
        let conflicts = scan.items.filter { $0.problem != .ready }
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Fill details from trackers"), onBack: { dismiss() })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header
                    M3Tabs(tabs: [false, true], selection: $showReady, title: { isReady in
                        isReady
                            ? String(localized: "Ready (\(ready.count))")
                            : String(localized: "Conflicts (\(conflicts.count))")
                    })
                    let shown = showReady ? ready : conflicts
                    if shown.isEmpty {
                        Text(showReady ? String(localized: "Nothing is ready to apply.") : String(localized: "No conflicts left."))
                            .font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    } else if showReady {
                        FilledButton(title: String(localized: "Apply all \(ready.count)")) { act { await scan.applyReady() } }
                            .disabled(busy)
                    } else {
                        M3TextButton(title: String(localized: "Keep everything for all"), color: m3.error) { confirmKeepAll = true }
                            .disabled(busy)
                    }
                    ForEach(shown) { item in
                        Group {
                            if item.changes.isEmpty {
                                FillMatchCard(item: item, busy: busy, act: act)
                            } else {
                                FillChangesCard(item: item, busy: busy, act: act)
                            }
                        }
                        .id(item.changes.map(\.field).joined() + item.id)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(m3.surface)
        .task { await scan.load() }
        .m3Dialog(isPresented: $confirmScan, title: nil) {
            Text("A new scan replaces the list waiting for review. Scan again?").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmScan = false }
            M3TextButton(title: String(localized: "Scan")) {
                confirmScan = false
                start()
            }
        }
        .m3Dialog(isPresented: $confirmKeepAll, title: nil) {
            Text("Keep what every series has and clear all \(conflicts.count) conflicts?").padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmKeepAll = false }
            M3TextButton(title: String(localized: "Keep everything for all")) {
                confirmKeepAll = false
                act { await scan.dismissConflicts() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scans your library using the trackers signed in on this device, then lists what it found for you to review. No series changes until you apply it. Applied fields are locked like any edit, and your choices reach your other devices and Dōchō Server through Dōchō Sync.")
                .font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
            if scan.isScanning || scan.hasUnfinishedScan {
                ProgressView(value: Double(scan.progress.done), total: Double(max(scan.progress.total, 1)))
                Text("Scanning series \(scan.progress.done) of \(scan.progress.total)").font(M3Type.bodyMedium).foregroundStyle(m3.onSurface)
                Text("Keep the app open: the scan pauses while it's in the background, and goes on when you're back.")
                    .font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                M3TextButton(title: String(localized: "Stop"), color: m3.error) { scan.stop() }
            } else {
                CheckboxRow(title: String(localized: "Also compare series with no empty fields (takes longer, finds more conflicts)"), isOn: $compareAll)
                CheckboxRow(title: String(localized: "Ask again about everything I kept or skipped"), isOn: $forget)
                if scan.progress.finished {
                    Text("Last scan: \(scan.progress.done) series looked at, \(scan.progress.unchanged) with nothing to add, \(scan.progress.failed) tracker errors")
                        .font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                }
                FilledButton(title: String(localized: "Scan")) {
                    if scan.items.isEmpty { start() } else { confirmScan = true }
                }
            }
            if let message { Text(message).font(M3Type.bodySmall).foregroundStyle(m3.error) }
        }
    }

    private func start() {
        guard scan.canScan else {
            message = String(localized: "Sign in to a tracker in Settings → Tracking first")
            return
        }
        message = nil
        scan.start(compareAll: compareAll, forgetChoices: forget)
        forget = false
    }

    private func act(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do {
                try await action()
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

private func fieldName(_ field: String) -> String {
    switch field {
    case TrackerFillRules.author: String(localized: "Author")
    case TrackerFillRules.artist: String(localized: "Artist")
    case TrackerFillRules.description: String(localized: "Description")
    default: String(localized: "Status")
    }
}

private func valueText(_ field: String, _ value: String) -> String {
    guard field == TrackerFillRules.status else { return value }
    return (Int(value).flatMap(MangaStatus.init(rawValue:)) ?? .unknown).title
}

/// A series whose fields need deciding, or that's ready to apply.
private struct FillChangesCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let item: FillItem
    let busy: Bool
    let act: (@escaping @MainActor () async throws -> Void) -> Void
    @State private var choices: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(M3Type.titleMedium).foregroundStyle(m3.onSurface)
            ForEach(item.changes, id: \.field) { change in
                Text(fieldName(change.field)).font(M3Type.labelLarge).foregroundStyle(m3.onSurface)
                if change.conflict {
                    if !isEmpty(change) {
                        RadioRow(
                            title: String(localized: "Keep: \(valueText(change.field, change.current))"),
                            selected: choices[change.field] == nil
                        ) { choices[change.field] = nil }
                    }
                    ForEach(change.options, id: \.self) { option in
                        RadioRow(
                            title: "\(option.trackerName): \(valueText(change.field, option.value))",
                            selected: choices[change.field] == option.value
                        ) { choices[change.field] = option.value }
                    }
                } else if let option = change.options.first {
                    Text("\(String(valueText(change.field, option.value).prefix(240))) (\(option.trackerName))")
                        .font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                }
            }
            HStack(spacing: 8) {
                FilledButton(title: String(localized: "Apply")) { act { await app.trackerFillScan.resolve(item.id, choices: choices) } }
                    .disabled(busy)
                M3TextButton(title: String(localized: "Keep everything")) { act { await app.trackerFillScan.skip(item.id) } }
                    .disabled(busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(m3.surfaceContainer, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            for change in item.changes where !change.conflict || isEmpty(change) {
                choices[change.field] = change.options.first?.value
            }
        }
    }

    private func isEmpty(_ change: FillChange) -> Bool {
        change.field == TrackerFillRules.status ? change.current == "0" : TrackerFillRules.isEmptyName(change.current)
    }
}

/// A series with no clear match: pick one of the results, search again, or leave it.
private struct FillMatchCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let item: FillItem
    let busy: Bool
    let act: (@escaping @MainActor () async throws -> Void) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(M3Type.titleMedium).foregroundStyle(m3.onSurface)
            Text(item.problem == .severalMatches
                ? String(localized: "Several results could be this series. Which is it?")
                : String(localized: "No tracker has this exact title. Is it one of these?"))
                .font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
            ForEach(Array(item.candidates.enumerated()), id: \.offset) { index, candidate in
                Button {
                    act { await app.trackerFillScan.pick(item.id, index: index) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title).font(M3Type.bodyLarge).foregroundStyle(m3.onSurface)
                        Text([candidate.trackerName, candidate.author, candidate.publishingStatus].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            M3TextField(label: String(localized: "Search for another title"), text: $query)
            HStack(spacing: 8) {
                M3TextButton(title: String(localized: "Search")) { act { try await app.trackerFillScan.search(item.id, query: query) } }
                    .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
                M3TextButton(title: String(localized: "Skip this series")) { act { await app.trackerFillScan.skip(item.id) } }
                    .disabled(busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(m3.surfaceContainer, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if query.isEmpty { query = item.title } }
    }
}
