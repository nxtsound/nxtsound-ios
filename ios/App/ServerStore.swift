import Foundation

/// Remembers the linked server address. The address is not a secret;
/// credentials will go into the keychain later.
final class ServerStore: ObservableObject {
    private let key = "serverURL"
    @Published var serverURL: URL?

    init() {
        if let text = UserDefaults.standard.string(forKey: key) {
            serverURL = URL(string: text)
        }
    }

    func link(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: key)
        serverURL = url
    }

    func unlink() {
        UserDefaults.standard.removeObject(forKey: key)
        serverURL = nil
    }
}
