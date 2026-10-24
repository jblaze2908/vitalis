import SwiftUI
import VitalisKit

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var url = SettingsStore.baseURL
    @State private var token = ""
    @State private var result: String?
    @State private var working = false
    @State private var confirmReset = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://vitalis.example.com", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Vitalis write token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save settings") { Task { await save() } }
                    Button("Test connection") { Task { await testConnection() } }
                } header: { Text("Server") } footer: {
                    Text("Enter your Vitalis server base URL and a write token. The token is stored only in the device Keychain. Use HTTPS for remote servers.")
                }
                .disabled(working || model.isSyncing)
                if let result {
                    Section("Result") { Text(result).font(.caption).textSelection(.enabled) }
                }
                Section {
                    Button("Retry background delivery") { model.retryBackgroundDelivery() }
                    Button("Reset local export state", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Reset before switching servers. It removes local anchors, pending uploads and sync history, then the next sync backfills everything. Server data stays intact.")
                }.disabled(working || model.isSyncing)
            }
            .navigationTitle("Settings")
            .task {
                do { token = try TokenStore.read() ?? "" }
                catch { result = error.localizedDescription }
            }
            .confirmationDialog("Reset export state and backfill again?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset local export state", role: .destructive) {
                    Task {
                        do { try await model.resetExport(); result = "Local export state reset." }
                        catch { result = error.localizedDescription }
                    }
                }
            }
        }
    }
    private func save() async {
        working = true
        defer { working = false }
        do { try await model.saveSettings(url: url, token: token); result = "Settings saved." }
        catch { result = error.localizedDescription }
    }
    private func testConnection() async {
        working = true
        defer { working = false }
        do {
            try await model.saveSettings(url: url, token: token)
            let response = try await HTTPAPIClient(settings: ServerSettings(url)).status()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            result = "Connected (HTTP 200)\n" + String(decoding: try encoder.encode(response), as: UTF8.self)
        } catch { result = error.localizedDescription }
    }
}
