import NukeUI
import SwiftUI

/// Browse → Extensions for extensions on this device (Mihon's Extensions tab): updates, those
/// waiting to be trusted, installed, then the rest by language. Repos are added by their URL;
/// the app suggests none (PLAN-2's App Store route).
struct DeviceExtensionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3

    typealias RPC = ExtensionRPC

    var body: some View {
        let model = app.deviceExtensions
        Group {
            switch model.status {
            case .unavailable:
                EmptyScreen(message: String(localized: "This build of Dōchō can't run extensions on the device."))
            case .starting where model.installed.isEmpty && model.available.isEmpty:
                VStack(spacing: 12) {
                    ProgressView().tint(m3.primary)
                    Text("Starting extensions…").font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where model.installed.isEmpty && model.available.isEmpty:
                EmptyScreen(message: String(localized: "Extensions didn't start: \(message)")) {
                    M3TextButton(title: String(localized: "Retry")) { Task { await model.refresh() } }
                }
            default:
                if model.repos.isEmpty, model.installed.isEmpty, !model.isLoading {
                    EmptyScreen(message: String(localized: "Extensions come from repos. Add a repo's index address (from the repo's site) to see its extensions here.")) {
                        NavigationLink(value: Route.extensionStores) {
                            Text("Add extension store").font(M3Type.labelLarge).foregroundStyle(m3.primary)
                        }
                    }
                } else {
                    list
                }
            }
        }
        .task { await model.refresh() }
    }

    private var list: some View {
        let model = app.deviceExtensions
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    NavigationLink(value: Route.extensionStores) {
                        Text("Extension stores").font(M3Type.labelLarge).foregroundStyle(m3.primary).padding(.horizontal, 12).frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                if let error = model.error {
                    Text(error).font(M3Type.bodySmall).foregroundStyle(m3.error).padding(.horizontal, 16).padding(.bottom, 8)
                }
                ForEach(groups, id: \.title) { group in
                    Text(group.title)
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.items) { item in
                        DeviceExtensionRow(item: item)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await model.refresh(refreshRepos: true) }
    }

    /// One row: an installed extension, an available one, or both (an update).
    struct Item: Identifiable {
        var installed: RPC.InstalledExtension?
        var available: RPC.AvailableExtension?

        var id: String { installed?.pkgName ?? available?.pkgName ?? "" }
        var name: String { installed?.name ?? available?.name ?? "" }
        var lang: String { installed?.lang ?? available?.lang ?? "" }
        var version: String { installed?.versionName ?? available?.versionName ?? "" }
        var isNSFW: Bool { (installed?.contentWarning ?? available?.contentWarning) == .nsfw }
    }

    private var groups: [(title: String, items: [Item])] {
        let model = app.deviceExtensions
        let languages = Set(app.preferences.sourceLanguages)
        let preferences = app.preferences
        let installedIds = Set(model.installed.map(\.pkgName))
        let byName: (Item, Item) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let installed = model.installed
            .filter { preferences.allows(contentWarning: $0.contentWarning.rawValue, installed: true) }
            .map { ext in Item(installed: ext, available: model.available.first { $0.pkgName == ext.pkgName }) }
        var groups: [(String, [Item])] = []
        let untrusted = installed.filter { $0.installed?.isTrusted == false }.sorted(by: byName)
        if !untrusted.isEmpty { groups.append((String(localized: "Waiting to be trusted"), untrusted)) }
        let updates = installed.filter { $0.installed?.isTrusted == true && $0.installed?.hasUpdate == true }.sorted(by: byName)
        if !updates.isEmpty { groups.append((String(localized: "Updates pending"), updates)) }
        let current = installed.filter { $0.installed?.isTrusted == true && $0.installed?.hasUpdate == false }.sorted(by: byName)
        if !current.isEmpty { groups.append((String(localized: "Installed"), current)) }
        let rest = model.available
            .filter { !installedIds.contains($0.pkgName) && preferences.allows(contentWarning: $0.contentWarning.rawValue, installed: false) && languages.contains($0.lang) }
            .map { Item(available: $0) }
        let byLang = Dictionary(grouping: rest, by: \.lang)
        for lang in byLang.keys.sorted(by: { ExtensionsView.languageName($0) < ExtensionsView.languageName($1) }) {
            groups.append((ExtensionsView.languageName(lang), byLang[lang, default: []].sorted(by: byName)))
        }
        return groups
    }
}

/// An extension on this device: icon, name, language and version, with Install, Update, Trust and Uninstall.
private struct DeviceExtensionRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    let item: DeviceExtensionsView.Item
    @State private var confirmingUninstall = false
    @State private var confirmingTrust = false

    var body: some View {
        let model = app.deviceExtensions
        let working = model.progress[item.id]
        HStack(spacing: 16) {
            LazyImage(url: model.iconURL(item.id)) { state in
                if let image = state.image { image.resizable().scaledToFit() } else { m3.surfaceContainerHighest }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(M3Type.bodyMedium).foregroundStyle(m3.onSurface).lineLimit(1)
                HStack(spacing: 4) {
                    Text(ExtensionsView.languageName(item.lang))
                    Text(item.version)
                    if item.isNSFW { Text("18+").foregroundStyle(m3.error) }
                    if item.installed?.isObsolete == true { Text("Obsolete").foregroundStyle(m3.error) }
                }
                .font(M3Type.bodySmall)
                .foregroundStyle(m3.onSurfaceVariant)
            }
            Spacer()
            if let working {
                if let fraction = working {
                    ProgressView(value: fraction).tint(m3.primary).frame(width: 40)
                } else {
                    ProgressView().tint(m3.primary).frame(width: 40, height: 40)
                }
            } else if let installed = item.installed {
                if !installed.isTrusted {
                    M3TextButton(title: String(localized: "Trust")) { confirmingTrust = true }
                } else if installed.hasUpdate {
                    M3TextButton(title: String(localized: "Update")) { Task { await model.update(installed) } }
                }
                AppBarIcon("delete", label: String(localized: "Uninstall")) { confirmingUninstall = true }
                    .foregroundStyle(m3.onSurfaceVariant)
            } else if let available = item.available {
                M3TextButton(title: String(localized: "Install")) { Task { await model.install(available) } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deviceExtension.\(item.id)")
        .m3Dialog(isPresented: $confirmingUninstall, title: String(localized: "Uninstall \(item.name)?")) {
            Text("Series from it stay in your library, but can't be updated until it's installed again.")
                .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingUninstall = false }
            M3TextButton(title: String(localized: "Uninstall"), color: m3.error) {
                confirmingUninstall = false
                if let installed = item.installed { Task { await model.uninstall(installed) } }
            }
        }
        .m3Dialog(isPresented: $confirmingTrust, title: String(localized: "Trust \(item.name)?")) {
            Text("This extension is signed by a key Dōchō doesn't know. Extensions run code on your device; only trust ones from repos you trust.")
                .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { confirmingTrust = false }
            M3TextButton(title: String(localized: "Trust")) {
                confirmingTrust = false
                if let installed = item.installed { Task { await model.trust(installed) } }
            }
        }
    }
}
