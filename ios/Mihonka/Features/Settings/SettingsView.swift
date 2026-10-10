import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var syncProgress = true
    @State private var loaded = false
    @State private var pendingCount = 0

    private var draft: KavitaCredentials {
        KavitaCredentials(serverURL: serverURL, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var serverURLIsValid: Bool {
        serverURL.isBlank || KavitaClient.normalizeApiURL(serverURL) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $serverURL, prompt: Text("e.g. https://kavita.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("kavita.serverURL")
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("kavita.apiKey")
                Button {
                    Task { await model.kavita.checkConnection() }
                } label: {
                    ConnectionRow(connection: model.connection, configured: draft.isConfigured)
                }
                .buttonStyle(.plain)
                .disabled(!draft.isConfigured || model.connection == .checking)
            } header: {
                Text("Kavita server")
            } footer: {
                if serverURLIsValid {
                    Text(
                        "Copy the API key from Kavita: your user settings, under API Key / OPDS. "
                            + "HTTPS is recommended, for example through Tailscale or a reverse proxy."
                    )
                } else {
                    Text("That isn't a valid server address.").foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Sync reading progress", isOn: $syncProgress)
                    .onChange(of: syncProgress) {
                        model.settings.syncProgress = syncProgress
                        if syncProgress { Task { await model.sync.syncQueued() } }
                    }
                if pendingCount > 0 {
                    LabeledContent("Waiting to be sent", value: "\(pendingCount)")
                        .accessibilityIdentifier("sync.pending")
                    Button("Send Now") {
                        Task { await model.sync.syncQueued() }
                    }
                    .disabled(!syncProgress)
                }
            } header: {
                Text("Reading progress")
            } footer: {
                Text(
                    "Sends every page you read to Kavita and picks up the page reached on other devices. "
                        + "The side that has read further wins."
                )
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.appVersion)
            }
        }
        .navigationTitle("Settings")
        .task {
            do {
                for try await count in model.database.pendingCount() { pendingCount = count }
            } catch {}
        }
        .onAppear {
            guard !loaded else { return }
            serverURL = model.settings.serverURL
            apiKey = model.settings.apiKey
            syncProgress = model.settings.syncProgress
            loaded = true
        }
        // Save and check on opening, and again shortly after the address or key is edited.
        .task(id: loaded ? draft : nil) {
            guard loaded, serverURLIsValid else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.settings.serverURL = draft.serverURL
            model.settings.apiKey = draft.apiKey
            await model.kavita.checkConnection()
        }
    }
}

private struct ConnectionRow: View {
    let connection: KavitaConnection
    let configured: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection").foregroundStyle(.primary)
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if connection == .checking {
                ProgressView()
            }
        }
        .contentShape(.rect)
    }

    private var color: Color {
        switch connection {
        case .connected: .green
        case .failed: .red
        case .checking, .unknown: .secondary
        }
    }

    private var status: String {
        switch connection {
        case .unknown where configured:
            String(localized: "Tap to check the connection")
        case .unknown:
            String(localized: "Enter the server address and API key first")
        case .checking:
            String(localized: "Connecting…")
        case .connected(let username, let version?):
            String(localized: "Connected to Kavita \(version) as \(username)")
        case .connected(let username, nil):
            String(localized: "Connected to Kavita as \(username)")
        case .failed(let reason):
            String(localized: "Couldn't connect: \(reason)")
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(AppModel())
}
