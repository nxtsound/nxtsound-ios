import Foundation
import WebKit

/// The one server the app is linked to. Whatever the page asks of the native side (play an address, show a picture) is checked against it:
/// a compromised or malicious server cannot use the app to make requests to other hosts, and only the page of the linked server is listened to.
final class TrustedOrigin {
    /// Address of the linked server (kept up to date by the web model).
    var url: URL?

    private static func effectivePort(scheme: String?, port: Int?) -> Int {
        if let port, port > 0 { return port }  // 0 means "the default port" in WebKit's security origin
        return scheme?.lowercased() == "http" ? 80 : 443
    }

    /// Same origin (scheme, host, port) as the linked server?
    static func matches(scheme: String?, host: String?, port: Int?, _ base: URL) -> Bool {
        guard let scheme, let host, let baseHost = base.host else { return false }
        return scheme.lowercased() == base.scheme?.lowercased()
            && host.lowercased() == baseHost.lowercased()
            && effectivePort(scheme: scheme, port: port) == effectivePort(scheme: base.scheme, port: base.port)
    }

    func isSame(_ other: URL) -> Bool {
        guard let url else { return false }
        return Self.matches(scheme: other.scheme, host: other.host, port: other.port, url)
    }

    /// Audio is only played from the stream addresses of the linked server.
    func isStream(_ other: URL) -> Bool {
        isSame(other) && other.path.hasPrefix("/api/stream/") && !other.path.contains("..")
    }

    /// Pictures (covers): from the linked server, or from any https address (covers of plugin tracks are external https pictures that the page shows as well).
    func isPicture(_ other: URL) -> Bool {
        isSame(other) || other.scheme?.lowercased() == "https"
    }

    /// Only the main frame of the linked server may talk to the native side (not an embedded frame, not another site).
    func accepts(_ message: WKScriptMessage) -> Bool {
        guard message.frameInfo.isMainFrame, let url else { return false }
        let origin = message.frameInfo.securityOrigin
        return Self.matches(scheme: origin.`protocol`, host: origin.host, port: origin.port, url)
    }
}
