import SwiftUI
import SwiftData

/// Storage ▸ Downloaded. Lists locally-downloaded tracks with swipe-to-delete (and "Remove All"),
/// each removal deleting the on-disk file via `TelegramService.removeDownload`. Presented as a
/// sheet from Settings, which has no NavigationStack of its own. The list is backed by the
/// "Downloaded" smart playlist, so it stays in sync as tracks are added/removed.
struct NDownloadsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?
    // Deliberately unfiltered, then narrowed in memory — the same trade-off `PlaylistService`
    // documents: a `#Predicate` over a `@Model` expands to a `ReferenceWritableKeyPath`, which can
    // never be `Sendable` (an error under the Swift 6 language mode). The playlist table is a
    // handful of rows, so filtering them here costs nothing measurable.
    @Query private var playlists: [Playlist]
    private var downloadLists: [Playlist] { playlists.filter(\.isDownloads) }
    @State private var confirmRemoveAll = false

    private var tracks: [AudioTrack] {
        (downloadLists.first?.orderedTracks ?? []).map(\.audioTrack)
    }

    var body: some View {
        NavigationStack {
            Group {
                if tracks.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Downloaded tracks play offline and appear here."))
                } else {
                    List {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                            TrackRow(title: t.displayTitle, subtitle: t.displaySubtitle, seed: t.remoteUniqueId,
                                     track: t, isActive: player.current?.remoteUniqueId == t.remoteUniqueId, isPlaying: player.isPlaying,
                                     downloaded: true, duration: t.formattedDuration,
                                     onTap: { player.play(tracks: tracks, startAt: i, context: "Downloaded") })
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowBackground(theme.elev)
                                .listRowSeparatorTint(theme.hairline)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { telegram.removeDownload(t) } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { player.addToQueue(t, feedback: feedback) } label: {
                                        Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                                    }
                                    .tint(theme.accentColor)
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Downloaded")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if !tracks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Remove All", role: .destructive) { confirmRemoveAll = true }
                    }
                }
            }
            .alert("Remove all downloads?", isPresented: $confirmRemoveAll) {
                Button("Remove All", role: .destructive) {
                    let toRemove = tracks
                    Task.detached(priority: .userInitiated) {
                        for track in toRemove {
                            await MainActor.run { telegram.removeDownload(track) }
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Files are deleted from this device. You can download them again later.")
            }
        }
    }
}
