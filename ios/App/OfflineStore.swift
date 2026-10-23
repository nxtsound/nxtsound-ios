import Foundation
import Network
import CryptoKit
import WebKit

/// Is there a network connection at all? (Not "is the server reachable": that is the web model's business.)
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    /// Cellular or a personal hotspot: big downloads wait for Wi-Fi if the user wants that.
    @Published private(set) var isExpensive = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let online = path.status == .satisfied
                if self.isOnline != online { self.isOnline = online }
                if self.isExpensive != path.isExpensive { self.isExpensive = path.isExpensive }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.nxtsound.network"))
    }

    deinit { monitor.cancel() }
}

/// A song kept on the device.
struct OfflineTrack: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    /// File names inside the store's folder.
    let file: String
    let cover: String?
}

/// A song the user chose to keep (from a search in the library), whatever the automatic selection says.
struct PinnedSong: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let thumb: String?
}

/// Keeps a selection of songs on the device for listening without a connection: the last songs the user played and their most played ones
/// (the server decides which, see `GET /api/me/offline-set`). Everything lives in one folder per server that is left out of backups and deleted on logout.
@MainActor
final class OfflineStore: ObservableObject {
    /// How many of each the server is asked for (the user can change both; the server allows up to 50).
    static let defaultCount = 20
    static let maxCount = 50
    /// A download that gets bigger than this is dropped (a whole audiobook is not "a song"); the whole selection stays below the total limit.
    private static let maxFileBytes: Int64 = 250_000_000
    private static let maxTotalBytes: Int64 = 3_000_000_000
    private static let minInterval: TimeInterval = 30 * 60

    private enum Key {
        static let enabled = "offlineEnabled"
        static let wifiOnly = "offlineWifiOnly"
        static let lastSync = "offlineLastSync"
        static let recent = "offlineRecentCount"
        static let top = "offlineTopCount"
    }

    @Published private(set) var tracks: [OfflineTrack] = []
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Key.enabled)
            if !enabled { removeAll() }
        }
    }
    @Published var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Key.wifiOnly) }
    }
    /// How many of the last played and of the most played songs are kept automatically.
    @Published var recentCount: Int {
        didSet { UserDefaults.standard.set(recentCount, forKey: Key.recent); UserDefaults.standard.removeObject(forKey: Key.lastSync) }
    }
    @Published var topCount: Int {
        didSet { UserDefaults.standard.set(topCount, forKey: Key.top); UserDefaults.standard.removeObject(forKey: Key.lastSync) }
    }
    /// Songs chosen by hand: they are always kept, before the automatic ones.
    @Published private(set) var pinned: [PinnedSong] = []

    private var dir: URL?
    private var server: URL?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    init() {
        enabled = UserDefaults.standard.bool(forKey: Key.enabled)
        wifiOnly = UserDefaults.standard.object(forKey: Key.wifiOnly) as? Bool ?? true
        recentCount = min(Self.maxCount, max(0, UserDefaults.standard.object(forKey: Key.recent) as? Int ?? Self.defaultCount))
        topCount = min(Self.maxCount, max(0, UserDefaults.standard.object(forKey: Key.top) as? Int ?? Self.defaultCount))
    }

    // MARK: Folder

    /// Points the store at a server (its own folder per address, so two servers never mix).
    func bind(_ url: URL?) {
        guard url != server else { return }
        server = url
        dir = nil
        tracks = []
        pinned = []
        bytes = 0
        guard let url, var base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        base.append(path: "Offline", directoryHint: .isDirectory)
        base.append(path: Self.hash(url.absoluteString), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        dir = base
        if let data = try? Data(contentsOf: base.appending(path: "tracks.json")), let list = try? JSONDecoder().decode([OfflineTrack].self, from: data) {
            tracks = list.filter { FileManager.default.fileExists(atPath: base.appending(path: $0.file).path) }
        }
        if let data = try? Data(contentsOf: base.appending(path: "pinned.json")), let list = try? JSONDecoder().decode([PinnedSong].self, from: data) { pinned = list }
        bytes = folderSize()
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(_ track: OfflineTrack) -> URL? { dir?.appending(path: track.file) }
    func coverURL(_ track: OfflineTrack) -> URL? { track.cover.flatMap { dir?.appending(path: $0) } }

    /// The songs as the native player takes them (local files).
    func nativeTracks() -> [NativeTrack] {
        tracks.compactMap { t in
            guard let url = fileURL(t) else { return nil }
            return NativeTrack(id: t.id, url: url, title: t.title, artist: t.artist, album: t.album, thumb: coverURL(t))
        }
    }

    private func folderSize() -> Int64 {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func saveIndex() {
        guard let dir, let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: dir.appending(path: "tracks.json"), options: .atomic)
    }

    /// Deletes everything that was saved (switching off, logout).
    func removeAll() {
        if let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        tracks = []
        pinned = []
        bytes = 0
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Key.lastSync)
    }

    // MARK: Songs chosen by hand

    func pin(_ song: PinnedSong) {
        guard !pinned.contains(where: { $0.id == song.id }) else { return }
        pinned.append(song)
        savePinned()
    }

    func unpin(_ id: String) {
        pinned.removeAll { $0.id == id }
        savePinned()
    }

    private func savePinned() {
        guard let dir, let data = try? JSONEncoder().encode(pinned) else { return }
        try? data.write(to: dir.appending(path: "pinned.json"), options: .atomic)
        UserDefaults.standard.removeObject(forKey: Key.lastSync)
    }

    /// Songs of the library that match a search (the server's own files, which can be kept).
    func search(_ text: String, cookies: [HTTPCookie]) async -> [PinnedSong] {
        guard let server, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)
        comps?.path = "/api/search"
        comps?.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "kind", value: "songs"), URLQueryItem(name: "source", value: "local")]
        guard let url = comps?.url, let (data, response) = try? await session.data(for: request(url, cookies: cookies)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let found = try? JSONDecoder().decode(SearchResult.self, from: data) else { return [] }
        return found.items.prefix(40).map { PinnedSong(id: $0.id, title: $0.title ?? "", artist: $0.artist ?? "", album: $0.album ?? "", thumb: $0.thumb) }
    }

    private struct SearchResult: Decodable { let items: [Remote] }

    // MARK: Synchronising

    private struct Remote: Decodable {
        let id: String
        let title: String?
        let artist: String?
        let album: String?
        let thumb: String?
    }

    private struct RemoteSet: Decodable { let tracks: [Remote] }

    /// Starts a round if switched on, connected, allowed on this connection, and the last one is a while ago (or `force`).
    func syncIfDue(cookies store: WKHTTPCookieStore, network: NetworkMonitor) async {
        guard enabled, network.isOnline, !(wifiOnly && network.isExpensive) else { return }
        let last = UserDefaults.standard.object(forKey: Key.lastSync) as? Date
        if let last, Date().timeIntervalSince(last) < Self.minInterval, !tracks.isEmpty { return }
        await sync(cookies: store)
    }

    /// Fetches the selection from the server, downloads what is missing and deletes what is no longer in it.
    func sync(cookies store: WKHTTPCookieStore) async {
        guard enabled, !syncing, let server, let dir else { return }
        syncing = true
        lastError = nil
        defer { syncing = false }
        let cookies = await store.allCookies()
        do {
            var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)
            comps?.path = "/api/me/offline-set"
            comps?.queryItems = [URLQueryItem(name: "recent", value: String(recentCount)), URLQueryItem(name: "top", value: String(topCount))]
            guard let url = comps?.url else { return }
            let (data, response) = try await session.data(for: request(url, cookies: cookies))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = String(localized: "The server did not accept the request. Are you logged in?")
                return
            }
            let chosen = pinned.map { Remote(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, thumb: $0.thumb) }
            let picked = try JSONDecoder().decode(RemoteSet.self, from: data).tracks
            let wanted = chosen + picked.filter { p in !chosen.contains { $0.id == p.id } }  // the chosen ones first: they win when space runs out
            var kept: [OfflineTrack] = []
            var total: Int64 = 0
            for remote in wanted {
                if let have = tracks.first(where: { $0.id == remote.id }), FileManager.default.fileExists(atPath: dir.appending(path: have.file).path) {
                    kept.append(have)
                    total += fileSize(dir.appending(path: have.file))
                    continue
                }
                if total >= Self.maxTotalBytes { continue }
                if let added = await download(remote, server: server, cookies: cookies, into: dir) {
                    kept.append(added)
                    total += fileSize(dir.appending(path: added.file))
                    tracks = kept  // the list grows while downloading
                }
            }
            tracks = kept
            let names = Set(kept.flatMap { [$0.file] + ($0.cover.map { [$0] } ?? []) } + ["tracks.json", "pinned.json"])
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !names.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
            saveIndex()
            bytes = folderSize()
            UserDefaults.standard.set(Date(), forKey: Key.lastSync)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func request(_ url: URL, cookies: [HTTPCookie]) -> URLRequest {
        var request = URLRequest(url: url)
        if let host = url.host {
            let relevant = cookies.filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            for (key, value) in HTTPCookie.requestHeaderFields(with: relevant) { request.setValue(value, forHTTPHeaderField: key) }
        }
        return request
    }

    private static let extensions = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac",
        "audio/flac": "flac", "audio/x-flac": "flac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/ogg": "ogg", "audio/opus": "opus",
    ]

    /// One song (and its cover, if there is one). Nil if anything about it is off: it is simply left out this round.
    private func download(_ remote: Remote, server: URL, cookies: [HTTPCookie], into dir: URL) async -> OfflineTrack? {
        guard let encoded = remote.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "/api/stream/" + encoded, relativeTo: server)?.absoluteURL else { return nil }
        do {
            let (temp, response) = try await session.download(for: request(url, cookies: cookies))
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, fileSize(temp) <= Self.maxFileBytes, fileSize(temp) > 0 else { return nil }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard mime.hasPrefix("audio/") || mime == "application/octet-stream" else { return nil }
            let name = Self.hash(remote.id)
            let file = name + "." + (Self.extensions[mime] ?? "mp3")
            let target = dir.appending(path: file)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            let cover = await downloadCover(remote.thumb, server: server, cookies: cookies, as: name + ".img", into: dir)
            return OfflineTrack(id: remote.id, title: remote.title ?? "", artist: remote.artist ?? "", album: remote.album ?? "", file: file, cover: cover)
        } catch {
            return nil
        }
    }

    private func downloadCover(_ thumb: String?, server: URL, cookies: [HTTPCookie], as name: String, into dir: URL) async -> String? {
        guard let thumb, !thumb.isEmpty, let url = URL(string: thumb, relativeTo: server)?.absoluteURL else { return nil }
        let sameServer = TrustedOrigin.matches(scheme: url.scheme, host: url.host, port: url.port, server)
        guard sameServer || url.scheme?.lowercased() == "https" else { return nil }  // like the page: the server's own covers or any https picture
        do {
            let (data, response) = try await session.data(for: sameServer ? request(url, cookies: cookies) : URLRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000, UIImage(data: data) != nil else { return nil }
            try data.write(to: dir.appending(path: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}
