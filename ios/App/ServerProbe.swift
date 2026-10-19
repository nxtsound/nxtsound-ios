import SwiftUI

/// Checks the entered server address continuously (shortly after typing) and keeps the result ready for display.
@MainActor
final class ServerProbe: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case ok(ServerInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    /// The checked, normalized address once the check has passed.
    private(set) var verifiedURL: URL?

    var isOK: Bool { if case .ok = state { return true } else { return false } }

    func update(_ address: String, delay: Duration = .milliseconds(700)) {
        task?.cancel()
        verifiedURL = nil
        guard ServerCheck.isPlausible(address), let url = try? ServerCheck.normalize(address) else {
            state = .idle
            return
        }
        state = .checking
        task = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            do {
                let info = try await ServerCheck.check(url)
                if Task.isCancelled { return }
                verifiedURL = url
                state = .ok(info)
            } catch {
                if Task.isCancelled { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Result of the connection check under the address field: grey while checking, green on success, red on failure.
struct ProbeResultView: View {
    @ObservedObject var probe: ServerProbe

    var body: some View {
        switch probe.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking connection …") }
                .font(.footnote).foregroundStyle(.secondary)
        case .ok(let info):
            Label(info.version.map { String(localized: "Connected to “\(info.name)” · version \($0)") } ?? String(localized: "Connected to “\(info.name)”"), systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.footnote).foregroundStyle(.red)
        }
    }
}
