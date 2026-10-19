import WebKit
import MediaPlayer

/// Bridge between the web UI's `navigator.mediaSession` and the native lock screen.
/// The page reports title, cover, position and state; the remote control calls the page's handlers.
final class NowPlayingBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "nowPlaying"

    private weak var webView: WKWebView?
    private var info: [String: Any] = [:]
    private var artworkTask: URLSessionDataTask?
    private var commandsReady = false
    /// Native player: play/pause/position go straight there, previous/next to the page.
    var audio: NativeAudio?

    /// Runs in the page before all its own scripts and forwards mediaSession calls.
    static let script = """
    (function () {
      if (window.__npInstalled) return; window.__npInstalled = true;
      var post = function (o) { try { webkit.messageHandlers.nowPlaying.postMessage(o); } catch (e) {} };
      var handlers = {};
      var proto = window.MediaSession && MediaSession.prototype;
      if (!proto) return;
      var abs = function (s) { try { return new URL(s, location.href).href; } catch (e) { return null; } };
      Object.defineProperty(proto, 'metadata', {
        configurable: true,
        get: function () { return this.__md || null; },
        set: function (m) {
          this.__md = m;
          if (!m) { post({ type: 'metadata', clear: true }); return; }
          var art = (m.artwork || []).map(function (a) { return abs(a.src); }).filter(Boolean);
          post({ type: 'metadata', title: m.title || '', artist: m.artist || '', album: m.album || '', artwork: art });
        }
      });
      Object.defineProperty(proto, 'playbackState', {
        configurable: true,
        get: function () { return this.__ps || 'none'; },
        set: function (s) { this.__ps = s; post({ type: 'state', state: s }); }
      });
      proto.setPositionState = function (s) {
        if (s) post({ type: 'position', duration: s.duration, position: s.position, rate: s.playbackRate || 1 });
      };
      proto.setActionHandler = function (name, fn) { if (fn) handlers[name] = fn; else delete handlers[name]; };
      window.__npFire = function (name, detail) {
        var fn = handlers[name];
        if (fn) { fn(Object.assign({ action: name }, detail || {})); return true; }
        var a = document.querySelector('audio');
        if (a && name === 'play') a.play(); else if (a && name === 'pause') a.pause();
        return !!a;
      };
    })();
    """

    /// Take position and state from the native player into the lock screen.
    func updatePlayback(elapsed: Double, duration: Double, playing: Bool) {
        guard info[MPMediaItemPropertyTitle] != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    /// Set lock-screen info for a track (from the page or from the native player).
    func setTrack(title: String, artist: String, album: String, artwork: URL?) {
        let center = MPNowPlayingInfoCenter.default()
        if info[MPMediaItemPropertyTitle] as? String == title, info[MPMediaItemPropertyArtist] as? String == artist, artwork != nil, info[MPMediaItemPropertyArtwork] != nil { return }
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = album
        info[MPMediaItemPropertyArtwork] = nil
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        center.nowPlayingInfo = info
        if let artwork { loadArtwork(artwork) }
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.add(self, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        setupCommands()
    }

    // MARK: Seite -> Lockscreen

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let center = MPNowPlayingInfoCenter.default()
        switch type {
        case "metadata":
            if body["clear"] as? Bool == true {
                info = [:]
                center.nowPlayingInfo = nil
                return
            }
            setTrack(title: body["title"] as? String ?? "", artist: body["artist"] as? String ?? "",
                     album: body["album"] as? String ?? "",
                     artwork: (body["artwork"] as? [String])?.first.flatMap(URL.init(string:)))
        default: break
        }
    }

    private func loadArtwork(_ url: URL) {
        artworkTask?.cancel()
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        store.getAllCookies { [weak self] cookies in
            var request = URLRequest(url: url)
            let relevant = cookies.filter { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == url.host || url.host?.hasSuffix($0.domain) == true }
            for (key, value) in HTTPCookie.requestHeaderFields(with: relevant) { request.setValue(value, forHTTPHeaderField: key) }
            let task = URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let self, let data, let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                DispatchQueue.main.async {
                    self.info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
                }
            }
            self?.artworkTask = task
            task.resume()
        }
    }

    // MARK: Lockscreen -> Seite

    private func setupCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.audio?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.audio?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            if MPNowPlayingInfoCenter.default().playbackState == .playing { self?.audio?.pause() } else { self?.audio?.play() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.audio?.remoteNext(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.audio?.remotePrevious(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.audio?.seek(to: e.positionTime); return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    func fire(_ name: String, detail: String = "null") {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__npFire && window.__npFire('\(name)', \(detail))")
        }
    }
}
