import SwiftUI
import AVFoundation

@main
struct NxtSoundApp: App {
    @StateObject private var store = ServerStore()

    init() {
        // Audio session for background playback (milestone 3).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            if let url = store.serverURL {
                PlayerScreen(store: store, url: url)
            } else {
                SetupView(store: store)
            }
        }
    }
}
