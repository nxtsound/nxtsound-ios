import SwiftUI

/// Shown when there is no connection (or the server cannot be reached) and the user has songs on the device: a plain list that plays them.
struct OfflineView: View {
    @ObservedObject var offline: OfflineStore
    @ObservedObject var model: WebModel
    let online: Bool
    let onRetry: () -> Void
    /// Leave the view (only offered when the page behind it is usable).
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                }
                Spacer()
                Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.body.weight(.semibold)) }
            }
            .padding(.horizontal, 20).padding(.top, 60).padding(.bottom, 8)
            .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Image(systemName: online ? "wifi.exclamationmark" : "wifi.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(online ? LocalizedStringKey("Server unreachable") : LocalizedStringKey("You are offline")).font(.title2.bold())
                Text(offline.tracks.isEmpty ? LocalizedStringKey("No songs are saved for offline use. You can switch this on in the app settings.") : LocalizedStringKey("These songs are saved on this device."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32).padding(.bottom, 16)

            if offline.tracks.isEmpty {
                Spacer()
            } else {
                List {
                    ForEach(Array(offline.tracks.enumerated()), id: \.element.id) { index, track in
                        Button { model.playOffline(offline.nativeTracks(), index: index) } label: { row(track) }
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }

            Button("Try again", action: onRetry).buttonStyle(.bordered).padding(.vertical, 12)
            if let now = model.nowPlaying, offline.tracks.contains(where: { $0.id == now.id }) { nowBar(now) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func row(_ track: OfflineTrack) -> some View {
        HStack(spacing: 12) {
            Cover(url: offline.coverURL(track)).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).foregroundStyle(model.nowPlaying?.id == track.id ? Color.accentColor : .primary).lineLimit(1)
                Text(track.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func nowBar(_ track: NativeTrack) -> some View {
        HStack(spacing: 14) {
            Cover(url: track.thumb).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
            Button { model.skipNext() } label: { Image(systemName: "forward.fill").font(.title3) }
        }
        .padding(.horizontal, 20).padding(.vertical, 10).padding(.bottom, 24)
        .background(.ultraThinMaterial)
    }
}

/// A picture from a local file (a missing one shows a plain tile).
struct Cover: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A small pill at the top: no connection. (Not a full-width bar: the page's own buttons stay reachable.)
struct OfflineBadge: View {
    let hasSongs: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("You are offline")
            if hasSongs {
                Button("Offline songs", action: onOpen).buttonStyle(.borderless).foregroundStyle(Color.accentColor)
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .padding(.top, Self.topInset + 6)
    }

    /// The view runs under the status bar and the Dynamic Island: the pill starts below them.
    private static var topInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets.top ?? 47
    }
}
