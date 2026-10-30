import NukeUI
import SwiftUI

/// Settings → Sync / Self-hosted sources → Suwayomi: the server that runs extensions, and the
/// extension repos it fetches them from.
struct SuwayomiSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showNSFW = false
    @State private var loaded = false
    @State private var status: ServerConnection = .unknown
    @State private var addingRepo = false
    @State private var repoURL = ""
    @State private var repoError: String?
    @State private var confirmingDelete = false

    var body: some View {
        let settings = app.suwayomiSettings
        ServerSection(name: "Suwayomi", icon: "brand.suwayomi", status: status, configured: settings.isConfigured) {
            VStack(spacing: 16) {
                M3TextField(
                    label: String(localized: "Server address"), text: $server, keyboard: .URL,
                    supporting: String(localized: "The address you open Suwayomi at, e.g. http://192.168.1.20:4567")
                )
                M3TextField(label: String(localized: "Username"), text: $username)
                M3TextField(
                    label: String(localized: "Password"), text: $password, secure: true,
                    supporting: String(localized: "Only if the server has basic authentication turned on")
                )
            }
            .padding(16)
            PreferenceRow(title: String(localized: "Connection"), subtitle: connectionText(status, configured: settings.isConfigured), action: {
                Task { await check() }
            })
            SwitchPreference(
                title: String(localized: "Show NSFW extensions and sources"), isOn: $showNSFW
            )
            if settings.isConfigured {
                PreferenceHeader(title: String(localized: "Extension repos"))
                if app.suwayomi.stores.isEmpty {
                    Text("Extensions come from repos. Add a repo's index address (from the repo's site) to see its extensions under Browse → Extensions.")
                        .font(M3Type.bodySmall)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(app.suwayomi.stores) { store in
                    PreferenceRow(title: store.name, subtitle: store.indexURL, widget: {
                        AppBarIcon("delete", label: String(localized: "Remove \(store.name)")) {
                            Task { await app.suwayomi.removeStore(store) }
                        }
                        .foregroundStyle(m3.onSurfaceVariant)
                    })
                }
                PreferenceRow(title: String(localized: "Add repo"), icon: "add", action: {
                    repoURL = ""
                    addingRepo = true
                })
            }
            PreferenceRow(
                title: String(localized: "Delete"), subtitle: String(localized: "Erase the Suwayomi settings on this device"),
                icon: "delete", iconTint: m3.error, action: { confirmingDelete = true }
            )
        }
        .m3Dialog(isPresented: $addingRepo, title: String(localized: "Add repo")) {
            VStack(alignment: .leading, spacing: 8) {
                M3TextField(label: String(localized: "Repo index address"), text: $repoURL, keyboard: .URL,
                            supporting: String(localized: "Ends in index.min.json"))
                if let repoError {
                    Text(repoError).font(M3Type.bodySmall).foregroundStyle(m3.error)
                }
            }
            .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { addingRepo = false }
            M3TextButton(title: String(localized: "Add")) {
                let url = repoURL
                Task {
                    do {
                        try await app.suwayomi.addStore(url)
                        addingRepo = false
                        repoError = nil
                    } catch {
                        repoError = error.localizedDescription
                    }
                }
            }
        }
        .m3Dialog(isPresented: $confirmingDelete, title: String(localized: "Delete Suwayomi settings?")) {
            Text("This erases the server address and sign-in on this device. Extensions stay installed on the server.")
                .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingDelete = false }
            M3TextButton(title: String(localized: "Delete"), color: m3.error) {
                confirmingDelete = false
                app.suwayomiSettings.reset()
                server = ""
                username = ""
                password = ""
                status = .unknown
                Task { await app.suwayomi.serverChanged() }
            }
        }
        .onAppear {
            guard !loaded else { return }
            server = settings.serverURL
            username = settings.username
            password = settings.password
            showNSFW = settings.showNSFW
            loaded = true
        }
        .onChange(of: server) { _, value in settings.serverURL = value }
        .onChange(of: username) { _, value in settings.username = value }
        .onChange(of: password) { _, value in settings.password = value }
        .onChange(of: showNSFW) { _, value in settings.showNSFW = value }
        .modifier(DebouncedCheck(key: server + username + password) { await check() })
    }

    private func check() async {
        guard app.suwayomiSettings.isConfigured else {
            status = .unknown
            return
        }
        status = .checking
        do {
            status = .connected(try await app.suwayomi.client.about())
            await app.suwayomi.serverChanged()
            await app.suwayomi.loadExtensions(refresh: false)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Browse → Extensions

/// Mihon's Browse → Extensions, for the extensions on the Suwayomi server: updates, installed,
/// then the rest by language.
struct ExtensionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let query: String

    var body: some View {
        let model = app.suwayomi
        Group {
            if model.extensions.isEmpty, model.isLoading {
                LoadingScreen()
            } else if model.extensions.isEmpty {
                EmptyScreen(message: model.error ?? (model.stores.isEmpty
                    ? String(localized: "No extension repos on the server. Add one in Settings → Sync / Self-hosted sources → Suwayomi.")
                    : String(localized: "No extensions found"))) {
                    M3TextButton(title: String(localized: "Retry")) { Task { await model.loadExtensions(refresh: true) } }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(groups, id: \.title) { group in
                            Text(group.title)
                                .font(M3Type.bodyMedium)
                                .foregroundStyle(m3.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 8)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { ext in
                                ExtensionRow(ext: ext, working: model.working.contains(ext.pkgName))
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .refreshable { await model.loadExtensions(refresh: true) }
            }
        }
        .task {
            if model.extensions.isEmpty { await model.loadExtensions(refresh: true) }
        }
    }

    private var groups: [(title: String, items: [SuwayomiExtension])] {
        let showNSFW = app.suwayomiSettings.showNSFW
        let languages = Set(app.preferences.sourceLanguages)
        let visible = app.suwayomi.extensions.filter { ext in
            // Installed ones always show, so they can be updated or removed.
            (showNSFW || !ext.isNSFW) && (ext.isInstalled || languages.contains(ext.lang))
                && (query.isEmpty || ext.name.localizedCaseInsensitiveContains(query))
        }
        let byName: (SuwayomiExtension, SuwayomiExtension) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var groups: [(String, [SuwayomiExtension])] = []
        let updates = visible.filter { $0.isInstalled && $0.hasUpdate }.sorted(by: byName)
        if !updates.isEmpty { groups.append((String(localized: "Updates pending"), updates)) }
        let installed = visible.filter { $0.isInstalled && !$0.hasUpdate }.sorted(by: byName)
        if !installed.isEmpty { groups.append((String(localized: "Installed"), installed)) }
        let available = Dictionary(grouping: visible.filter { !$0.isInstalled }, by: \.lang)
        let order = available.keys.sorted { Self.languageOrder($0) < Self.languageOrder($1) }
        for lang in order {
            groups.append((Self.languageName(lang), available[lang, default: []].sorted(by: byName)))
        }
        return groups
    }

    /// Mihon's order: all, then the device's language, then the rest by name.
    private static func languageOrder(_ code: String) -> String {
        if code == "all" { return "0" }
        if code == Locale.current.language.languageCode?.identifier { return "1" }
        return "2" + languageName(code)
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "all": String(localized: "Multi")
        case "other", "": String(localized: "Other")
        default: Locale.current.localizedString(forIdentifier: code)?.localizedCapitalized ?? code
        }
    }
}

/// An extension: icon, name, language and version, with Install / Update / Uninstall.
private struct ExtensionRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let ext: SuwayomiExtension
    let working: Bool
    @State private var confirmingUninstall = false

    var body: some View {
        HStack(spacing: 16) {
            LazyImage(request: app.suwayomi.client.request(ext.iconPath).map { ImageRequest(urlRequest: $0) }) { state in
                if let image = state.image { image.resizable().scaledToFit() } else { m3.surfaceContainerHighest }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface).lineLimit(1)
                HStack(spacing: 4) {
                    Text(ExtensionsView.languageName(ext.lang))
                    Text(ext.versionName)
                    if ext.isNSFW { Text("18+").foregroundStyle(m3.error) }
                    if ext.isObsolete { Text("Obsolete").foregroundStyle(m3.error) }
                }
                .font(M3Type.bodySmall)
                .foregroundStyle(m3.onSurfaceVariant)
            }
            Spacer()
            if working {
                ProgressView().tint(m3.primary).frame(width: 40, height: 40)
            } else if ext.isInstalled {
                if ext.hasUpdate {
                    M3TextButton(title: String(localized: "Update")) { Task { await app.suwayomi.change(ext, .update) } }
                }
                AppBarIcon("delete", label: String(localized: "Uninstall")) { confirmingUninstall = true }
                    .foregroundStyle(m3.onSurfaceVariant)
            } else {
                M3TextButton(title: String(localized: "Install")) { Task { await app.suwayomi.change(ext, .install) } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("extension.\(ext.pkgName)")
        .m3Dialog(isPresented: $confirmingUninstall, title: String(localized: "Uninstall \(ext.name)?")) {
            Text("It's removed from the Suwayomi server. Series from it stay in your library, but can't be updated until it's installed again.")
                .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingUninstall = false }
            M3TextButton(title: String(localized: "Uninstall"), color: m3.error) {
                confirmingUninstall = false
                Task { await app.suwayomi.change(ext, .uninstall) }
            }
        }
    }
}

/// Mihon's language filter for Browse: which languages' sources and extensions are listed.
struct LanguagesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3

    var body: some View {
        let languages = Set(app.suwayomi.sourceInfos.map(\.lang) + app.suwayomi.extensions.map(\.lang) + app.preferences.sourceLanguages)
            .sorted { Self.order($0) < Self.order($1) }
        VStack(spacing: 0) {
            Text("Languages")
                .font(M3Type.titleLarge)
                .foregroundStyle(m3.onSurface)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(languages, id: \.self) { lang in
                        SwitchPreference(
                            title: ExtensionsView.languageName(lang),
                            isOn: Binding(
                                get: { app.preferences.sourceLanguages.contains(lang) },
                                set: { on in
                                    var chosen = app.preferences.sourceLanguages.filter { $0 != lang }
                                    if on { chosen.append(lang) }
                                    app.preferences.sourceLanguages = chosen
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    private static func order(_ code: String) -> String {
        if code == "all" { return "0" }
        if code == Locale.current.language.languageCode?.identifier { return "1" }
        return "2" + ExtensionsView.languageName(code)
    }
}
