import SwiftUI

/// One row for local, Telegram and bot audio, with the same playback and playlist actions.
struct NSearchTrackRow: View {
    let track: AudioTrack
    let songs: [AudioTrack]
    let context: String
    let onCommit: () -> Void
    @Binding var addTarget: AudioTrack?
    @Binding var actionTarget: AudioTrack?
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?
    @Environment(NTrackSelection.self) private var selection: NTrackSelection?

    var body: some View {
        TrackRow(title: track.displayTitle, subtitle: track.displaySubtitle, seed: track.remoteUniqueId,
                 track: track, isActive: player.current?.remoteUniqueId == track.remoteUniqueId,
                 isPlaying: player.isPlaying, downloaded: telegram.isDownloaded(track),
                 duration: track.formattedDuration,
                 onTap: play, onMore: { actionTarget = track })
            .swipeActions(edge: .leading) {
                if selection?.isSelecting != true,
                   !telegram.isOfflineStable || telegram.isAvailableOffline(track),
                   !telegram.isUnavailableOnTelegram(track) {
                    Button { player.addToQueue(track, feedback: feedback, fromSearch: true) } label: {
                        Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .tint(theme.accentColor)
                }
            }

    }

    private func play() {
        onCommit()
        let index = songs.firstIndex { $0.id == track.id } ?? 0
        player.play(tracks: songs, startAt: index, context: context, fromSearch: true)
    }
}
