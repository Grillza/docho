import SwiftUI
import UIKit

/// Settings → Browse → Extension stores (Mihon's and Android Dōchō's Extension stores screen):
/// the repos extensions come from, on Dōchō Server and on this device, as cards with the store's
/// name, open its website, copy its address and remove it; + adds one by its index address.
struct ExtensionStoresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var newURL = ""
    @State private var addToDevice = false
    @State private var addError: String?
    @State private var working = false
    @State private var removing: Store?

    /// A store on either side.
    struct Store: Identifiable, Equatable {
        enum Place { case server, device }
        var place: Place
        var name: String
        var indexURL: String
        var website: String?

        var id: String { "\(place)\(indexURL)" }
    }

    private var serverStores: [Store] {
        app.suwayomi.isConfigured ? app.suwayomi.stores.map { Store(place: .server, name: $0.name, indexURL: $0.indexURL) } : []
    }

    private var deviceStores: [Store] {
        app.deviceExtensions.isEnabled
            ? app.deviceExtensions.repos.map { Store(place: .device, name: $0.name, indexURL: $0.indexUrl, website: $0.website) }
            : []
    }

    /// Both places can take stores: the cards are grouped, and adding asks where.
    private var both: Bool { app.suwayomi.isConfigured && app.deviceExtensions.isEnabled }

    var body: some View {
        VStack(spacing: 0) {
            TopAppBar(title: String(localized: "Extension stores"), showsBack: true) {
                AppBarIcon("refresh", label: String(localized: "Refresh")) { Task { await refresh(fetch: true) } }
            }
            if !app.suwayomi.isConfigured && !app.deviceExtensions.isEnabled {
                EmptyScreen(message: String(localized: "Set up Dōchō Server or Suwayomi, or turn on extensions on this device, to add extension stores."))
            } else if serverStores.isEmpty && deviceStores.isEmpty {
                EmptyScreen(message: String(localized: "You haven't added an extension store yet"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        section(String(localized: "Dōchō Server"), serverStores)
                        section(String(localized: "This device"), deviceStores)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }
            }
        }
        .background(m3.surface)
        .overlay(alignment: .bottomTrailing) {
            if app.suwayomi.isConfigured || app.deviceExtensions.isEnabled {
                Button {
                    newURL = ""
                    addError = nil
                    addToDevice = !app.suwayomi.isConfigured
                    adding = true
                } label: {
                    MIcon("add")
                        .foregroundStyle(m3.onPrimaryContainer)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(m3.primaryContainer))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                }
                .buttonStyle(.plain)
                .padding(16)
                .accessibilityLabel(String(localized: "Add extension store"))
            }
        }
        .task { await refresh(fetch: false) }
        .m3Dialog(isPresented: $adding, title: String(localized: "Add extension store")) {
            VStack(alignment: .leading, spacing: 12) {
                M3TextField(label: String(localized: "Store index URL"), text: $newURL, keyboard: .URL, supporting: String(localized: "Ends in index.min.json"))
                if both {
                    Picker(String(localized: "Add to"), selection: $addToDevice) {
                        Text("Dōchō Server").tag(false)
                        Text("This device").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if working { Text("Processing…").font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant) }
                if let addError { Text(addError).font(M3Type.bodySmall).foregroundStyle(m3.error) }
            }
            .padding(.horizontal, 24)
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { adding = false }
            M3TextButton(title: String(localized: "Add")) { Task { await add() } }
                .disabled(newURL.isBlank || working)
        }
        .m3Dialog(isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), title: String(localized: "Remove extension store")) {
            if let removing {
                Text("Do you wish to remove the extension store \"\(removing.name)\" (\(removing.indexURL))?")
                    .padding(.horizontal, 24)
            }
        } buttons: {
            M3TextButton(title: String(localized: "Cancel")) { removing = nil }
            M3TextButton(title: String(localized: "Remove"), color: m3.error) {
                if let store = removing { Task { await remove(store) } }
                removing = nil
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ stores: [Store]) -> some View {
        if !stores.isEmpty {
            if both {
                Text(title)
                    .font(M3Type.bodyMedium)
                    .foregroundStyle(m3.onSurfaceVariant)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(stores) { store in card(store) }
        }
    }

    private func card(_ store: Store) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                MIcon("label").foregroundStyle(m3.onSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.name).font(M3Type.titleMedium).foregroundStyle(m3.onSurface)
                    Text(store.indexURL).font(M3Type.bodySmall).foregroundStyle(m3.onSurfaceVariant).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding([.top, .horizontal], 16)
            HStack(spacing: 0) {
                Spacer()
                if let website = store.website.flatMap(URL.init(string:)), !(store.website ?? "").isEmpty {
                    AppBarIcon("public", label: String(localized: "Open in browser")) { openURL(website) }
                }
                AppBarIcon("content_copy", label: String(localized: "Copy to clipboard")) { UIPasteboard.general.string = store.indexURL }
                AppBarIcon("delete", label: String(localized: "Delete")) { removing = store }
            }
            .foregroundStyle(m3.onSurfaceVariant)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(m3.surfaceContainerLow))
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        .accessibilityElement(children: .contain)
    }

    private func refresh(fetch: Bool) async {
        if app.suwayomi.isConfigured { await app.suwayomi.loadExtensions(refresh: fetch) }
        if app.deviceExtensions.isEnabled { await app.deviceExtensions.refresh(refreshRepos: fetch) }
    }

    private func add() async {
        working = true
        defer { working = false }
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(serverStores + deviceStores).contains(where: { $0.indexURL == url && ($0.place == .device) == addToDevice }) else {
            addError = String(localized: "This extension store already exists")
            return
        }
        do {
            if addToDevice { try await app.deviceExtensions.addRepo(url) } else { try await app.suwayomi.addStore(url) }
            adding = false
        } catch {
            addError = error.localizedDescription
        }
    }

    private func remove(_ store: Store) async {
        switch store.place {
        case .server:
            if let found = app.suwayomi.stores.first(where: { $0.indexURL == store.indexURL }) { await app.suwayomi.removeStore(found) }
        case .device:
            if let found = app.deviceExtensions.repos.first(where: { $0.indexUrl == store.indexURL }) { await app.deviceExtensions.removeRepo(found) }
        }
    }
}
