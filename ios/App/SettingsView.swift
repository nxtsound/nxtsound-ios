import SwiftUI

/// App settings (modelled on the Home Assistant app): change server, reload, log out.
struct SettingsView: View {
    @ObservedObject var store: ServerStore
    @ObservedObject var model: WebModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var probe = ServerProbe()
    @State private var address = ""
    @State private var confirmUnlink = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("music.example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onChange(of: address) { _, value in probe.update(value) }
                    ProbeResultView(probe: probe)
                    Button("Save address", action: saveAddress)
                        .disabled(!probe.isOK || probe.verifiedURL == store.serverURL)
                }

                Section {
                    Button("Reload page") { dismiss(); model.reload() }
                }

                Section {
                    Button("Log out and remove server", role: .destructive) { confirmUnlink = true }
                } footer: {
                    Text("Deletes the session on this device and asks for the server address again at the next start.")
                }

                Section("Info") {
                    LabeledContent(AppConfig.appName, value: version)
                }
            }
            .navigationTitle("App settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Really log out?", isPresented: $confirmUnlink, titleVisibility: .visible) {
                Button("Log out", role: .destructive) {
                    model.clearSession { dismiss(); store.unlink() }
                }
            }
        }
        .onAppear {
            address = store.serverURL?.absoluteString ?? ""
            probe.update(address, delay: .milliseconds(0))
        }
    }

    private func saveAddress() {
        guard probe.isOK, let url = probe.verifiedURL else { return }
        store.link(url)
        dismiss()
        model.load(url)
    }
}
