import SwiftUI

/// "Is this where you're up to?" (Android's `SyncConflictBanner`): shown at the top of the screen when
/// Dōchō Sync took a later change that went back (an earlier page, or unread) while further progress
/// was elsewhere. Compare shows both and lets you keep either; Ignore keeps what's there. It hides
/// itself after the time set in Appearance, keeping what's there.
struct SyncConflictBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var comparing = false

    private var sync: DochoSync { app.dochoSync }
    private var conflicts: [DochoSync.Conflict] { sync.conflicts }

    var body: some View {
        VStack {
            if let first = conflicts.first, !comparing {
                banner(first)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: conflicts.isEmpty || comparing)
        // Starts again when more arrive; not while comparing.
        .task(id: TimerKey(ids: conflicts.map(\.chapterId), seconds: app.preferences.syncBannerSeconds, comparing: comparing)) {
            let seconds = app.preferences.syncBannerSeconds
            guard !conflicts.isEmpty, seconds > 0, !comparing else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            sync.dismissConflicts(conflicts)
        }
        .m3Dialog(isPresented: $comparing, title: String(localized: "Reading progress")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(conflicts) { conflict in details(conflict) }
                }
            }
            .frame(maxHeight: 420)
        } buttons: {
            M3TextButton(title: String(localized: "Keep all")) {
                sync.dismissConflicts(conflicts)
                comparing = false
            }
        }
        .onChange(of: conflicts.isEmpty) { _, empty in if empty { comparing = false } }
    }

    private struct TimerKey: Hashable {
        var ids: [Int]
        var seconds: Int
        var comparing: Bool
    }

    private func banner(_ first: DochoSync.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Is this where you're up to?").font(M3Type.titleSmall)
            Text(summary(first)).font(M3Type.bodyMedium)
            if conflicts.count > 1 {
                Text(conflicts.count == 2 ? String(localized: "And 1 more chapter.") : String(localized: "And \(conflicts.count - 1) more chapters."))
                    .font(M3Type.bodySmall)
            }
            HStack {
                Spacer()
                M3TextButton(title: String(localized: "Ignore")) { sync.dismissConflicts(conflicts) }
                M3TextButton(title: String(localized: "Compare")) { comparing = true }
            }
        }
        .foregroundStyle(m3.onSecondaryContainer)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(m3.secondaryContainer).shadow(radius: 6, y: 2))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func details(_ conflict: DochoSync.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conflict.seriesTitle).font(M3Type.titleSmall)
            Text(conflict.chapterName).font(M3Type.bodyMedium)
            Text("Now: \(progressText(conflict.kept))").font(M3Type.bodyMedium).padding(.top, 4)
            Text(furtherText(conflict)).font(M3Type.bodyMedium)
            HStack {
                Spacer()
                M3TextButton(title: String(localized: "Keep this")) { sync.dismissConflicts([conflict]) }
                M3TextButton(title: String(localized: "Go to \(progressText(conflict.further))")) {
                    Task { await sync.useFurther(conflict) }
                }
            }
            M3Divider()
        }
        .foregroundStyle(m3.onSurface)
        .padding(.vertical, 8)
    }

    private func summary(_ conflict: DochoSync.Conflict) -> String {
        let kept = progressText(conflict.kept)
        let further = progressText(conflict.further)
        return conflict.keptHere
            ? String(localized: "\(conflict.seriesTitle), \(conflict.chapterName): you went to \(kept) here, but \(deviceText(conflict.furtherDevice)) had \(further).")
            : String(localized: "\(conflict.seriesTitle), \(conflict.chapterName): another device went to \(kept), but this device had \(further).")
    }

    private func furtherText(_ conflict: DochoSync.Conflict) -> String {
        let further = progressText(conflict.further)
        let device = deviceText(conflict.furtherDevice)
        guard let at = conflict.furtherAt else { return String(localized: "Further: \(further), on \(device)") }
        let when = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: Double(at) / 1000), relativeTo: Date())
        return String(localized: "Further: \(further), on \(device), \(when)")
    }

    /// "page 5", "unread" or "read"; pages count from 1 here, from 0 in the records.
    private func progressText(_ progress: DochoSync.Progress) -> String {
        if progress.read { return String(localized: "read") }
        if progress.page > 0 { return String(localized: "page \(progress.page + 1)") }
        return String(localized: "unread")
    }

    private func deviceText(_ device: String?) -> String {
        switch device {
        case nil, sync.settings.deviceId: String(localized: "this device")
        case "docho-server": String(localized: "Dōchō Server")
        default: String(localized: "another device")
        }
    }
}
