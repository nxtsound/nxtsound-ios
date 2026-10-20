import SwiftUI
import WebKit

/// Owns the web view together with the native player and lock-screen bridge, and watches the page load.
final class WebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// How long the server may take for the first answer before the error view appears.
    static let timeout: TimeInterval = 12

    /// Adds "App settings" to the profile menu and to the account page of the web UI.
    /// Wraps the page functions `sheetMenu` and `viewAccount`; if they are missing, nothing happens.
    static var menuScript: String {
        let label = String(localized: "App settings").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
    (function () {
      var open = function () { try { webkit.messageHandlers.appSettings.postMessage(1); } catch (e) {} };
      if (typeof sheetMenu === 'function') {
        var origMenu = sheetMenu;
        sheetMenu = function (title, items) {
          var isProfile = typeof S !== 'undefined' && S.user && title === S.user.name && Array.isArray(items);
          if (isProfile) {
            items = items.slice();
            items.splice(Math.min(1, items.length), 0, { label: '\(label)', fn: open });
          }
          return origMenu.call(this, title, items);
        };
      }
      if (typeof viewAccount === 'function') {
        var origAccount = viewAccount;
        viewAccount = async function () {
          var r = await origAccount.apply(this, arguments);
          var box = document.querySelector('.acct .acard:last-child .actions');
          if (box && !box.querySelector('[data-app-settings]')) {
            var b = document.createElement('button');
            b.className = 'btn sec'; b.textContent = '\(label)'; b.setAttribute('data-app-settings', '');
            b.addEventListener('click', open);
            box.insertBefore(b, box.firstChild);
          }
          return r;
        };
      }
    })();
    """
    }

    @Published var state: LoadState = .loading
    @Published var showSettings = false

    let webView: WKWebView
    /// The linked server: everything the page asks of the native side is checked against it (see TrustedOrigin).
    private let origin = TrustedOrigin()
    private let audio = NativeAudio()
    private let bridge = NowPlayingBridge()
    private var timer: Timer?
    private(set) var url: URL

    init(url: URL) {
        self.url = url
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Edge to edge: the page takes care of the safe area itself (viewport-fit=cover, env(safe-area-inset-*)).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.underPageBackgroundColor = .black

        origin.url = url
        audio.origin = origin
        bridge.origin = origin
        bridge.audio = audio
        audio.onPlayback = { [weak bridge] e, d, p in bridge?.updatePlayback(elapsed: e, duration: d, playing: p) }
        audio.onTrack = { [weak bridge] t in bridge?.setTrack(title: t.title, artist: t.artist, album: t.album, artwork: t.thumb) }
        audio.onPageCommand = { [weak bridge] name in bridge?.fire(name) }
        audio.attach(to: webView)
        bridge.attach(to: webView)

        // Settings: three-finger tap, or the page calls `webkit.messageHandlers.appSettings.postMessage(1)`.
        webView.configuration.userContentController.add(self, name: "appSettings")
        webView.configuration.userContentController.addUserScript(WKUserScript(source: Self.menuScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let tap = UITapGestureRecognizer(target: self, action: #selector(openSettings))
        tap.numberOfTouchesRequired = 3
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)

        load()
    }

    /// Loads the web UI only once the server identifies itself as a NxtSound server (otherwise error view).
    func load(_ newURL: URL? = nil) {
        if let newURL { url = newURL; origin.url = newURL }
        state = .loading
        let target = url
        Task { @MainActor in
            do {
                _ = try await ServerCheck.check(target)
                guard target == self.url else { return }
                self.webView.load(URLRequest(url: target))
                self.armTimer()
            } catch {
                guard target == self.url else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func reload() {
        if webView.url == nil { load() } else { state = .loading; webView.reload() }
        armTimer()
    }

    // MARK: Timeout

    private func armTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            guard let self, self.state == .loading else { return }
            self.webView.stopLoading()
            self.state = .failed(String(localized: "The server does not respond."))
        }
    }

    private func disarmTimer() { timer?.invalidate(); timer = nil }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if state != .loading { state = .loading }
        armTimer()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        disarmTimer()
        state = .loaded
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled { return }  // cancelled by the timer or a new request
        disarmTimer()
        state = .failed(error.localizedDescription)
    }

    // MARK: Linked server only

    /// Same origin as the linked server address (scheme, host, port).
    private func isSameOrigin(_ other: URL) -> Bool { origin.isSame(other) }

    /// The app is not a browser: the main window only goes to the linked server. Links to other websites open in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == false || isSameOrigin(target) || target.scheme == "blob" || target.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        if let scheme = target.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
            UIApplication.shared.open(target)
        }
        decisionHandler(.cancel)
    }

    /// No additional windows (target="_blank"): foreign addresses go to Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = action.request.url, !isSameOrigin(target), ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(target)
        } else if let target = action.request.url, isSameOrigin(target) {
            webView.load(action.request)
        }
        return nil
    }

    // MARK: JavaScript dialogs

    /// WKWebView swallows alert()/confirm()/prompt() unless the app presents them itself (confirm() would silently return false).
    private func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard let vc = topController() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler() })
        vc.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard let vc = topController() else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler(true) })
        vc.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let vc = topController() else { completionHandler(nil); return }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        vc.present(alert, animated: true)
    }

    // MARK: Settings

    @objc private func openSettings() { showSettings = true }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard origin.accepts(message) else { return }  // only the page of the linked server may open the app's settings
        if message.name == "appSettings" { DispatchQueue.main.async { self.showSettings = true } }
    }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

    /// Log out: delete cookies and site data of this server.
    func clearSession(completion: @escaping () -> Void) {
        let store = webView.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records, completionHandler: completion)
        }
    }
}
