import SwiftUI

struct SetupView: View {
    @ObservedObject var store: ServerStore
    @StateObject private var probe = ServerProbe()
    @State private var address = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("Logo")
                .resizable().scaledToFit().frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(AppConfig.appName).font(.largeTitle.bold())
            Text("Enter your server's address.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextField("music.example.com", text: $address)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 54)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(borderColor, lineWidth: 1.5))
                    .contentShape(Rectangle())
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .onChange(of: address) { _, value in probe.update(value) }
                ProbeResultView(probe: probe)
                    .frame(minHeight: 20, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            Button(action: connect) {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!probe.isOK)
            Spacer()
        }
        .padding(24)
    }

    private var borderColor: Color {
        switch probe.state {
        case .ok: return .green
        case .failed: return .red
        default: return .clear
        }
    }

    private func connect() {
        guard probe.isOK, let url = probe.verifiedURL else { return }
        store.link(url)
    }
}
