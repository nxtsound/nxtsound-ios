import SwiftUI

/// The songs the user keeps on the device by choice: search the library, add, remove.
struct OfflineChooseView: View {
    @ObservedObject var offline: OfflineStore
    @ObservedObject var model: WebModel
    @ObservedObject var network: NetworkMonitor
    @State private var query = ""
    @State private var results: [PinnedSong] = []
    @State private var searching = false

    var body: some View {
        List {
            if !query.isEmpty {
                Section("Search results") {
                    if results.isEmpty {
                        Text(searching ? LocalizedStringKey("Searching …") : LocalizedStringKey("Nothing found.")).foregroundStyle(.secondary)
                    }
                    ForEach(results) { song in
                        let chosen = offline.pinned.contains { $0.id == song.id }
                        Button { toggle(song, chosen: chosen) } label: { row(song, chosen: chosen) }
                    }
                }
            }
            Section {
                if offline.pinned.isEmpty {
                    Text("You have not chosen any songs yet. Search above and tap one to keep it.").foregroundStyle(.secondary)
                }
                ForEach(offline.pinned) { song in row(song, chosen: true) }
                    .onDelete { offsets in
                        offsets.map { offline.pinned[$0].id }.forEach(offline.unpin)
                        update()
                    }
            } header: {
                Text("Chosen songs")
            } footer: {
                Text("Chosen songs are always kept. The last played and most played ones fill up the rest.")
            }
        }
        .navigationTitle("Chosen songs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search your library"))
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(350))  // wait for the typing to pause (a new letter cancels this)
            guard !Task.isCancelled else { return }
            let cookies = await model.cookieStore.allCookies()
            let found = await offline.search(query, cookies: cookies)
            if !Task.isCancelled { results = found; searching = false }
        }
    }

    private func row(_ song: PinnedSong, chosen: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).foregroundStyle(.primary).lineLimit(1)
                Text(song.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: chosen ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(chosen ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ song: PinnedSong, chosen: Bool) {
        if chosen { offline.unpin(song.id) } else { offline.pin(song) }
        update()
    }

    /// Downloads (or drops) what changed, if a connection and the settings allow it.
    private func update() {
        guard offline.enabled, network.isOnline else { return }
        Task { await offline.sync(cookies: model.cookieStore) }
    }
}
