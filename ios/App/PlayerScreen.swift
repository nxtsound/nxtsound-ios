import SwiftUI
import WebKit

/// Shows the server's web UI edge to edge. The page handles login itself (cookie session).
struct PlayerScreen: View {
    @ObservedObject var store: ServerStore
    @StateObject private var model: WebModel
    @State private var showSplash = true
    @State private var showOffline = false
    @StateObject private var net = NetworkMonitor()
    @StateObject private var offline = OfflineStore()
    @Environment(\.scenePhase) private var scenePhase

    init(store: ServerStore, url: URL) {
        self.store = store
        _model = StateObject(wrappedValue: WebModel(url: url))
    }

    var body: some View {
        ZStack {
            Color.black
            WebView(webView: model.webView)
            switch model.state {
            case .loading: LoadingOverlay()
            case .failed(let reason):
                if offline.tracks.isEmpty || !(showOffline || !net.isOnline) {
                    ConnectionFailedView(host: store.serverURL?.host ?? "", reason: reason, model: model, hasOfflineSongs: !offline.tracks.isEmpty) { showOffline = true }
                }
            case .loaded: EmptyView()
            }
            if offlineVisible { OfflineView(offline: offline, model: model, online: net.isOnline, onRetry: { model.reload() }, onClose: failed ? nil : { showOffline = false }) }
            if showSplash { SplashView(model: model) }
        }
        .overlay(alignment: .top) {
            if !net.isOnline && !offlineVisible && !showSplash { OfflineBadge(hasSongs: !offline.tracks.isEmpty) { showOffline = true } }
        }
        .onAppear { offline.bind(store.serverURL) }
        .onChange(of: store.serverURL) { _, url in offline.bind(url) }
        .onChange(of: model.state) { _, state in
            if state == .loaded { syncOffline() }
        }
        .onChange(of: net.isOnline) { _, online in
            guard online else { return }
            if failed || model.fromCache { model.reload() }
            syncOffline()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { syncOffline() } }
        .task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(store: store, model: model, offline: offline, network: net)
        }
    }

    private var failed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    /// The offline list takes over when the page cannot be shown and there is no connection, or when the user opened it.
    private var offlineVisible: Bool {
        !offline.tracks.isEmpty && (showOffline || (failed && !net.isOnline))
    }

    private func syncOffline() {
        Task { await offline.syncIfDue(cookies: model.cookieStore, network: net) }
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Only visible on first load and with slow servers; fades out otherwise.
struct LoadingOverlay: View {
    var body: some View {
        ProgressView().controlSize(.large).tint(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

struct ConnectionFailedView: View {
    let host: String
    let reason: String
    @ObservedObject var model: WebModel
    var hasOfflineSongs = false
    var openOffline: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Server unreachable").font(.title2.bold())
            Text(host).font(.callout.monospaced()).foregroundStyle(.secondary)
            Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { model.reload() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("App settings") { model.showSettings = true }
                .buttonStyle(.bordered).controlSize(.large)
            if hasOfflineSongs {
                Button("Offline songs", action: openOffline).buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// Splash for a few seconds: name, loading indicator and a way into the app settings.
struct SplashView: View {
    @ObservedObject var model: WebModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("Logo")
                .resizable().scaledToFit().frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            Text(AppConfig.appName).font(.largeTitle.bold())
            ProgressView().tint(.white)
            Spacer()
            Button { model.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .transition(.opacity)
    }
}
