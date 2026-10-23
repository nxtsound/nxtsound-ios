import SwiftUI

/// App settings (modelled on the Home Assistant app): change server, reload, log out.
struct SettingsView: View {
    @ObservedObject var store: ServerStore
    @ObservedObject var model: WebModel
    @ObservedObject var offline: OfflineStore
    @ObservedObject var network: NetworkMonitor
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

                offlineSection

                Section {
                    Button("Reload page") { dismiss(); model.reload() }
                    Button("Reset app cache") { dismiss(); model.resetCache() }
                } footer: {
                    Text("The app keeps its pages on the device so it can open without a connection. Resetting loads them from the server again; you stay logged in.")
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
                    offline.removeAll()  // what was saved belongs to this account
                    model.clearSession { dismiss(); store.unlink() }
                }
            }
        }
        .onAppear {
            address = store.serverURL?.absoluteString ?? ""
            probe.update(address, delay: .milliseconds(0))
        }
    }

    private var offlineSection: some View {
        Section {
            Toggle("Keep songs for offline listening", isOn: $offline.enabled)
                .onChange(of: offline.enabled) { _, on in if on { updateOffline() } }
            if offline.enabled {
                Toggle("Only on Wi-Fi", isOn: $offline.wifiOnly)
                Stepper(value: $offline.recentCount, in: 0...OfflineStore.maxCount) { LabeledContent("Last played", value: "\(offline.recentCount)") }
                Stepper(value: $offline.topCount, in: 0...OfflineStore.maxCount) { LabeledContent("Most played", value: "\(offline.topCount)") }
                NavigationLink {
                    OfflineChooseView(offline: offline, model: model, network: network)
                } label: {
                    LabeledContent("Chosen songs", value: "\(offline.pinned.count)")
                }
                LabeledContent("Saved", value: "\(offline.tracks.count) · \(ByteCountFormatter.string(fromByteCount: offline.bytes, countStyle: .file))")
                Button(offline.syncing ? LocalizedStringKey("Updating …") : LocalizedStringKey("Update now"), action: updateOffline).disabled(offline.syncing || !network.isOnline)
                if let error = offline.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Delete saved songs", role: .destructive) { offline.removeAll() }
                    .disabled(offline.tracks.isEmpty)
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("Saves the songs you played last, your most played ones and the songs you chose on this device, so you can keep listening without a connection. The selection is updated when the app is online.")
        }
    }

    private func updateOffline() {
        Task { await offline.sync(cookies: model.cookieStore) }
    }

    private func saveAddress() {
        guard probe.isOK, let url = probe.verifiedURL else { return }
        store.link(url)
        dismiss()
        model.load(url)
    }
}
