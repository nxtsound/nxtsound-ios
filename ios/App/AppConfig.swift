import Foundation

/// Central configuration. The display name is maintained here only.
enum AppConfig {
    static let appName = "NxtSound"
    /// Marker that `GET /api/server-info` must return in the `server` field.
    static let serverIdentity = "nxtsound"
    /// Which server `api_version` this app version understands.
    static let supportedAPIVersions = 1...1
}
