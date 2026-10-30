import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Comic book ZIPs; declared in Info.plist so the Files app offers them to Dōchō.
    static let cbz = UTType(importedAs: "io.github.grillza.docho.cbz", conformingTo: .zip)
    static let cbr = UTType(importedAs: "io.github.grillza.docho.cbr", conformingTo: .archive)
    static let cb7 = UTType(importedAs: "io.github.grillza.docho.cb7", conformingTo: .archive)
    static let rar = UTType(importedAs: "com.rarlab.rar-archive", conformingTo: .archive)
    static let sevenZip = UTType(importedAs: "org.7-zip.7-zip-archive", conformingTo: .archive)

    /// Everything the Local source reads.
    static let comics: [UTType] = [.cbz, .cbr, .cb7, .zip, .rar, .sevenZip, .epub, .pdf, .folder]
}

/// Adding comics to the Local source from the Files app: pick files or folders, then choose the
/// series they belong to (a new one per file, or one already there).
struct LocalImportModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.m3) private var m3
    @Binding var isPresented: Bool
    /// Called with the series folders added to.
    let onAdded: ([String]) -> Void

    @State private var picked: [URL] = []
    @State private var choosing = false
    @State private var series: String?
    @State private var newName = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: UTType.comics, allowsMultipleSelection: true) { outcome in
                guard case .success(let urls) = outcome, !urls.isEmpty else { return }
                picked = urls
                series = nil
                newName = ""
                // Folders of chapters are series of their own; only ask when files could go anywhere.
                if app.localSource.seriesNames().isEmpty && urls.count == 1 {
                    add(to: nil)
                } else {
                    choosing = true
                }
            }
            .m3Dialog(isPresented: $choosing, title: String(localized: "Add to")) {
                ScrollView {
                    VStack(spacing: 0) {
                        RadioRow(title: String(localized: "A new series for each file"), selected: series == nil && newName.isEmpty) {
                            series = nil
                            newName = ""
                        }
                        M3TextField(label: String(localized: "New series named…"), text: $newName)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .onChange(of: newName) { _, name in if !name.isEmpty { series = nil } }
                        ForEach(app.localSource.seriesNames(), id: \.self) { name in
                            RadioRow(title: name, selected: series == name) {
                                series = name
                                newName = ""
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            } buttons: {
                M3TextButton(title: String(localized: "Cancel")) { choosing = false }
                M3TextButton(title: String(localized: "Add")) {
                    choosing = false
                    add(to: newName.isBlank ? series : newName)
                }
            }
            .m3Dialog(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), title: String(localized: "Couldn't add")) {
                Text(error ?? "").font(M3Type.bodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } buttons: {
                M3TextButton(title: String(localized: "OK")) { error = nil }
            }
    }

    private func add(to series: String?) {
        let urls = picked
        let source = app.localSource
        Task {
            do {
                let added = try await Task.detached { try source.add(urls, series: series) }.value
                onAdded(added)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension View {
    func localImport(isPresented: Binding<Bool>, onAdded: @escaping ([String]) -> Void) -> some View {
        modifier(LocalImportModifier(isPresented: isPresented, onAdded: onAdded))
    }
}
