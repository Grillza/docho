import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: "Not set")
            } header: {
                Text("Kavita")
            } footer: {
                Text("HTTPS is recommended, for example through Tailscale or a reverse proxy.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.appVersion)
            }
        }
        .navigationTitle("Settings")
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
}
