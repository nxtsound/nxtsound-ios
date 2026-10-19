import Foundation

/// Response of `GET /api/server-info`.
struct ServerInfo: Decodable, Equatable {
    let server: String?
    let name: String
    let version: String?
    let apiVersion: Int?

    enum CodingKeys: String, CodingKey {
        case server, name, version
        case apiVersion = "api_version"
    }
}

enum ServerCheckError: LocalizedError, Equatable {
    case invalidURL
    case unreachable(String)
    case notNxtSound
    case redirected(String)
    case appTooOld
    case serverTooOld

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "That is not a valid address.")
        case .unreachable(let why): return String(localized: "Server unreachable: \(why)")
        case .notNxtSound: return String(localized: "This is not a \(AppConfig.appName) server.")
        case .redirected(let host): return String(localized: "The address redirects to \(host). Please enter the final address.")
        case .appTooOld: return String(localized: "The server is newer than this app. Please update the app.")
        case .serverTooOld: return String(localized: "The server is too old for this app. Please update the server.")
        }
    }
}

enum ServerCheck {
    /// Turns input like "music.example.com" into a URL (without a scheme: https).
    static func normalize(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServerCheckError.invalidURL }
        if !text.contains("://") { text = (isLocalHost(hostPart(of: text)) ? "http://" : "https://") + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { throw ServerCheckError.invalidURL }
        return url
    }

    /// Is the input a usable address (domain with a TLD, IPv4, localhost or *.local)?
    /// Checked continuously while typing so "Connect" only becomes active for sensible input.
    static func isPlausible(_ input: String) -> Bool {
        guard let url = try? normalize(input), let rawHost = url.host else { return false }
        let host = rawHost.lowercased()
        if host.count > 253 { return false }
        if host == "localhost" { return true }
        if host.hasPrefix("[") { return host.count > 4 }  // IPv6
        let parts: [String] = host.components(separatedBy: ".")
        if isIPv4(parts) { return true }
        if parts.count < 2 { return false }
        let tld = parts[parts.count - 1]
        if tld.count < 2 { return false }
        if !(host.hasSuffix(".local") || tld.allSatisfy({ $0.isLetter })) { return false }
        for label in parts where !isValidLabel(label) { return false }
        return true
    }

    private static func isIPv4(_ parts: [String]) -> Bool {
        if parts.count != 4 { return false }
        for part in parts where part.isEmpty || part.count > 3 || UInt8(part) == nil { return false }
        return true
    }

    private static func isValidLabel(_ label: String) -> Bool {
        if label.isEmpty || label.count > 63 || label.hasPrefix("-") || label.hasSuffix("-") { return false }
        for ch in label where !(ch.isLetter || ch.isNumber || ch == "-") { return false }
        return true
    }

    /// Host part of an input without a scheme ("192.168.1.5:8000/x" -> "192.168.1.5").
    private static func hostPart(of text: String) -> String {
        var t = text
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        if t.hasPrefix("[") { return t }
        if let colon = t.firstIndex(of: ":") { t = String(t[..<colon]) }
        return t.lowercased()
    }

    /// Addresses on the local network for which iOS allows unencrypted HTTP (localhost, IPv4, *.local, names without a dot).
    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        return isIPv4(host.components(separatedBy: "."))
    }

    /// Evaluates the response to `/api/server-info`. Only a server that identifies itself as a NxtSound server counts as connected;
    /// arbitrary websites (even ones that answer on the home page) are rejected.
    static func verify(status: Int, data: Data) throws -> ServerInfo {
        if status >= 500 { throw ServerCheckError.unreachable("HTTP \(status)") }
        guard status == 200,
              let info = try? JSONDecoder().decode(ServerInfo.self, from: data),
              info.server == AppConfig.serverIdentity,
              let api = info.apiVersion
        else { throw ServerCheckError.notNxtSound }
        if api > AppConfig.supportedAPIVersions.upperBound { throw ServerCheckError.appTooOld }
        if api < AppConfig.supportedAPIVersions.lowerBound { throw ServerCheckError.serverTooOld }
        return info
    }

    /// Queries `/api/server-info` (without cookies, without a redirect to another host).
    static func check(_ base: URL) async throws -> ServerInfo {
        var request = URLRequest(url: base.appendingPathComponent("api/server-info"))
        request.timeoutInterval = 8
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, response) = try await session.data(for: request)
            if let finalHost = response.url?.host, finalHost.lowercased() != base.host?.lowercased() {
                throw ServerCheckError.redirected(finalHost)
            }
            return try verify(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch let error as ServerCheckError {
            throw error
        } catch {
            throw ServerCheckError.unreachable(error.localizedDescription)
        }
    }
}
