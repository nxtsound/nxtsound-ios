import WebKit
import AVFoundation
import Network
import UIKit

/// Native player behind the web UI's `<audio id="audio">`.
/// A script in the page replaces the element's behaviour (src, play, pause, currentTime ...)
/// and forwards it here; playback runs in the app process (AVPlayer), not in the web view.
/// Result: lock screen, island and remote control are real, and iOS does not freeze playback together with the page.
struct NativeTrack {
    let id: String
    let url: URL
    let title: String
    let artist: String
    let album: String
    let thumb: URL?

    /// A track the page describes. Only stream addresses of the linked server count, and a cover only from there or from https.
    init?(_ dict: [String: Any]?, origin: TrustedOrigin?) {
        guard let dict, let id = dict["id"] as? String, let text = dict["url"] as? String, let url = URL(string: text),
              origin?.isStream(url) == true else { return nil }
        self.id = id
        self.url = url
        title = dict["title"] as? String ?? ""
        artist = dict["artist"] as? String ?? ""
        album = dict["album"] as? String ?? ""
        thumb = (dict["thumb"] as? String).flatMap(URL.init(string:)).flatMap { origin?.isPicture($0) == true ? $0 : nil }
    }

    init(id: String, url: URL) {
        self.id = id; self.url = url; title = ""; artist = ""; album = ""; thumb = nil
    }

    /// A song kept on the device (a local file; not checked against the server: the app wrote it itself).
    init(id: String, url: URL, title: String, artist: String, album: String, thumb: URL?) {
        self.id = id; self.url = url; self.title = title; self.artist = artist; self.album = album; self.thumb = thumb
    }
}

final class NativeAudio: NSObject, WKScriptMessageHandler {
    static let handlerName = "nativeAudio"

    /// Keep the lock-screen position and state up to date.
    var onPlayback: ((_ elapsed: Double, _ duration: Double, _ playing: Bool) -> Void)?
    /// The track has changed (even without the page): set lock-screen info.
    var onTrack: ((NativeTrack) -> Void)?
    /// Pass a command on to the page when the player cannot handle it itself.
    var onPageCommand: ((String) -> Void)?

    /// The linked server: the page may only make the player fetch its stream addresses (set by the web model).
    var origin: TrustedOrigin?

    private weak var webView: WKWebView?
    private let player = AVQueuePlayer()
    private var wantPlay = false
    private var ended = false
    private var loading = false
    private var generation = 0
    private var observers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var cookies: [HTTPCookie] = []

    // A stream that breaks (tunnel, cell change, weak signal): the same song is loaded again where it stopped, as long as the user did not pause.
    private var lastTime = 0.0
    private var resumeAt: Double?
    private var retries = 0
    private var retryItem: DispatchWorkItem?
    private var retryBackground: UIBackgroundTaskIdentifier = .invalid
    private let pathMonitor = NWPathMonitor()
    private static let maxRetries = 12

    // Queue window, reported by the page
    private var current: NativeTrack?
    private var previous: NativeTrack?
    private var upcoming: [NativeTrack] = []
    private var repeatMode = "off"
    private var meta: [ObjectIdentifier: NativeTrack] = [:]

    // Replaces the behaviour of the audio element #audio. The second element (DJ mode) is left untouched.
    static let script = """
    (function () {
      if (window.__nativeAudioInstalled) return; window.__nativeAudioInstalled = true;
      var P = HTMLMediaElement.prototype;
      var post = function (o) { try { webkit.messageHandlers.nativeAudio.postMessage(o); } catch (e) {} };
      var isN = function (el) { return el && el.id === 'audio'; };
      var abs = function (s) { try { return new URL(s, location.href).href; } catch (e) { return s; } };
      var st = { src: '', paused: true, ended: false, t: 0, dur: NaN, ready: 0, seeking: false, el: null };
      var fire = function (type) { if (st.el) st.el.dispatchEvent(new Event(type)); };

      var accessor = function (name, get, set) {
        var o = Object.getOwnPropertyDescriptor(P, name) || {};
        Object.defineProperty(P, name, { configurable: true, enumerable: true,
          get: function () { if (isN(this)) { st.el = this; return get(); } return o.get && o.get.call(this); },
          set: function (v) { if (isN(this)) { st.el = this; if (set) set(v); } else if (o.set) o.set.call(this, v); } });
      };
      accessor('src', function () { return st.src; }, function (v) {
        st.src = v ? abs(v) : ''; st.t = 0; st.dur = NaN; st.ended = false; st.ready = 0;
        if (st.src) { post({ cmd: 'load', url: st.src }); fire('loadstart'); } else post({ cmd: 'stop' });
      });
      accessor('currentSrc', function () { return st.src; });
      accessor('paused', function () { return st.paused; });
      accessor('ended', function () { return st.ended; });
      accessor('duration', function () { return st.dur; });
      accessor('readyState', function () { return st.ready; });
      accessor('seeking', function () { return st.seeking; });
      accessor('currentTime', function () { return st.t; }, function (v) {
        st.t = v; st.seeking = true; post({ cmd: 'seek', time: v }); fire('seeking');
      });

      var method = function (name, fn) {
        var o = P[name];
        P[name] = function () { if (isN(this)) { st.el = this; return fn.apply(this, arguments); } return o.apply(this, arguments); };
      };
      method('play', function () { st.paused = false; post({ cmd: 'play' }); fire('play'); return Promise.resolve(); });
      method('pause', function () { st.paused = true; post({ cmd: 'pause' }); fire('pause'); });
      method('load', function () { if (st.src) post({ cmd: 'load', url: st.src }); });
      var origRemove = Element.prototype.removeAttribute;
      Element.prototype.removeAttribute = function (n) {
        if (isN(this) && n === 'src') { st.src = ''; st.t = 0; st.dur = NaN; post({ cmd: 'stop' }); return; }
        return origRemove.apply(this, arguments);
      };
      var origSet = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (n, v) {
        if (isN(this) && n === 'src') { this.src = v; return; }
        return origSet.apply(this, arguments);
      };

      // Preloading as a blob (only needed for the PWA) is of no use to the native player: reject it.
      var origFetch = window.fetch;
      window.fetch = function (input) {
        var u = typeof input === 'string' ? input : (input && input.url) || '';
        if (u.indexOf('/api/stream/') >= 0 && u.indexOf('pre=1') >= 0) {
          var e = new Error('nativ'); e.name = 'AbortError'; return Promise.reject(e);
        }
        return origFetch.apply(this, arguments);
      };

      // Report the queue window to the native player so it can keep playing even without the page.
      var lastSig = '';
      var info = function (t) {
        return t ? { id: t.id, title: t.title || '', artist: t.artist || '', album: t.album || '',
                     thumb: t.thumb ? abs(t.thumb) : null, url: abs('/api/stream/' + encodeURIComponent(t.id)) } : null;
      };
      var snapshot = function () {
        if (typeof S === 'undefined' || !S.queue || S.idx < 0 || !S.queue[S.idx]) return;
        var next = S.queue.slice(S.idx + 1, S.idx + 4).map(info);
        var sig = [S.queue[S.idx].id, (S.queue[S.idx - 1] || {}).id, S.repeat].concat(next.map(function (x) { return x.id; })).join('|');
        if (sig === lastSig) return;
        lastSig = sig;
        post({ cmd: 'queue', cur: info(S.queue[S.idx]), prev: info(S.queue[S.idx - 1]), next: next, repeat: S.repeat || 'off' });
      };
      setInterval(snapshot, 1000);

      // The native player is already at the next track: catch the page up (index, display) without restarting.
      window.__nativeAudioAdvanced = function (id) {
        if (typeof S === 'undefined' || !S.queue) return;
        var i = S.queue.findIndex(function (t) { return t.id === id; });
        if (i >= 0 && i !== S.idx) { lastSig = ''; playIndex(i); }
      };

      // Mirror events from the native player into the page.
      window.__nativeAudioEvent = function (e) {
        st.t = e.t; if (e.dur != null) st.dur = e.dur; st.paused = e.paused; st.ended = e.ended;
        if (e.type === 'loadedmetadata') st.ready = 1;
        if (e.type === 'canplay' || e.type === 'playing') st.ready = 4;
        if (e.type === 'seeked') st.seeking = false;
        fire(e.type);
        if (e.type === 'loadedmetadata') fire('durationchange');
      };
    })();
    """

    func attach(to webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.add(self, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        observePlayer()
    }

    // MARK: Seite -> Player

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard origin?.accepts(message) == true, let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "load": if let text = body["url"] as? String, let url = URL(string: text), origin?.isStream(url) == true { load(url) }
        case "play": play()
        case "pause": pause()
        case "seek": seek(to: body["time"] as? Double ?? 0)
        case "stop": stop()
        case "queue": updateQueue(body)
        default: break
        }
    }

    /// Plays songs kept on the device (the offline view): from `index` on, the ones before it are reachable with "previous".
    func playLocal(_ tracks: [NativeTrack], index: Int) {
        guard tracks.indices.contains(index) else { return }
        previous = index > 0 ? tracks[index - 1] : nil
        upcoming = Array(tracks[(index + 1)...])
        repeatMode = "off"
        wantPlay = true
        play(track: tracks[index])
    }

    // MARK: Control (also used by the remote control)

    func play() {
        wantPlay = true
        if ended { ended = false; player.seek(to: .zero) }
        player.play()
    }

    func pause() {
        wantPlay = false
        cancelRetry()
        player.pause()
        emit("pause")
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.emit("seeked")
        }
    }

    private func stop() {
        generation += 1
        wantPlay = false
        cancelRetry()
        loading = false
        player.pause()
        player.removeAllItems()
        current = nil; previous = nil; upcoming = []; meta.removeAll()
    }

    private static func id(of url: URL) -> String { url.lastPathComponent }

    private func known(_ id: String) -> NativeTrack? {
        ([current, previous].compactMap { $0 } + upcoming).first { $0.id == id }
    }

    private func load(_ url: URL) {
        let id = Self.id(of: url)
        // Already playing (the native player was at the track before the page): do not restart anything.
        if current?.id == id, player.currentItem != nil {
            emit("loadedmetadata"); emit("canplay")
            if player.timeControlStatus == .playing { emit("playing") }
            return
        }
        // Already preloaded: switch there immediately.
        if let queued = player.items().dropFirst().first, meta[ObjectIdentifier(queued)]?.id == id {
            player.advanceToNextItem()
            return
        }
        play(track: known(id) ?? NativeTrack(id: id, url: url))
    }

    /// Rebuilds playback on a track (stream with the session's cookies).
    private func play(track: NativeTrack) {
        generation += 1
        let gen = generation
        loading = true
        ended = false
        current = track
        lastTime = resumeAt ?? 0
        if !track.title.isEmpty { onTrack?(track) }  // unknown track: the page supplies the info later
        player.pause()
        withCookies { [weak self] in
            guard let self, gen == self.generation else { return }
            self.player.removeAllItems()
            self.meta.removeAll()
            let item = self.makeItem(track)
            self.observe(item)
            self.player.insert(item, after: nil)
            if let t = self.resumeAt { item.seek(to: CMTime(seconds: t, preferredTimescale: 600), completionHandler: nil); self.resumeAt = nil }
            self.loading = false
            self.syncQueueItems()
            if self.wantPlay { self.player.play() }
        }
    }

    private func makeItem(_ track: NativeTrack) -> AVPlayerItem {
        let relevant = cookies.filter { cookie in
            guard let host = track.url.host else { return false }
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: track.url, options: [AVURLAssetHTTPCookiesKey: relevant]))
        meta[ObjectIdentifier(item)] = track
        return item
    }

    private func withCookies(_ work: @escaping () -> Void) {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        store.getAllCookies { [weak self] list in
            DispatchQueue.main.async { self?.cookies = list; work() }
        }
    }

    // MARK: Warteschlange

    private func updateQueue(_ body: [String: Any]) {
        guard let cur = NativeTrack(body["cur"] as? [String: Any], origin: origin) else { return }
        // Outdated state of the page (the player is already further): ignore it, the page catches up.
        guard cur.id == current?.id else { return }
        current = cur
        previous = NativeTrack(body["prev"] as? [String: Any], origin: origin)
        upcoming = (body["next"] as? [[String: Any]] ?? []).compactMap { NativeTrack($0, origin: origin) }
        repeatMode = body["repeat"] as? String ?? "off"
        withCookies { [weak self] in self?.syncQueueItems() }
    }

    /// Keeps the next one or two tracks preloaded in the player (none for "repeat track").
    private func syncQueueItems() {
        guard player.currentItem != nil else { return }
        let want = repeatMode == "one" ? [] : Array(upcoming.prefix(2))
        let queued = Array(player.items().dropFirst())
        if queued.compactMap({ meta[ObjectIdentifier($0)]?.id }) == want.map(\.id) { return }
        queued.forEach { player.remove($0); meta[ObjectIdentifier($0)] = nil }
        for track in want { player.insert(makeItem(track), after: player.items().last) }
    }

    /// The track changes in the player by itself (end or next button): update state and lock screen, notify the page.
    private func advanced(to item: AVPlayerItem) {
        guard let track = meta[ObjectIdentifier(item)], track.id != current?.id else { return }
        previous = current
        current = track
        upcoming.removeAll { $0.id == track.id }
        ended = false
        onTrack?(track)
        observe(item)
        syncQueueItems()
        callPage("__nativeAudioAdvanced", argument: track.id)
    }

    func remoteNext() {
        if player.items().count > 1 { player.advanceToNextItem() } else { onPageCommand?("nexttrack") }
    }

    func remotePrevious() {
        if player.currentTime().seconds > 3 { seek(to: 0); return }
        guard let prev = previous else { seek(to: 0); return }
        wantPlay = true
        play(track: prev)
        callPage("__nativeAudioAdvanced", argument: prev.id)
    }

    // MARK: Player -> Seite

    private var itemObservation: NSKeyValueObservation?

    private func observe(_ item: AVPlayerItem) {
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                self?.emit("loadedmetadata")
                self?.emit("canplay")
            case .failed:
                self?.streamFailed()
            default: break
            }
        }
    }

    /// The stream broke while the user wanted to listen: try again where it stopped (quickly at first, then slower), also at once when the connection returns.
    /// Only after many attempts the page hears about it (it would skip or stop).
    private func streamFailed() {
        guard wantPlay, current != nil else { emit("error"); return }
        guard retries < Self.maxRetries else { give(upAfter: "error"); return }
        retries += 1
        if retryBackground == .invalid {
            retryBackground = UIApplication.shared.beginBackgroundTask(withName: "stream-retry") { [weak self] in self?.endRetryBackground() }
        }
        retryItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retryNow() }
        retryItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(Double(retries), 8), execute: work)
    }

    private func retryNow() {
        retryItem?.cancel(); retryItem = nil
        guard wantPlay, let track = current else { return }
        resumeAt = lastTime > 1 ? lastTime : nil
        play(track: track)
    }

    private func give(upAfter event: String) {
        cancelRetry()
        wantPlay = false
        emit(event)
    }

    private func cancelRetry() {
        retryItem?.cancel(); retryItem = nil
        retries = 0
        endRetryBackground()
    }

    private func endRetryBackground() {
        if retryBackground != .invalid { UIApplication.shared.endBackgroundTask(retryBackground); retryBackground = .invalid }
    }

    @objc private func didEnd(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
        if player.items().count > 1 { return }  // the next track is already starting, `advanced` takes care of it
        if repeatMode == "one", let track = current { play(track: track); return }
        ended = true
        wantPlay = false
        emit("ended")
    }

    @objc private func didFailToEnd(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
        streamFailed()
    }

    private func observePlayer() {
        guard observers.isEmpty else { return }
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self, !self.loading else { return }
            switch player.timeControlStatus {
            case .playing:
                if self.retries > 0 { self.cancelRetry() }
                self.emit("playing")
            case .waitingToPlayAtSpecifiedRate: if self.wantPlay { self.emit("waiting") }
            case .paused:
                // Paused by the system (call, headphones unplugged, remote control): inform the page.
                // (A broken stream also stops the player: that is handled by `streamFailed`, not a pause.)
                if self.wantPlay && !self.ended && self.player.currentItem?.status != .failed && self.retryItem == nil {
                    self.wantPlay = false; self.emit("pause")
                }
            @unknown default: break
            }
        })
        observers.append(player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            guard let self, !self.loading, let item = player.currentItem else { return }
            self.advanced(to: item)
        })
        NotificationCenter.default.addObserver(self, selector: #selector(didEnd(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didFailToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { if self?.retryItem != nil { self?.retryNow() } }  // the connection is back: no need to wait for the timer
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.nxtsound.audio.network"))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            guard let self else { return }
            let t = self.player.currentTime().seconds
            if t.isFinite, self.player.timeControlStatus == .playing { self.lastTime = t }
            self.emit("timeupdate")
        }
    }

    private func callPage(_ function: String, argument: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [argument]), let arr = String(data: data, encoding: .utf8) else { return }
        let js = "window.\(function) && window.\(function)(\(arr)[0])"
        DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(js) }
    }

    private func emit(_ type: String) {
        let t = player.currentTime().seconds
        let d = player.currentItem?.duration.seconds ?? .nan
        let time = t.isFinite ? t : 0
        let dur: Any = d.isFinite ? d : NSNull()
        onPlayback?(time, d.isFinite ? d : 0, player.timeControlStatus == .playing)
        let payload: [String: Any] = ["type": type, "t": time, "dur": dur, "paused": !wantPlay, "ended": ended]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__nativeAudioEvent && window.__nativeAudioEvent(\(json))")
        }
    }
}
