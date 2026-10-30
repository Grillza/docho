import SwiftUI

/// Android's Settings → Sync / Self-hosted sources: where reading progress goes, then a section
/// per server that folds down to its logo, name and connection status.
struct SyncSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var mode: ProgressSyncMode = .source
    @State private var counts: [String: Int] = [:]
    @State private var komgaNotice = false
    @State private var hideNotice = false

    var body: some View {
        VStack(spacing: 0) {
            PreferenceHeader(title: String(localized: "Reading progress"))
            ListPreference(
                title: String(localized: "Sync progress with"), selection: $mode,
                options: [(.source, String(localized: "Default - Sync with source")), (.koreader, String(localized: "KOReader"))]
            )
            if mode == .koreader {
                InfoPreference(text: String(localized: "KOReader: every series syncs with the KOReader sync server below instead of its source. Works for Kavita, BookOrbit and Komga (if you allow downloading its books); other sources have no files to match, so they don't sync."))
            }
            KavitaSection(waiting: counts[KavitaSync.engine] ?? 0)
            BookOrbitSection(waiting: counts[BookOrbitSync.engine] ?? 0)
            KomgaSection(waiting: counts[KomgaSync.engine] ?? 0)
            KoreaderSection(waiting: counts[KoreaderSync.engine] ?? 0)
        }
        .onAppear { mode = app.syncSettings.mode }
        .onChange(of: mode) { old, new in
            guard old != new else { return }
            app.syncSettings.mode = new
            if new == .koreader, app.komgaSettings.isConfigured, !app.komgaSettings.koreaderNoticeHidden, !app.komgaSettings.koreaderDownloads {
                komgaNotice = true
            }
            Task { await app.sync.syncLibrary() }
        }
        .task {
            do {
                for try await counts in app.database.syncQueueCounts() { self.counts = counts }
            } catch {}
        }
        .m3Dialog(isPresented: $komgaNotice, title: String(localized: "Komga and KOReader sync")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("KOReader recognises a book by a fingerprint taken across its whole file. Komga can only send complete files, so to sync a Komga book with KOReader, Dōchō has to download the book once to work out its fingerprint. The download isn't kept, but large books can use a lot of data.\n\nYou can change this later under KOReader sync.")
                    .padding(.horizontal, 24)
                CheckboxRow(title: String(localized: "Don't show this again"), isOn: $hideNotice)
            }
        } buttons: {
            VStack(alignment: .trailing, spacing: 0) {
                M3TextButton(title: String(localized: "I understand, sync Komga")) {
                    app.komgaSettings.koreaderDownloads = true
                    app.komgaSettings.koreaderNoticeHidden = hideNotice
                    komgaNotice = false
                }
                M3TextButton(title: String(localized: "Don't sync Komga")) {
                    app.komgaSettings.koreaderDownloads = false
                    app.komgaSettings.koreaderNoticeHidden = hideNotice
                    komgaNotice = false
                }
            }
        }
    }
}

/// A server's folding section: logo, name and status; opened, its settings.
struct ServerSection<Content: View>: View {
    @Environment(\.m3) private var m3
    let name: String
    let icon: String
    let status: ServerConnection
    let configured: Bool
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 16) {
                    Group {
                        if UIImage(named: icon) != nil {
                            Image(icon).resizable().scaledToFit()
                        } else {
                            MIcon("dns").foregroundStyle(m3.primary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 16)).foregroundStyle(m3.onSurface)
                        Text(statusText).font(M3Type.bodySmall).foregroundStyle(statusColor).lineLimit(2)
                    }
                    Spacer()
                    MIcon(expanded ? "keyboard_arrow_up" : "keyboard_arrow_down").foregroundStyle(m3.onSurfaceVariant)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.ripple)
            .accessibilityIdentifier("sync.section.\(name)")
            if expanded {
                VStack(spacing: 0) { content }
                    .padding(.bottom, 8)
            }
            M3Divider()
        }
    }

    private var statusText: String {
        guard configured else { return String(localized: "Not set up") }
        return switch status {
        case .unknown: String(localized: "Tap to check the connection")
        case .checking: String(localized: "Connecting…")
        case .connected(let name): name
        case .failed(let reason): String(localized: "Couldn't connect: \(reason)")
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected: Color(hex: 0x4CAF50)
        case .failed: m3.error
        default: m3.onSurfaceVariant
        }
    }
}

/// The parts every server section shares: sync toggle, sync now, waiting count, Browse, Delete.
private struct ServerCommonRows: View {
    @Environment(\.m3) private var m3
    let name: String
    let sourceId: Int64?
    @Binding var syncProgress: Bool
    let syncSummary: String
    let syncNowSummary: String
    let waiting: Int
    let syncNow: () async -> Int
    let sendNow: () async -> Void
    let delete: () -> Void
    @State private var syncResult: String?
    @State private var syncing = false
    @State private var confirmingDelete = false

    var body: some View {
        SwitchPreference(title: String(localized: "Sync reading progress"), subtitle: syncSummary, isOn: $syncProgress)
        PreferenceRow(
            title: String(localized: "Sync library now"),
            subtitle: syncing ? String(localized: "Syncing with \(name)…") : (syncResult ?? syncNowSummary),
            action: {
                guard !syncing else { return }
                syncing = true
                Task {
                    let count = await syncNow()
                    syncResult = String(localized: "Synced \(count) \(name) series")
                    syncing = false
                }
            }
        )
        if waiting > 0 {
            PreferenceRow(
                title: String(localized: "Waiting to be sent: \(waiting)"),
                subtitle: String(localized: "Progress made while the server couldn't be reached"),
                action: { Task { await sendNow() } }
            ) {
                Text("Send Now").font(M3Type.labelLarge).foregroundStyle(m3.primary)
            }
        }
        if let sourceId {
            NavigationLink(value: Route.source(sourceId, listing: .popular)) {
                PreferenceRow(
                    title: String(localized: "Browse \(name)"),
                    subtitle: String(localized: "Your \(name) series also appear under Browse → Sources. Add them to the library like any other manga.")
                )
            }
            .buttonStyle(.ripple)
        }
        PreferenceRow(
            title: String(localized: "Delete"), subtitle: String(localized: "Erase the \(name) settings on this device"),
            icon: "delete", iconTint: m3.error, action: { confirmingDelete = true }
        )
        .m3Dialog(isPresented: $confirmingDelete, title: String(localized: "Delete \(name) settings?")) {
            Text("This erases the \(name) server address, sign-in details, sync options and any progress not yet sent. Nothing is deleted on the server, and your other settings stay as they are.")
                .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingDelete = false }
            M3TextButton(title: String(localized: "Delete"), color: m3.error) {
                confirmingDelete = false
                delete()
            }
        }
    }
}

/// Checks the connection 300 ms after the last edit, as Android does.
private struct DebouncedCheck: ViewModifier {
    let key: String
    let check: () async -> Void

    func body(content: Content) -> some View {
        content.task(id: key) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await check()
        }
    }
}

// MARK: - Kavita

private struct KavitaSection: View {
    @Environment(AppModel.self) private var app
    let waiting: Int
    @State private var server = ""
    @State private var apiKey = ""
    @State private var syncProgress = true
    @State private var loaded = false

    var body: some View {
        ServerSection(name: "Kavita", icon: "brand.kavita", status: status, configured: app.settings.credentials.isConfigured) {
            VStack(spacing: 16) {
                M3TextField(label: String(localized: "Server address"), text: $server, keyboard: .URL, supporting: String(localized: "e.g. https://kavita.example.com"))
                    .accessibilityIdentifier("settings.kavita.server")
                M3TextField(
                    label: String(localized: "API key"), text: $apiKey, secure: true,
                    supporting: String(localized: "Copy it from Kavita: your user settings, under API Key / OPDS")
                )
                .accessibilityIdentifier("settings.kavita.apikey")
            }
            .padding(16)
            PreferenceRow(title: String(localized: "Connection"), subtitle: connectionText, action: { Task { await app.kavita.checkConnection() } })
                .accessibilityIdentifier("settings.kavita.connection")
            ServerCommonRows(
                name: "Kavita", sourceId: app.settings.credentials.isConfigured ? KavitaSource.id : nil, syncProgress: $syncProgress,
                syncSummary: String(localized: "Sends every page you read to Kavita and picks up the page reached on other devices. The side that has read further wins."),
                syncNowSummary: String(localized: "Reconciles progress for every Kavita series in your library"),
                waiting: waiting,
                syncNow: { await app.kavitaSync.syncLibrary() },
                sendNow: { await app.kavitaSync.syncQueued() },
                delete: {
                    app.settings.serverURL = ""
                    app.settings.apiKey = ""
                    app.settings.syncProgress = true
                    server = ""
                    apiKey = ""
                    Task { try? await app.database.writer.write { db in try db.execute(sql: "DELETE FROM pendingProgress") } }
                }
            )
        }
        .onAppear {
            guard !loaded else { return }
            server = app.settings.serverURL
            apiKey = app.settings.apiKey
            syncProgress = app.settings.syncProgress
            loaded = true
        }
        .onChange(of: server) { _, value in app.settings.serverURL = value }
        .onChange(of: apiKey) { _, value in app.settings.apiKey = value }
        .onChange(of: syncProgress) { _, value in
            app.settings.syncProgress = value
            if value { Task { await app.kavitaSync.syncQueued() } }
        }
        .modifier(DebouncedCheck(key: server + apiKey) { await app.kavita.checkConnection() })
    }

    private var status: ServerConnection {
        switch app.connection {
        case .unknown: .unknown
        case .checking: .checking
        case .connected(let username, let version): .connected(String(localized: "Connected to Kavita \(version ?? "") as \(username)"))
        case .failed(let reason): .failed(reason)
        }
    }

    private var connectionText: String {
        guard app.settings.credentials.isConfigured else { return String(localized: "Enter the server address and API key first") }
        return switch status {
        case .unknown: String(localized: "Tap to check the connection")
        case .checking: String(localized: "Connecting…")
        case .connected(let text): text
        case .failed(let reason): String(localized: "Couldn't connect: \(reason)")
        }
    }
}

// MARK: - BookOrbit

private struct BookOrbitSection: View {
    @Environment(AppModel.self) private var app
    let waiting: Int
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var syncProgress = true
    @State private var loaded = false
    @State private var status: ServerConnection = .unknown

    var body: some View {
        ServerSection(name: "BookOrbit", icon: "brand.bookorbit", status: status, configured: app.bookOrbitSettings.isConfigured) {
            VStack(spacing: 16) {
                M3TextField(
                    label: String(localized: "Server address"), text: $server, keyboard: .URL,
                    supporting: String(localized: "The address you open BookOrbit at, e.g. http://bookorbit.lan:3010")
                )
                M3TextField(label: String(localized: "Username"), text: $username)
                M3TextField(label: String(localized: "Password"), text: $password, secure: true, supporting: String(localized: "The account you sign in to BookOrbit with"))
            }
            .padding(16)
            PreferenceRow(title: String(localized: "Connection"), subtitle: connectionText(status, configured: app.bookOrbitSettings.isConfigured), action: {
                Task { await app.bookOrbit.checkConnection() }
            })
            ServerCommonRows(
                name: "BookOrbit", sourceId: app.bookOrbitSettings.isConfigured ? BookOrbitSource.id : nil, syncProgress: $syncProgress,
                syncSummary: String(localized: "Sends every page you read to BookOrbit and picks up the page reached in its reader, KOReader or Kobo. The side that has read further wins."),
                syncNowSummary: String(localized: "Reconciles progress for every BookOrbit series in your library"),
                waiting: waiting,
                syncNow: { await app.bookOrbitSync.syncLibrary() },
                sendNow: { await app.bookOrbitSync.syncQueued() },
                delete: {
                    app.bookOrbitSettings.reset()
                    server = ""
                    username = ""
                    password = ""
                    Task {
                        await app.bookOrbit.signOut()
                        try? await app.database.clearSyncQueue(engine: BookOrbitSync.engine)
                    }
                }
            )
        }
        .onAppear {
            guard !loaded else { return }
            server = app.bookOrbitSettings.serverURL
            username = app.bookOrbitSettings.username
            password = app.bookOrbitSettings.password
            syncProgress = app.bookOrbitSettings.syncProgress
            loaded = true
        }
        .onChange(of: server) { _, value in
            app.bookOrbitSettings.serverURL = value
            Task { await app.bookOrbit.signOut() }
        }
        .onChange(of: username) { _, value in
            app.bookOrbitSettings.username = value
            Task { await app.bookOrbit.signOut() }
        }
        .onChange(of: password) { _, value in app.bookOrbitSettings.password = value }
        .onChange(of: syncProgress) { _, value in app.bookOrbitSettings.syncProgress = value }
        .modifier(DebouncedCheck(key: server + username + password) { await app.bookOrbit.checkConnection() })
        .task {
            for await connection in app.bookOrbit.status.changes { status = connection }
        }
    }
}

// MARK: - Komga

private struct KomgaSection: View {
    @Environment(AppModel.self) private var app
    let waiting: Int
    @State private var server = ""
    @State private var apiKey = ""
    @State private var syncProgress = true
    @State private var loaded = false
    @State private var status: ServerConnection = .unknown

    var body: some View {
        ServerSection(name: "Komga", icon: "brand.komga", status: displayed, configured: app.komgaSettings.isConfigured) {
            VStack(spacing: 16) {
                M3TextField(
                    label: String(localized: "Server address"), text: $server, keyboard: .URL,
                    supporting: String(localized: "The address you open Komga at, e.g. http://komga.lan:25600")
                )
                M3TextField(
                    label: String(localized: "API key"), text: $apiKey, secure: true,
                    supporting: String(localized: "Create one in Komga: your account settings, under API Keys")
                )
            }
            .padding(16)
            PreferenceRow(title: String(localized: "Connection"), subtitle: connectionText(displayed, configured: app.komgaSettings.isConfigured), action: {
                Task { await app.komga.checkConnection() }
            })
            ServerCommonRows(
                name: "Komga", sourceId: app.komgaSettings.isConfigured ? KomgaSource.id : nil, syncProgress: $syncProgress,
                syncSummary: String(localized: "Sends every page you read to Komga and picks up the page reached in its reader or on other devices. The side that has read further wins."),
                syncNowSummary: String(localized: "Reconciles progress for every Komga series in your library"),
                waiting: waiting,
                syncNow: { await app.komgaSync.syncLibrary() },
                sendNow: { await app.komgaSync.syncQueued() },
                delete: {
                    app.komgaSettings.reset()
                    server = ""
                    apiKey = ""
                    Task { try? await app.database.clearSyncQueue(engine: KomgaSync.engine) }
                }
            )
        }
        .onAppear {
            guard !loaded else { return }
            server = app.komgaSettings.serverURL
            apiKey = app.komgaSettings.apiKey
            syncProgress = app.komgaSettings.syncProgress
            loaded = true
        }
        .onChange(of: server) { _, value in app.komgaSettings.serverURL = value }
        .onChange(of: apiKey) { _, value in app.komgaSettings.apiKey = value }
        .onChange(of: syncProgress) { _, value in app.komgaSettings.syncProgress = value }
        .modifier(DebouncedCheck(key: server + apiKey) { await app.komga.checkConnection() })
        .task {
            for await connection in app.komga.status.changes { status = connection }
        }
    }

    private var displayed: ServerConnection {
        if case .connected(let email) = status { return .connected(String(localized: "Connected to Komga as \(email)")) }
        return status
    }
}

// MARK: - KOReader

private struct KoreaderSection: View {
    @Environment(AppModel.self) private var app
    let waiting: Int
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var matchKomga = false
    @State private var loaded = false
    @State private var status: ServerConnection = .unknown
    @State private var syncResult: String?

    var body: some View {
        ServerSection(name: String(localized: "KOReader sync"), icon: "brand.koreader", status: displayed, configured: app.koreaderSettings.isConfigured) {
            VStack(spacing: 16) {
                M3TextField(
                    label: String(localized: "Server address"), text: $server, keyboard: .URL,
                    supporting: String(localized: "The address KOReader uses, e.g. http://bookorbit.lan:3010/api/v1/koreader")
                )
                M3TextField(label: String(localized: "Username"), text: $username)
                M3TextField(
                    label: String(localized: "Password"), text: $password, secure: true,
                    supporting: String(localized: "Your KOReader sync account. In BookOrbit, create it under Settings → KOReader.")
                )
            }
            .padding(16)
            PreferenceRow(title: String(localized: "Connection"), subtitle: connectionText(displayed, configured: app.koreaderSettings.isConfigured), action: {
                Task { await app.koreader.checkConnection() }
            })
            SwitchPreference(
                title: String(localized: "Match Komga books"),
                subtitle: String(localized: "Downloads each Komga book once to work out the fingerprint KOReader matches it by. Large books can use a lot of data."),
                isOn: $matchKomga
            )
            PreferenceRow(
                title: String(localized: "Sync library now"),
                subtitle: syncResult ?? String(localized: "Reconciles progress for every library series that syncs here. Only runs while sync is set to KOReader."),
                action: {
                    Task {
                        let count = await app.koreaderSync.syncLibrary()
                        syncResult = String(localized: "Synced \(count) series")
                    }
                }
            )
            if waiting > 0 {
                PreferenceRow(title: String(localized: "Waiting to be sent: \(waiting)"), action: { Task { await app.koreaderSync.syncQueued() } })
            }
            InfoPreference(text: String(localized: "Chapters are matched by file, the way KOReader matches books, so the sync server needs the same files. Kavita and BookOrbit chapters that are a single archive (or PDF on Kavita) can be matched, and Komga books once you allow downloading them."))
            PreferenceRow(
                title: String(localized: "Delete"), subtitle: String(localized: "Erase the KOReader sync settings on this device"), icon: "delete",
                action: {
                    app.koreaderSettings.reset()
                    server = ""
                    username = ""
                    password = ""
                    Task { try? await app.database.clearSyncQueue(engine: KoreaderSync.engine) }
                }
            )
        }
        .onAppear {
            guard !loaded else { return }
            server = app.koreaderSettings.serverURL
            username = app.koreaderSettings.username
            password = app.koreaderSettings.password
            matchKomga = app.komgaSettings.koreaderDownloads
            loaded = true
        }
        .onChange(of: server) { _, value in app.koreaderSettings.serverURL = value }
        .onChange(of: username) { _, value in app.koreaderSettings.username = value }
        .onChange(of: password) { _, value in app.koreaderSettings.password = value }
        .onChange(of: matchKomga) { _, value in app.komgaSettings.koreaderDownloads = value }
        .modifier(DebouncedCheck(key: server + username + password) { await app.koreader.checkConnection() })
        .task {
            for await connection in app.koreader.status.changes { status = connection }
        }
    }

    private var displayed: ServerConnection {
        if case .connected(let name) = status { return .connected(String(localized: "Signed in as \(name)")) }
        return status
    }
}

private func connectionText(_ status: ServerConnection, configured: Bool) -> String {
    guard configured else { return String(localized: "Enter the server address and sign-in details first") }
    return switch status {
    case .unknown: String(localized: "Tap to check the connection")
    case .checking: String(localized: "Connecting…")
    case .connected(let text): text
    case .failed(let reason): String(localized: "Couldn't connect: \(reason)")
    }
}
